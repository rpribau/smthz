import Observation
import SmthzCore
import SwiftUI

/// UI-22 integration: retain one instance per window and apply
/// `.smthzCloseConfirmations(coordinator)` to the full window content. Route close
/// actions through `await coordinator.confirmClose(...)`; the callback owns removal
/// and session termination. No host mutation happens while deciding whether to ask.
@MainActor @Observable
final class SmthzCloseConfirmationCoordinator {
    enum Prompt {
        case pinned(label: String?)
        case running(label: String?, isAgent: Bool)
        case bulk(SmthzBulkCloseKind)
    }

    static let runningPreferenceKey = "confirmations.skipRunningTerminal"
    static let pinnedPreferenceKey = "confirmations.skipPinnedTab"
    private(set) var prompt: Prompt?
    private(set) var isChecking = false
    private(set) var presentationID = UUID()
    private let defaults: UserDefaults
    private var accept: (@MainActor () -> Void)?
    private var checkID = UUID()

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// A fresh connection on a background task keeps synchronous RPC off the UI thread.
    /// Unknown foreground state is treated conservatively and still asks before closing.
    func confirmClose(
        sessionID: String, socketPath: String, tabLabel: String? = nil,
        isPinned: Bool = false, isAgent: Bool = false,
        onClose: @escaping @MainActor () -> Void
    ) async {
        await confirmClose(tabLabel: tabLabel, isPinned: isPinned, isAgent: isAgent,
                           foregroundIsShell: {
            try await Task.detached {
                let client = try HostClient(socketPath: socketPath)
                defer { client.disconnect() }
                return try client.foreground(id: sessionID).isShell
            }.value
        }, onClose: onClose)
    }

    /// Injectable lookup for a caller that already serializes its host connection.
    func confirmClose(
        tabLabel: String? = nil, isPinned: Bool = false, isAgent: Bool = false,
        foregroundIsShell: @MainActor () async throws -> Bool,
        onClose: @escaping @MainActor () -> Void
    ) async {
        guard prompt == nil, !isChecking else { return }
        isChecking = true
        let requestID = UUID()
        checkID = requestID
        let needsRunningPrompt: Bool
        if defaults.bool(forKey: Self.runningPreferenceKey) {
            needsRunningPrompt = false
        } else if isAgent {
            needsRunningPrompt = true
        } else {
            needsRunningPrompt = (try? await foregroundIsShell()) != true
        }
        guard checkID == requestID else { return }
        isChecking = false
        guard !Task.isCancelled else { return }
        let afterPin: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            if needsRunningPrompt {
                self.present(.running(label: tabLabel, isAgent: isAgent), accept: onClose)
            } else {
                onClose()
            }
        }
        if isPinned && !defaults.bool(forKey: Self.pinnedPreferenceKey) {
            present(.pinned(label: tabLabel), accept: afterPin)
        } else {
            afterPin()
        }
    }

    /// Pass only the candidate tabs for this operation; pinned IDs are filtered here
    /// as well as in the UI. Empty selections do not show a dialog.
    func confirmClose(
        _ kind: SmthzBulkCloseKind, tabIDs: [String], pinnedTabIDs: Set<String>,
        onClose: @escaping @MainActor ([String]) -> Void
    ) {
        guard prompt == nil, !isChecking else { return }
        var seen = Set<String>()
        let targets = tabIDs.filter { !pinnedTabIDs.contains($0) && seen.insert($0).inserted }
        guard !targets.isEmpty else { return }
        present(.bulk(kind)) { onClose(targets) }
    }

    func cancel() {
        checkID = UUID()
        isChecking = false
        prompt = nil
        accept = nil
    }

    func confirm(dontAskAgain: Bool = false) {
        guard let prompt else { return }
        if dontAskAgain {
            switch prompt {
            case .running: defaults.set(true, forKey: Self.runningPreferenceKey)
            case .pinned: defaults.set(true, forKey: Self.pinnedPreferenceKey)
            case .bulk: break
            }
        }
        let action = accept
        self.prompt = nil
        accept = nil
        action?()
    }

    private func present(_ prompt: Prompt, accept: @escaping @MainActor () -> Void) {
        presentationID = UUID()
        self.prompt = prompt
        self.accept = accept
    }
}

struct SmthzCloseTerminalDialog: View {
    var tabLabel: String? = nil
    var isAgent = false
    let onCancel: () -> Void
    let onConfirm: (Bool) -> Void
    @State private var dontAskAgain = false

    var body: some View {
        SmthzDialog(title: isAgent ? "Stop this agent?" : "Stop running command?",
                    description: isAgent
                        ? "Closing this terminal will stop the agent's current work."
                        : "Closing this terminal will stop the command running inside it.",
                    compact: true, onDismiss: onCancel) {
            if isAgent {
                Text("This terminal will not resume automatically. Cancel and put the workspace to sleep to resume it later.")
                    .font(SmthzFont.ui(size: 12))
                    .foregroundStyle(SmthzTheme.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SmthzCloseTabLabel(label: tabLabel)
            SmthzConfirmationCheckbox(title: "Don't ask again for running terminals", isOn: $dontAskAgain)
        } footer: {
            Button("Cancel", action: onCancel)
                .buttonStyle(SmthzButtonStyle(.outline, size: .small))
                .keyboardShortcut(.cancelAction)
            Button(isAgent ? "Stop Agent" : "Stop and Close", role: .destructive) { onConfirm(dontAskAgain) }
                .buttonStyle(SmthzDestructiveDialogButtonStyle())
        }
    }
}

struct SmthzCloseTabLabel: View {
    let label: String?
    var body: some View {
        if let label, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(label.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(SmthzFont.ui(size: 12, weight: .medium))
                .lineLimit(1).truncationMode(.middle).help(label)
        }
    }
}

struct SmthzConfirmationCheckbox: View {
    let title: String
    @Binding var isOn: Bool
    var body: some View {
        Toggle(title, isOn: $isOn)
            .toggleStyle(.checkbox)
            .font(SmthzFont.ui(size: 12))
            .foregroundStyle(SmthzTheme.mutedForeground)
            .tint(SmthzTheme.foreground)
    }
}

/// Destructive variant local to UI-22; shared control styles stay read-only.
struct SmthzDestructiveDialogButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SmthzDestructiveDialogButton(configuration: configuration)
    }

    private struct SmthzDestructiveDialogButton: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        @State private var hovered = false
        var body: some View {
            configuration.label
                .font(SmthzFont.ui(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12).frame(height: 32)
                .background(SmthzTheme.destructive.opacity(hovered || configuration.isPressed ? 0.9 : 1),
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isFocused ? SmthzTheme.ring : .clear, lineWidth: 2)
                        .padding(-3)
                }
                .opacity(isEnabled ? 1 : 0.5)
                .onHover { hovered = $0 }
        }
    }
}

private struct SmthzCloseConfirmationPresentation: ViewModifier {
    let coordinator: SmthzCloseConfirmationCoordinator
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        ZStack {
            content
                .disabled(coordinator.prompt != nil)
                .accessibilityHidden(coordinator.prompt != nil)
                .blur(radius: coordinator.prompt != nil && !reduceTransparency ? 2 : 0)
            if let prompt = coordinator.prompt {
                Color.black.opacity(0.55).ignoresSafeArea()
                    .onTapGesture { coordinator.cancel() }.accessibilityHidden(true)
                    .transition(.opacity)
                Group {
                    switch prompt {
                    case .pinned(let label):
                        SmthzPinnedTabCloseDialog(tabLabel: label, onCancel: coordinator.cancel,
                                                 onConfirm: { coordinator.confirm(dontAskAgain: $0) })
                    case .running(let label, let isAgent):
                        SmthzCloseTerminalDialog(tabLabel: label, isAgent: isAgent, onCancel: coordinator.cancel,
                                                onConfirm: { coordinator.confirm(dontAskAgain: $0) })
                    case .bulk(let kind):
                        SmthzBulkCloseDialog(kind: kind, onCancel: coordinator.cancel,
                                             onConfirm: { coordinator.confirm() })
                    }
                }
                .id(coordinator.presentationID) // Each subject gets a fresh unchecked checkbox.
                .padding(24)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.95)))
                .zIndex(1)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: coordinator.prompt != nil)
    }
}

extension View {
    func smthzCloseConfirmations(_ coordinator: SmthzCloseConfirmationCoordinator) -> some View {
        modifier(SmthzCloseConfirmationPresentation(coordinator: coordinator))
    }
}

#Preview("Running command") {
    SmthzCloseTerminalDialog(tabLabel: "sleep 100", onCancel: {}, onConfirm: { _ in })
        .padding(40).frame(width: 600, height: 360).background(SmthzTheme.background)
}

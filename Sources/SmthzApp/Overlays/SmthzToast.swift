import SwiftUI

struct SmthzToastAction: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let perform: @MainActor () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

/// Defaults to a persistent error, preserving existing `title:description:` call sites.
struct SmthzToastMessage: Identifiable, Equatable {
    enum Kind: String, CaseIterable {
        case success, info, loading, error, warning

        var icon: String {
            switch self {
            case .success: "circle-check"
            case .info: "info"
            case .loading: "loader-circle" // Lucide Loader2 alias.
            case .error: "octagon-x"
            case .warning: "triangle-alert"
            }
        }
    }

    let id = UUID()
    let title: String
    var description: String? = nil
    var kind: Kind = .error
    var action: SmthzToastAction? = nil
}

/// Flat Sonner surface (UI-DETAIL §8, UI-SPEC §10). Actions wrap below the copy.
struct SmthzToast: View {
    let message: SmthzToastMessage
    let onDismiss: () -> Void
    var folded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var spinning = false
    @State private var closeHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                SmthzIcon.image(message.kind.icon).scaledToFit()
                    .frame(width: 16, height: 16)
                    .rotationEffect(.degrees(spinning && !reduceMotion ? 360 : 0))
                    .animation(message.kind == .loading && !reduceMotion
                        ? .linear(duration: 1).repeatForever(autoreverses: false) : nil,
                               value: spinning)
                    .padding(.top, 2)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(message.title)
                        .font(SmthzFont.ui(size: 14, weight: .medium))
                    if let description = message.description {
                        Text(description)
                            .font(SmthzFont.ui(size: 14))
                            .opacity(0.8)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let action = message.action {
                Button(action.title) {
                    action.perform()
                    onDismiss()
                }
                .buttonStyle(SmthzButtonStyle(.primary, size: .xs))
                .padding(.leading, 26)
                .padding(.top, 2)
            }
        }
        .opacity(folded ? 0 : 1)
        .smthzTracking(size: 14)
        .foregroundStyle(SmthzTheme.foreground)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: 416, alignment: .leading)
        .background(SmthzTheme.popover, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).strokeBorder(SmthzTheme.border, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
        .overlay(alignment: .topLeading) {
            if !folded {
                Button(action: onDismiss) {
                    SmthzIcon.image("x").scaledToFit().frame(width: 12, height: 12)
                        .frame(width: 20, height: 20)
                        .background(closeHovered ? SmthzTheme.accent : SmthzTheme.popover, in: Circle())
                        .overlay {
                            Circle().strokeBorder((colorScheme == .dark ? Color.white : .black)
                                .opacity(0.14), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .onHover { closeHovered = $0 }
                .offset(x: -8, y: -8)
                .accessibilityLabel("Dismiss notification")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(message.kind.rawValue.capitalized) notification")
        .onAppear { spinning = message.kind == .loading }
    }
}

/// Shows the last three notifications, folded until hovered.
private struct SmthzToastStack: View {
    let messages: [SmthzToastMessage]
    let dismiss: (UUID) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    @State private var frontHeight: CGFloat = 70

    private var visible: [SmthzToastMessage] { Array(messages.suffix(3)) }
    private var expanded: Bool { hovered }

    var body: some View {
        VStack(spacing: expanded ? 14 : 0) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, message in
                let depth = visible.count - index - 1
                SmthzToast(message: message, onDismiss: { dismiss(message.id) },
                            folded: !expanded && depth != 0)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        if depth == 0 { frontHeight = height }
                    }
                    .frame(height: expanded || depth == 0 ? nil : frontHeight, alignment: .top)
                    .clipped(disabled: expanded || depth == 0)
                    .scaleEffect(expanded ? 1 : 1 - CGFloat(depth) * 0.04, anchor: .bottom)
                    .padding(.bottom, expanded || depth == 0 ? 0 : -frontHeight)
                    .offset(y: expanded ? 0 : -CGFloat(depth) * 14)
                    .zIndex(Double(index))
                    .allowsHitTesting(expanded || depth == 0)
                    .accessibilityHidden(!expanded && depth != 0)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: 416)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: expanded)
        .overlay {
            // Timers belong to every queued message, including folded/hidden cards.
            ForEach(messages) { message in
                Color.clear.frame(width: 0, height: 0)
                    .task(id: "\(expanded)-\(message.kind.rawValue)") {
                        guard message.kind != .error, !expanded else { return }
                        do { try await Task.sleep(for: .seconds(4)) } catch { return }
                        guard !Task.isCancelled else { return }
                        dismiss(message.id)
                    }
            }
        }
    }
}

private extension View {
    @ViewBuilder func clipped(disabled: Bool) -> some View {
        if disabled { self } else { clipped() }
    }
}

private struct SmthzToastQueuePresentation: ViewModifier {
    @Binding var messages: [SmthzToastMessage]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottomTrailing) {
            if !messages.isEmpty {
                SmthzToastStack(messages: messages) { id in
                    messages.removeAll { $0.id == id }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 40)
                .zIndex(100)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: messages.map(\.id))
    }
}

/// Accumulates successive single-binding notifications instead of replacing the previous one.
private struct SmthzToastPresentation: ViewModifier {
    @Binding var message: SmthzToastMessage?
    @State private var messages: [SmthzToastMessage] = []

    func body(content: Content) -> some View {
        content.modifier(SmthzToastQueuePresentation(messages: $messages))
            .onChange(of: message, initial: true) { _, next in
                guard let next else { messages.removeAll(); return }
                if let index = messages.firstIndex(where: { $0.id == next.id }) {
                    messages[index] = next
                } else {
                    messages.append(next)
                }
            }
            .onChange(of: messages) { _, queue in
                if let current = message, !queue.contains(where: { $0.id == current.id }) {
                    // Do not clear older notifications when the latest one expires.
                    message = queue.last
                }
            }
    }
}

extension View {
    /// Compatible single-message binding; assigning a fresh message appends it to the stack.
    func smthzToast(_ message: Binding<SmthzToastMessage?>) -> some View {
        modifier(SmthzToastPresentation(message: message))
    }

    /// Explicit queue API for UI-29. Append to present, remove by id to dismiss/update.
    /// Apply to the window's complete content to keep the bottom clearance exactly 40 pt.
    func smthzToasts(_ messages: Binding<[SmthzToastMessage]>) -> some View {
        modifier(SmthzToastQueuePresentation(messages: messages))
    }
}

#if DEBUG
// VISUAL-ONLY: stub data until notification producers supply real messages in the shell.
private struct SmthzToastPreview: View {
    let scheme: ColorScheme
    @State private var actionTaken = false
    @State private var messages: [SmthzToastMessage] = []

    var body: some View {
        VStack(spacing: 14) {
            ForEach(SmthzToastMessage.Kind.allCases, id: \.self) { kind in
                SmthzToast(message: .init(title: "\(kind.rawValue.capitalized) notification",
                    description: "Notification details remain readable and selectable.", kind: kind,
                    action: .init(title: "Retry", perform: { actionTaken = true })), onDismiss: {})
            }
            Button(actionTaken ? "Action received — show stack" : "Show notification stack") {
                messages = SmthzToastMessage.Kind.allCases.map {
                    .init(title: "\($0.rawValue.capitalized) notification", kind: $0)
                }
            }
        }
        .padding(24)
        .frame(width: 600, height: 850)
        .background(SmthzTheme.background)
        .smthzToasts($messages)
        .preferredColorScheme(scheme)
    }
}

#Preview("Five toast types • light") { SmthzToastPreview(scheme: .light) }
#Preview("Five toast types • dark") { SmthzToastPreview(scheme: .dark) }
#endif

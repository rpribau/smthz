import AppKit
import SmthzCore
import SwiftUI

/// The §9 landing page. Supply real actions from the shell; no host or workspace side effects live here.
/// Use `variant: .hostNotRunning` with `onStartHost`/`onRetry`, or `.welcome` with project actions.
/// Supply `bindings` from the active registry; `shortcuts` optionally overrides the displayed rows.
struct LandingView: View {
    enum Variant { case welcome, hostNotRunning }
    struct Shortcut: Identifiable {
        var id: String { title }
        let title: String
        let keys: [String]
    }

    var variant: Variant = .welcome
    var hasProjects = false
    var createLabel = "Create workspace"
    var bindings: KeybindingRegistry = .defaults
    var shortcuts: [Shortcut]? = nil
    var preflightIssues: [String] = []

    private var displayedShortcuts: [Shortcut] {
        if let shortcuts { return shortcuts }
        var rows: [Shortcut] = []
        if let chord = bindings.chords(for: .workspaceCreate).first {
            rows.append(.init(title: "Create workspace", keys: KeyCapView.symbols(for: chord)))
        }
        for (title, action) in [("Move up workspace", KeybindingAction.worktreeNavigateUp),
                                ("Move down workspace", KeybindingAction.worktreeNavigateDown)] {
            if action.available, let chord = bindings.chords(for: action).first {
                rows.append(.init(title: title, keys: KeyCapView.symbols(for: chord)))
            }
        }
        return rows
    }
    var onAddProject: (() -> Void)? = nil
    var onCreateWorkspace: (() -> Void)? = nil
    var onStartHost: (() -> Void)? = nil
    var onRetry: (() -> Void)? = nil

    private var hint: String {
        if variant == .hostNotRunning { return "Start the local host to connect to your workspaces." }
        return hasProjects ? "Select a workspace from the sidebar to begin." : "Add a project to get started."
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                logoTile
                Text("smthz")
                    .font(SmthzFont.ui(size: 36, weight: .bold))
                    .tracking(-0.9)
                    .foregroundStyle(SmthzTheme.foreground)
                if !preflightIssues.isEmpty { preflightCard }
                if variant == .hostNotRunning {
                    Text("Host not running")
                        .font(SmthzFont.ui(size: 18, weight: .semibold))
                        .foregroundStyle(SmthzTheme.foreground)
                }
                Text(hint)
                    .font(SmthzFont.ui(size: 14))
                    .foregroundStyle(SmthzTheme.mutedForeground)
                    .multilineTextAlignment(.center)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { actions }
                    VStack(spacing: 10) { actions }
                }
                if variant == .welcome {
                    VStack(spacing: 12) {
                        ForEach(displayedShortcuts) { shortcut in
                            HStack(spacing: 12) {
                                Text(shortcut.title)
                                    .font(SmthzFont.ui(size: 14))
                                    .foregroundStyle(SmthzTheme.mutedForeground)
                                Spacer(minLength: 0)
                                KeyCapView.combo(shortcut.keys)
                            }
                        }
                    }
                    .frame(maxWidth: 320)
                    .padding(.top, 24)
                }
            }
            .frame(maxWidth: 512)
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity)
            .frame(minHeight: availableHeight)
        }
        .background(SmthzTheme.background)
        .overlay {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { availableHeight = geometry.size.height }
                    .onChange(of: geometry.size.height) { _, height in availableHeight = height }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    @State private var availableHeight: CGFloat = 0

    @ViewBuilder private var actions: some View {
        if variant == .hostNotRunning {
            action("Start host", icon: .server, action: onStartHost)
            action("Try again", icon: .history, action: onRetry)
        } else {
            action("Add project", icon: .folderPlus, action: onAddProject)
            action(createLabel, icon: .gitBranchPlus, action: onCreateWorkspace)
        }
    }

    private func action(_ title: String, icon: SmthzIcon.Name, action: (() -> Void)?) -> some View {
        Button { action?() } label: {
            HStack(spacing: 8) {
                SmthzIcon.image(icon).resizable().scaledToFit().frame(width: 14, height: 14)
                    .accessibilityHidden(true)
                Text(title)
            }
        }
        .buttonStyle(SmthzButtonStyle(.landing))
        .disabled(action == nil)
    }

    private var preflightCard: some View {
        HStack(alignment: .top, spacing: 10) {
            SmthzIcon.image("triangle-alert").resizable().scaledToFit()
                .frame(width: 16, height: 16).foregroundStyle(SmthzTheme.statusWarning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(preflightIssues.enumerated()), id: \.offset) { _, issue in
                    Text(issue).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .font(SmthzFont.ui(size: 13))
        .foregroundStyle(SmthzTheme.foreground)
        .padding(12).frame(maxWidth: 384, alignment: .leading)
        .background(SmthzTheme.muted.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(SmthzTheme.border.opacity(0.8)))
        .accessibilityElement(children: .combine)
    }

    private var logoTile: some View {
        RoundedRectangle(cornerRadius: 18)
            .fill(Color(red: 18.0 / 255, green: 24.0 / 255, blue: 30.0 / 255))
            .frame(width: 80, height: 80)
            .overlay {
                if let icon = Self.productIcon {
                    Image(nsImage: icon).resizable().scaledToFit().frame(width: 48, height: 48)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18).strokeBorder(SmthzTheme.border.opacity(0.8), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.4), radius: 15, y: 10)
            .accessibilityHidden(true)
    }

    /// Packaged apps use the icon generated from icon/icon.png; previews use the read-only source asset.
    private static var productIcon: NSImage? {
        for name in ["icon", "smthz"] {
            for ext in ["png", "icns"] {
                if let url = Bundle.main.url(forResource: name, withExtension: ext),
                   let image = NSImage(contentsOf: url) { return image }
            }
        }
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return NSImage(contentsOf: sourceRoot.appendingPathComponent("icon/icon.png"))
    }
}

#Preview("Landing • light") {
    LandingView(onAddProject: {}, onCreateWorkspace: {})
        .frame(width: 640, height: 540).preferredColorScheme(.light)
}

#Preview("Host not running • dark") {
    LandingView(variant: .hostNotRunning, onStartHost: {}, onRetry: {})
        .frame(width: 600, height: 400).preferredColorScheme(.dark)
}

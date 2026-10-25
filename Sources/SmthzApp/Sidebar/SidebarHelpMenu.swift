import AppKit
import SwiftUI

/// Bottom-toolbar Help dropdown (UI-DETAIL §2.6).
/// Docs / Changelog / GitHub / Discord / X are omitted until smthz URLs exist (UI-GAP2 WP UI-15).
struct SidebarHelpMenu: View {
    var onKeyboardShortcuts: () -> Void = {}
    var onSendFeedback: () -> Void = {}
    var onOnboarding: () -> Void = {}
    var onCheckForUpdates: () -> Void = {}
    /// nil relaunches the app bundle.
    var onRestart: (() -> Void)? = nil

    var body: some View {
        Menu {
            Button { onKeyboardShortcuts() } label: { item("Keyboard Shortcuts", .keyboard) }
            Divider()
            Button { onSendFeedback() } label: { item("Send Feedback", "message-square-text") }
            Button { onOnboarding() } label: { item("Onboarding", "school") }
            Divider()
            Button { onCheckForUpdates() } label: { item("Check for Updates", "refresh-cw") }
            Divider()
            Button { (onRestart ?? { Self.relaunch() })() } label: { item("Restart smthz", "rotate-cw") }
        } label: {
            SidebarIconLabel(icon: .circleHelp, size: 12, stroke: 2, tint: SmthzTheme.mutedForeground)
        }
        .menuStyle(.button).buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .smthzTooltip("Help", edge: .top)
        .accessibilityLabel("Help")
    }

    private func item(_ title: String, _ icon: SmthzIcon.Name) -> some View {
        Label {
            Text(title)
        } icon: {
            if let image = SmthzIcon.nsImage(icon)?.copy() as? NSImage {
                let _ = image.size = NSSize(width: 14, height: 14)
                Image(nsImage: image)
            }
        }
    }

    /// Opens a fresh instance of the running bundle, then quits this one.
    @MainActor static func relaunch() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

import AppKit
import SwiftUI
import Observation

/// UI-29 injects this value into ShellView's environment. ShellLayout publishes it
/// to the active scene so menus always address the focused window, including a terminal.
struct SmthzShellActions: Sendable {
    enum Action: Sendable {
        case newTerminal, closeTab, renameTab, clearTerminal, recentTab
        case selectTab(Int), jumpPalette, quickOpen, settings, keyboardShortcuts
        case showExplorer, showSourceControl, showPorts, explore, gettingStarted
    }
    var perform: @MainActor @Sendable (Action) -> Void = { _ in }
}

private struct SmthzShellActionsKey: EnvironmentKey {
    static let defaultValue = SmthzShellActions()
}
private struct SmthzFocusedShellActionsKey: FocusedValueKey {
    typealias Value = SmthzShellActions
}
extension EnvironmentValues {
    var smthzShellActions: SmthzShellActions {
        get { self[SmthzShellActionsKey.self] }
        set { self[SmthzShellActionsKey.self] = newValue }
    }
}
extension FocusedValues {
    var smthzShellActions: SmthzShellActions? {
        get { self[SmthzFocusedShellActionsKey.self] }
        set { self[SmthzFocusedShellActionsKey.self] = newValue }
    }
}

@main
struct SmthzApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let model = AppModel()

    var body: some Scene {
        WindowGroup("Workspaces") {
            SmthzUIZoom {
                ShellView(appModel: model)
                    .onAppear { delegate.shell = model.workspace }
            }
            .frame(minWidth: 600, minHeight: 400)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: NSScreen.main?.visibleFrame.width ?? 1100,
                     height: NSScreen.main?.visibleFrame.height ?? 760)
        .commands { SmthzShellCommands(); SmthzHostCommands() }
    }
}

/// UI zoom changes the complete interface; terminal typography keeps its own setting.
private struct SmthzUIZoom<Content: View>: View {
    @AppStorage("shell.uiZoom") private var storedZoom = 1.0
    @AppStorage("appearance.theme") private var theme = "system"
    @ViewBuilder var content: () -> Content
    private var zoom: Double { storedZoom.isFinite ? min(1.5, max(0.75, storedZoom)) : 1 }

    var body: some View {
        GeometryReader { geometry in
            content()
                .frame(width: geometry.size.width / zoom, height: geometry.size.height / zoom)
                .scaleEffect(zoom, anchor: .topLeading)
        }
        .onChange(of: theme, initial: true) { _, mode in
            TerminalSettingsModel.applyAppTheme(mode)
        }
    }
}

struct SmthzShellCommands: Commands {
    @FocusedValue(\.smthzShellActions) private var actions
    @AppStorage("shell.sidebarOpen") private var sidebarOpen = true
    @AppStorage("shell.rightSidebarOpen") private var rightSidebarOpen = true
    @AppStorage("shell.showStatusBar") private var showStatusBar = true
    @AppStorage("shell.showTitlebarAppName") private var showAppName = true
    @AppStorage("sidebar.showTasksButton") private var showTasks = true
    @AppStorage("sidebar.showAutomationsButton") private var showAutomations = true
    @AppStorage("sidebar.showMobileButton") private var showMobile = true
    @AppStorage("shell.uiZoom") private var zoom = 1.0

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            action("Settings…", .settings, key: ",")
        }
        CommandGroup(replacing: .newItem) {
            action("New Terminal", .newTerminal, key: "t")
        }
        CommandGroup(replacing: .saveItem) {
            action("Close Tab", .closeTab, key: "w")
            action("Rename Tab…", .renameTab, key: "r")
        }
        CommandGroup(replacing: .sidebar) {
            Button("Toggle Left Sidebar") { sidebarOpen.toggle() }
                .keyboardShortcut("b", modifiers: .command)
            Button("Toggle Right Sidebar") { rightSidebarOpen.toggle() }
                .keyboardShortcut("l", modifiers: .command)
            Toggle("Show Status Bar", isOn: $showStatusBar)
            Menu("Appearance") {
                Toggle("Show Tasks Button", isOn: $showTasks)
                Toggle("Show Automations Button", isOn: $showAutomations)
                Toggle("Show smthz Mobile Button", isOn: $showMobile)
                Toggle("Show Titlebar App Name", isOn: $showAppName)
            }
            Divider()
            action("Open Worktree Palette", .jumpPalette, key: "j")
            action("Go to File…", .quickOpen, key: "p")
            Divider()
            action("Show Explorer", .showExplorer, key: "e", modifiers: [.command, .shift])
            action("Show Source Control", .showSourceControl, key: "g", modifiers: [.command, .shift])
            action("Show Ports", .showPorts, key: "i", modifiers: [.command, .shift])
            Divider()
            Button("Reset Size") { zoom = 1 }.keyboardShortcut("0", modifiers: .command)
            Button("Zoom In") { zoom = min(1.5, zoom + 0.1) }.keyboardShortcut("=", modifiers: .command)
            Button("Zoom Out") { zoom = max(0.75, zoom - 0.1) }.keyboardShortcut("-", modifiers: .command)
        }
        CommandMenu("Terminal") {
            action("Clear Screen", .clearTerminal, key: "k")
            action("Previous Recent Tab", .recentTab, key: .tab, modifiers: .control)
            Menu("Select Tab") {
                ForEach(1...9, id: \.self) { index in
                    action("Tab \(index)", .selectTab(index), key: KeyEquivalent(Character(String(index))), modifiers: .control)
                }
            }
        }
        CommandGroup(replacing: .help) {
            Button("Explore smthz") { actions?.perform(.explore) }
            Button("Getting Started with smthz") { actions?.perform(.gettingStarted) }
            Divider()
            Button("Keyboard Shortcuts") { actions?.perform(.keyboardShortcuts) }
        }
    }

    private func action(_ title: String, _ action: SmthzShellActions.Action,
                        key: KeyEquivalent, modifiers: EventModifiers = .command) -> some View {
        Button(title) { actions?.perform(action) }.keyboardShortcut(key, modifiers: modifiers)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var shell: ShellController?
    func applicationWillTerminate(_ notification: Notification) { shell?.flush() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// The App owns reference-backed UI state without relying on SwiftUI macros.
@MainActor @Observable
final class AppModel {
    let workspace = ShellController()
    var destination: Destination? = .workspaces
    var columns: NavigationSplitViewVisibility = .all
}

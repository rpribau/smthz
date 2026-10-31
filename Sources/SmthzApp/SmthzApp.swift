import AppKit
import SwiftUI
import Observation
import SmthzCore

/// UI-29 injects this value into ShellView's environment. ShellLayout publishes it
/// to the active scene so menus always address the focused window, including a terminal.
struct SmthzShellActions: Sendable {
    enum Action: Sendable {
        case keybinding(KeybindingAction, index: Int?)
        case newTerminal, closeTab, renameTab, clearTerminal, recentTab
        case selectTab(Int), jumpPalette, quickOpen, settings, keyboardShortcuts
        case showExplorer, showSourceControl, showPorts, explore, gettingStarted
    }
    var canPerform: @MainActor @Sendable (KeybindingAction) -> Bool = { $0.available }
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

    private var bindings: SmthzKeybindings { .shared }
    var body: some Commands {
        CommandGroup(replacing: .appSettings) { action(.appSettings) }
        CommandGroup(replacing: .newItem) {
            action(.tabNewTerminal)
            action(.workspaceCreate)
            Button("New Window") {}.keyboardShortcut(bindings.shortcut(KeybindingRegistry.nativeNewWindowChord)).disabled(true)
        }
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { NSApp.sendAction(#selector(NSText.cut(_:)), to: NSApp.keyWindow?.firstResponder, from: nil) }
                .keyboardShortcut(bindings.shortcut(KeybindingRegistry.nativeCutChord)).disabled(!bindings.editingNativeText)
            editingAction(.terminalCopySelection, selector: "copy:")
            editingAction(.terminalPaste, selector: "paste:")
            editingAction(.terminalSelectAll, selector: "selectAll:")
        }
        CommandGroup(replacing: .saveItem) {
            action(.tabClose); action(.tabCloseAll); action(.tabReopenClosed); action(.tabRename)
        }
        CommandGroup(replacing: .sidebar) {
            action(.sidebarLeftToggle); action(.sidebarRightToggle)
            Toggle("Show Status Bar", isOn: $showStatusBar)
            Menu("Appearance") {
                Toggle("Show Tasks Button", isOn: $showTasks)
                Toggle("Show Automations Button", isOn: $showAutomations)
                Toggle("Show smthz Mobile Button", isOn: $showMobile)
                Toggle("Show Titlebar App Name", isOn: $showAppName)
            }
            Divider()
            action(.worktreePalette); action(.worktreeQuickOpen)
            action(.sidebarExplorerToggle); action(.sidebarSearchToggle); action(.sidebarSourceControlToggle)
            action(.sidebarChecksToggle); action(.sidebarPortsToggle)
            Divider()
            action(.zoomReset); action(.zoomIn); action(.zoomOut)
            action(.appForceReload)
        }
        CommandMenu("Tabs") {
            ForEach(KeybindingRegistry.definitions.filter { $0.scope == .tabs && ![KeybindingAction.tabClose, .tabCloseAll, .tabReopenClosed, .tabRename, .tabNewTerminal, .tabSelectByIndex].contains($0.action) }, id: \.action) { definition in
                action(definition.action)
            }
            Menu("Select Tab") {
                ForEach(0..<9, id: \.self) { index in
                    Button("Tab \(index + 1)") { actions?.perform(.keybinding(.tabSelectByIndex, index: index)) }
                        .keyboardShortcut(bindings.shortcut(.tabSelectByIndex, index: index))
                        .disabled(actions?.canPerform(.tabSelectByIndex) != true)
                }
            }
        }
        CommandMenu("Terminal") {
            ForEach(KeybindingRegistry.definitions.filter { $0.scope == .terminal }, id: \.action) { definition in action(definition.action) }
        }
        CommandMenu("Other Actions") {
            ForEach(KeybindingScope.allCases.filter { ![KeybindingScope.tabs, .terminal].contains($0) }, id: \.self) { scope in
                Menu(scope.rawValue.capitalized) {
                    ForEach(KeybindingRegistry.definitions.filter { $0.scope == scope }, id: \.action) { definition in action(definition.action) }
                }
            }
        }
        CommandGroup(replacing: .help) {
            Button("Explore smthz") { actions?.perform(.explore) }
            Button("Getting Started with smthz") { actions?.perform(.gettingStarted) }
            Divider()
            Button("Keyboard Shortcuts") { actions?.perform(.keyboardShortcuts) }
            Button("Check for Updates…") { unavailable("Update checking") }
            Button("Report Crash…") { unavailable("Crash reporting") }
        }
    }
    private func unavailable(_ title: String) {
        let alert = NSAlert(); alert.messageText = title
        alert.informativeText = "Not available yet."; alert.runModal()
    }
    private func editingAction(_ action: KeybindingAction, selector: String) -> some View {
        let chord = (bindings.editingNativeText ? KeybindingRegistry.defaults : bindings.registry).chords(for: action).first
        return Button(action.definition.title) {
            NSApp.sendAction(Selector(selector), to: NSApp.keyWindow?.firstResponder, from: nil)
        }
        .keyboardShortcut(chord.flatMap { bindings.shortcut($0) })
        .disabled(!bindings.editingNativeText && actions?.canPerform(action) != true)
    }
    private func action(_ action: KeybindingAction) -> some View {
        Button(action.definition.title) { actions?.perform(.keybinding(action, index: nil)) }
            .keyboardShortcut(bindings.shortcut(action))
            .disabled(!action.available || actions?.canPerform(action) != true)
            .help(action.available ? action.definition.title : "Not available yet")
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

import Foundation

/// A key plus modifiers, parsed from Orca keybinding strings such as
/// `"Mod+Shift+BracketRight"`. `Mod` is Command on macOS.
public struct KeyChord: Hashable, Sendable, Codable {
    public var key: String
    public var command: Bool
    public var option: Bool
    public var control: Bool
    public var shift: Bool

    public init(key: String, command: Bool = false, option: Bool = false, control: Bool = false, shift: Bool = false) {
        self.key = key
        self.command = command
        self.option = option
        self.control = control
        self.shift = shift
    }

    /// Orca form with a stable modifier order: Mod, Ctrl, Alt, Shift.
    public var formatted: String {
        var parts: [String] = []
        if command { parts.append("Mod") }
        if control { parts.append("Ctrl") }
        if option { parts.append("Alt") }
        if shift { parts.append("Shift") }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    public static func parse(_ text: String) throws -> KeyChord {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw KeyChordParseError.empty }

        // A literal trailing "+" is the key itself ("Mod++").
        var body = trimmed
        var keyToken: String?
        if body.hasSuffix("+") {
            body.removeLast()
            if body.isEmpty { keyToken = "+" } else if body.hasSuffix("+") {
                body.removeLast()
                keyToken = "+"
            } else {
                throw KeyChordParseError.missingKey(text)
            }
        }
        var tokens = body.isEmpty ? [] : body.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        if keyToken == nil {
            guard let last = tokens.popLast() else { throw KeyChordParseError.missingKey(text) }
            keyToken = last
        }

        var chord = KeyChord(key: "")
        for raw in tokens {
            switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
            case "mod", "cmd", "command", "meta": chord.command = true
            case "ctrl", "control": chord.control = true
            case "alt", "option", "opt": chord.option = true
            case "shift": chord.shift = true
            default: throw KeyChordParseError.unknownModifier(raw)
            }
        }
        guard let key = normalizeKey(keyToken ?? "") else {
            throw KeyChordParseError.unknownKey(keyToken ?? "")
        }
        chord.key = key
        return chord
    }

    private static let symbolKeys: [String: String] = [
        "[": "BracketLeft", "]": "BracketRight", "-": "Minus", "=": "Equal", "+": "Plus",
        ",": "Comma", ".": "Period", "/": "Slash", "\\": "Backslash", ";": "Semicolon",
        "'": "Quote", "`": "Backquote",
    ]

    private static let namedKeys: [String: String] = {
        let names = [
            "Enter", "Tab", "Escape", "Space", "Backspace", "Delete", "Insert", "Home", "End",
            "PageUp", "PageDown", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight",
            "BracketLeft", "BracketRight", "Minus", "Equal", "Plus", "Comma", "Period", "Slash",
            "Backslash", "Semicolon", "Quote", "Backquote", "NumpadAdd", "NumpadSubtract",
        ]
        var map: [String: String] = [:]
        for name in names { map[name.lowercased()] = name }
        let aliases = [
            "return": "Enter", "esc": "Escape", "spacebar": "Space", "pgup": "PageUp",
            "pgdn": "PageDown", "left": "ArrowLeft", "right": "ArrowRight", "up": "ArrowUp",
            "down": "ArrowDown", "del": "Delete", "ins": "Insert", "add": "NumpadAdd",
            "subtract": "NumpadSubtract",
        ]
        for (alias, name) in aliases { map[alias] = name }
        return map
    }()

    private static func normalizeKey(_ token: String) -> String? {
        let t = token.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        if let symbol = symbolKeys[t] { return symbol }
        if t.count == 1, let scalar = t.unicodeScalars.first {
            if CharacterSet.decimalDigits.contains(scalar), scalar.isASCII { return t }
            if CharacterSet.letters.contains(scalar), scalar.isASCII { return t.uppercased() }
            return nil
        }
        let lower = t.lowercased()
        if let named = namedKeys[lower] { return named }
        if lower.hasPrefix("f"), let n = Int(lower.dropFirst()), (1...24).contains(n) { return "F\(n)" }
        return nil
    }
}

public enum KeyChordParseError: Error, Equatable, Sendable {
    case empty
    case missingKey(String)
    case unknownModifier(String)
    case unknownKey(String)
}

/// Orca 1.4.238's complete 91-action registry. Unavailable actions retain their
/// metadata and defaults for the editor, but are never dispatched by the app.
public enum KeybindingAction: String, CaseIterable, Sendable, Codable {
    case worktreeQuickOpen = "worktree.quickOpen"
    case appSettings = "app.settings"
    case appForceReload = "app.forceReload"
    case worktreePalette = "worktree.palette"
    case worktreeNavigateUp = "worktree.navigateUp"
    case worktreeNavigateDown = "worktree.navigateDown"
    case workspaceCreate = "workspace.create"
    case workspaceRename = "workspace.rename"
    case workspaceDelete = "workspace.delete"
    case workspaceOpenBoard = "workspace.openBoard"
    case dashboardToggle = "dashboard.toggle"
    case workspaceSelectByIndex = "workspace.selectByIndex"
    case voiceDictation = "voice.dictation"
    case viewTasks = "view.tasks"
    case sidebarLeftToggle = "sidebar.left.toggle"
    case sidebarRightToggle = "sidebar.right.toggle"
    case sidebarExplorerToggle = "sidebar.explorer.toggle"
    case sidebarSearchToggle = "sidebar.search.toggle"
    case sidebarSourceControlToggle = "sidebar.sourceControl.toggle"
    case sidebarChecksToggle = "sidebar.checks.toggle"
    case sidebarPortsToggle = "sidebar.ports.toggle"
    case sidebarSleepingWorkspacesToggle = "sidebar.sleepingWorkspaces.toggle"
    case sidebarFocusWorktreeList = "sidebar.focusWorktreeList"
    case floatingTerminalToggle = "floatingTerminal.toggle"
    case floatingWorkspaceMaximize = "floatingWorkspace.maximize"
    case floatingWorkspaceMinimize = "floatingWorkspace.minimize"
    case zoomIn = "zoom.in"
    case zoomOut = "zoom.out"
    case zoomReset = "zoom.reset"
    case worktreeHistoryBack = "worktree.history.back"
    case worktreeHistoryForward = "worktree.history.forward"
    case tabNewTerminal = "tab.newTerminal"
    case tabNewAgent = "tab.newAgent"
    case tabNewBrowser = "tab.newBrowser"
    case tabNewSimulator = "tab.newSimulator"
    case tabNewMarkdown = "tab.newMarkdown"
    case tabOpenMarkdown = "tab.openMarkdown"
    case tabClose = "tab.close"
    case tabCloseAll = "tab.closeAll"
    case tabRename = "tab.rename"
    case tabReopenClosed = "tab.reopenClosed"
    case tabNextSameType = "tab.nextSameType"
    case tabPreviousSameType = "tab.previousSameType"
    case tabNextAllTypes = "tab.nextAllTypes"
    case tabPreviousAllTypes = "tab.previousAllTypes"
    case tabPreviousRecent = "tab.previousRecent"
    case tabNextTerminal = "tab.nextTerminal"
    case tabPreviousTerminal = "tab.previousTerminal"
    case tabSelectByIndex = "tab.selectByIndex"
    case tabOpenQuickCommandsMenu = "tab.openQuickCommandsMenu"
    case browserFind = "browser.find"
    case browserBack = "browser.back"
    case browserForward = "browser.forward"
    case browserReload = "browser.reload"
    case browserHardReload = "browser.hardReload"
    case browserFocusAddressBar = "browser.focusAddressBar"
    case browserGrabElement = "browser.grabElement"
    case browserAnnotateElement = "browser.annotateElement"
    case editorFind = "editor.find"
    case editorReplace = "editor.replace"
    case editorSave = "editor.save"
    case editorMarkdownPreview = "editor.markdownPreview"
    case editorToggleWordWrap = "editor.toggleWordWrap"
    case editorCopyContext = "editor.copyContext"
    case editorPreviousChange = "editor.previousChange"
    case editorNextChange = "editor.nextChange"
    case editorAddReviewNote = "editor.addReviewNote"
    case sourceControlSendReviewNotes = "sourceControl.sendReviewNotes"
    case fileExplorerUndo = "fileExplorer.undo"
    case fileExplorerRedo = "fileExplorer.redo"
    case fileExplorerCopyPath = "fileExplorer.copyPath"
    case fileExplorerCopyRelativePath = "fileExplorer.copyRelativePath"
    case fileExplorerDelete = "fileExplorer.delete"
    case settingsSearch = "settings.search"
    case terminalCopySelection = "terminal.copySelection"
    case terminalSelectAll = "terminal.selectAll"
    case terminalPaste = "terminal.paste"
    case terminalSearch = "terminal.search"
    case terminalClear = "terminal.clear"
    case terminalFocusNextPane = "terminal.focusNextPane"
    case terminalFocusPreviousPane = "terminal.focusPreviousPane"
    case terminalEqualizePaneSizes = "terminal.equalizePaneSizes"
    case terminalExpandPane = "terminal.expandPane"
    case terminalSetTitle = "terminal.setTitle"
    case chatFind = "chat.find"
    case sidebarChildWorkspacesToggle = "sidebar.childWorkspaces.toggle"
    case terminalClearPaneTitle = "terminal.clearPaneTitle"
    case terminalClosePane = "terminal.closePane"
    case terminalSplitRight = "terminal.splitRight"
    case terminalSplitDown = "terminal.splitDown"
    case terminalSwitchInputSource = "terminal.switchInputSource"

    public var definition: KeybindingDefinition { KeybindingRegistry.definitions.first { $0.action == self }! }
    public var scope: KeybindingScope { definition.scope }
    public var available: Bool { definition.available }
}

public enum KeybindingScope: String, CaseIterable, Sendable {
    case window = "global"
    case tabs, terminal, browser, editor, fileExplorer, settings, chat
}

public struct KeybindingDefinition: Sendable {
    public let action: KeybindingAction
    public let title: String
    public let group: String
    public let scope: KeybindingScope
    public let conflictGroup: String?
    public let available: Bool
    public let defaultBindings: [String]
}

public struct KeybindingDiagnostic: Equatable, Sendable {
    public enum Severity: String, Sendable { case warning, error }
    public var severity: Severity
    public var message: String
    public var actionID: String?

    public init(severity: Severity, message: String, actionID: String? = nil) {
        self.severity = severity
        self.message = message
        self.actionID = actionID
    }
}

public struct KeybindingRegistry: Sendable {
    private let bindings: [KeybindingAction: [KeyChord]]

    public init(bindings: [KeybindingAction: [KeyChord]]) {
        self.bindings = bindings
    }

    /// Ordered exactly like definitions-core-1...4.ts. D7 reserves Cmd-N for
    /// native windows; Cmd-Shift-N opens the workspace composer. Zoom changes
    /// terminal typography, not the native interface scale.
    public static let definitions: [KeybindingDefinition] = [
        .init(action: .worktreeQuickOpen, title: "Go to File", group: "Global", scope: .window, conflictGroup: nil, available: true, defaultBindings: ["Mod+P"]),
        .init(action: .appSettings, title: "Open Settings", group: "Global", scope: .window, conflictGroup: "menu", available: true, defaultBindings: []),
        .init(action: .appForceReload, title: "Force Reload", group: "Global", scope: .window, conflictGroup: "menu", available: true, defaultBindings: ["Mod+Shift+R"]),
        .init(action: .worktreePalette, title: "Switch worktree", group: "Global", scope: .window, conflictGroup: nil, available: true, defaultBindings: ["Mod+J"]),
        .init(action: .worktreeNavigateUp, title: "Previous worktree", group: "Global", scope: .window, conflictGroup: nil, available: false, defaultBindings: ["Mod+Shift+ArrowUp"]),
        .init(action: .worktreeNavigateDown, title: "Next worktree", group: "Global", scope: .window, conflictGroup: nil, available: false, defaultBindings: ["Mod+Shift+ArrowDown"]),
        .init(action: .workspaceCreate, title: "Create worktree", group: "Global", scope: .window, conflictGroup: nil, available: true, defaultBindings: ["Mod+Shift+N"]),
        .init(action: .workspaceRename, title: "Rename worktree", group: "Global", scope: .window, conflictGroup: "workspace-shell", available: false, defaultBindings: ["Mod+Alt+R"]),
        .init(action: .workspaceDelete, title: "Delete Workspace", group: "Global", scope: .window, conflictGroup: nil, available: false, defaultBindings: ["Mod+Shift+Backspace"]),
        .init(action: .workspaceOpenBoard, title: "Toggle Workspace Board", group: "Global", scope: .window, conflictGroup: nil, available: false, defaultBindings: []),
        .init(action: .dashboardToggle, title: "Toggle Agent Dashboard", group: "Global", scope: .window, conflictGroup: nil, available: false, defaultBindings: []),
        .init(action: .workspaceSelectByIndex, title: "Select Workspace 1–9", group: "Global", scope: .window, conflictGroup: nil, available: false, defaultBindings: ["Mod+1"]),
        .init(action: .voiceDictation, title: "Dictation", group: "Global", scope: .window, conflictGroup: nil, available: false, defaultBindings: ["Mod+E"]),
        .init(action: .viewTasks, title: "Open Tasks", group: "Global", scope: .window, conflictGroup: nil, available: true, defaultBindings: []),
        .init(action: .sidebarLeftToggle, title: "Toggle Sidebar", group: "Global", scope: .window, conflictGroup: nil, available: true, defaultBindings: ["Mod+B"]),
        .init(action: .sidebarRightToggle, title: "Toggle Right Sidebar", group: "Global", scope: .window, conflictGroup: nil, available: true, defaultBindings: ["Mod+L"]),
        .init(action: .sidebarExplorerToggle, title: "Show Explorer", group: "Global", scope: .window, conflictGroup: nil, available: true, defaultBindings: ["Mod+Shift+E"]),
        .init(action: .sidebarSearchToggle, title: "Show Search", group: "Global", scope: .window, conflictGroup: nil, available: true, defaultBindings: ["Mod+Shift+F"]),
        .init(action: .sidebarSourceControlToggle, title: "Show Source Control", group: "Global", scope: .window, conflictGroup: nil, available: true, defaultBindings: ["Mod+Shift+G"]),
        .init(action: .sidebarChecksToggle, title: "Show Checks", group: "Global", scope: .window, conflictGroup: nil, available: true, defaultBindings: []),
        .init(action: .sidebarPortsToggle, title: "Show Ports", group: "Global", scope: .window, conflictGroup: nil, available: true, defaultBindings: ["Mod+Shift+I"]),
        .init(action: .sidebarSleepingWorkspacesToggle, title: "Toggle Sleeping Workspaces", group: "Global", scope: .window, conflictGroup: nil, available: false, defaultBindings: []),
        .init(action: .sidebarFocusWorktreeList, title: "Focus worktree list", group: "Global", scope: .window, conflictGroup: nil, available: false, defaultBindings: ["Mod+Shift+0"]),
        .init(action: .floatingTerminalToggle, title: "Toggle Floating Terminal", group: "Global", scope: .window, conflictGroup: nil, available: false, defaultBindings: ["Mod+Alt+A"]),
        .init(action: .floatingWorkspaceMaximize, title: "Maximize Floating Workspace Panel", group: "Global", scope: .window, conflictGroup: nil, available: false, defaultBindings: ["Mod+Alt+Shift+A"]),
        .init(action: .floatingWorkspaceMinimize, title: "Minimize Floating Workspace Panel", group: "Global", scope: .window, conflictGroup: nil, available: false, defaultBindings: []),
        .init(action: .zoomIn, title: "Zoom In", group: "Global", scope: .window, conflictGroup: nil, available: true, defaultBindings: ["Mod+Equal", "Mod+Shift+Plus", "Mod+NumpadAdd"]),
        .init(action: .zoomOut, title: "Zoom Out", group: "Global", scope: .window, conflictGroup: nil, available: true, defaultBindings: ["Mod+Minus", "Mod+NumpadSubtract"]),
        .init(action: .zoomReset, title: "Reset Size", group: "Global", scope: .window, conflictGroup: nil, available: true, defaultBindings: ["Mod+0"]),
        .init(action: .worktreeHistoryBack, title: "Worktree History Back", group: "Global", scope: .window, conflictGroup: nil, available: false, defaultBindings: ["Mod+Alt+ArrowLeft"]),
        .init(action: .worktreeHistoryForward, title: "Worktree History Forward", group: "Global", scope: .window, conflictGroup: nil, available: false, defaultBindings: ["Mod+Alt+ArrowRight"]),
        .init(action: .tabNewTerminal, title: "New terminal tab", group: "Tabs", scope: .tabs, conflictGroup: nil, available: true, defaultBindings: ["Mod+T"]),
        .init(action: .tabNewAgent, title: "New agent tab (default agent)", group: "Tabs", scope: .tabs, conflictGroup: nil, available: false, defaultBindings: ["Mod+Alt+T"]),
        .init(action: .tabNewBrowser, title: "New browser tab", group: "Tabs", scope: .tabs, conflictGroup: nil, available: false, defaultBindings: ["Mod+Shift+B"]),
        .init(action: .tabNewSimulator, title: "New mobile emulator tab", group: "Tabs", scope: .tabs, conflictGroup: nil, available: false, defaultBindings: ["Mod+Alt+Shift+E"]),
        .init(action: .tabNewMarkdown, title: "New markdown tab", group: "Tabs", scope: .tabs, conflictGroup: nil, available: false, defaultBindings: ["Mod+Shift+M"]),
        .init(action: .tabOpenMarkdown, title: "Open markdown tab", group: "Tabs", scope: .tabs, conflictGroup: nil, available: false, defaultBindings: ["Mod+Shift+O"]),
        .init(action: .tabClose, title: "Close active tab", group: "Tabs", scope: .tabs, conflictGroup: nil, available: true, defaultBindings: ["Mod+W"]),
        .init(action: .tabCloseAll, title: "Close all editor tabs", group: "Tabs", scope: .tabs, conflictGroup: nil, available: true, defaultBindings: ["Mod+Alt+W"]),
        .init(action: .tabRename, title: "Rename active tab", group: "Tabs", scope: .tabs, conflictGroup: "workspace-shell", available: true, defaultBindings: ["Mod+R"]),
        .init(action: .tabReopenClosed, title: "Reopen closed tab", group: "Tabs", scope: .tabs, conflictGroup: nil, available: true, defaultBindings: ["Mod+Shift+T"]),
        .init(action: .tabNextSameType, title: "Next tab (same type)", group: "Tab Navigation", scope: .tabs, conflictGroup: nil, available: true, defaultBindings: ["Mod+Alt+BracketRight"]),
        .init(action: .tabPreviousSameType, title: "Previous tab (same type)", group: "Tab Navigation", scope: .tabs, conflictGroup: nil, available: true, defaultBindings: ["Mod+Alt+BracketLeft"]),
        .init(action: .tabNextAllTypes, title: "Next tab (all types)", group: "Tab Navigation", scope: .tabs, conflictGroup: nil, available: true, defaultBindings: ["Mod+Shift+BracketRight"]),
        .init(action: .tabPreviousAllTypes, title: "Previous tab (all types)", group: "Tab Navigation", scope: .tabs, conflictGroup: nil, available: true, defaultBindings: ["Mod+Shift+BracketLeft"]),
        .init(action: .tabPreviousRecent, title: "Previous recent tab", group: "Tab Navigation", scope: .tabs, conflictGroup: nil, available: true, defaultBindings: ["Ctrl+Tab"]),
        .init(action: .tabNextTerminal, title: "Next terminal tab", group: "Tab Navigation", scope: .tabs, conflictGroup: nil, available: true, defaultBindings: ["Ctrl+PageDown"]),
        .init(action: .tabPreviousTerminal, title: "Previous terminal tab", group: "Tab Navigation", scope: .tabs, conflictGroup: nil, available: true, defaultBindings: ["Ctrl+PageUp"]),
        .init(action: .tabSelectByIndex, title: "Select Tab 1–9", group: "Tab Navigation", scope: .tabs, conflictGroup: nil, available: true, defaultBindings: ["Ctrl+1"]),
        .init(action: .tabOpenQuickCommandsMenu, title: "Toggle Quick Commands menu", group: "Quick Commands", scope: .tabs, conflictGroup: "global", available: true, defaultBindings: []),
        .init(action: .browserFind, title: "Find in Browser", group: "Browser", scope: .browser, conflictGroup: nil, available: false, defaultBindings: ["Mod+F"]),
        .init(action: .browserBack, title: "Go Back in Browser", group: "Browser", scope: .browser, conflictGroup: nil, available: false, defaultBindings: ["Mod+BracketLeft"]),
        .init(action: .browserForward, title: "Go Forward in Browser", group: "Browser", scope: .browser, conflictGroup: nil, available: false, defaultBindings: ["Mod+BracketRight"]),
        .init(action: .browserReload, title: "Reload Browser Page", group: "Browser", scope: .browser, conflictGroup: nil, available: false, defaultBindings: ["Mod+R"]),
        .init(action: .browserHardReload, title: "Hard Reload Browser Page", group: "Browser", scope: .browser, conflictGroup: nil, available: false, defaultBindings: ["Mod+Shift+R"]),
        .init(action: .browserFocusAddressBar, title: "Focus Browser Address Bar", group: "Browser", scope: .browser, conflictGroup: nil, available: false, defaultBindings: ["Mod+L"]),
        .init(action: .browserGrabElement, title: "Grab Page Element", group: "Browser", scope: .browser, conflictGroup: nil, available: false, defaultBindings: ["Mod+C"]),
        .init(action: .browserAnnotateElement, title: "Annotate Page Element", group: "Browser", scope: .browser, conflictGroup: nil, available: false, defaultBindings: ["Mod+Shift+C"]),
        .init(action: .editorFind, title: "Find in editor", group: "Editors", scope: .editor, conflictGroup: nil, available: false, defaultBindings: ["Mod+F"]),
        .init(action: .editorReplace, title: "Replace in editor", group: "Editors", scope: .editor, conflictGroup: nil, available: false, defaultBindings: ["Mod+Alt+F"]),
        .init(action: .editorSave, title: "Save File", group: "Editors", scope: .editor, conflictGroup: nil, available: false, defaultBindings: ["Mod+S"]),
        .init(action: .editorMarkdownPreview, title: "Show Markdown Preview", group: "Editors", scope: .editor, conflictGroup: nil, available: false, defaultBindings: ["Mod+Shift+V"]),
        .init(action: .editorToggleWordWrap, title: "Toggle Word Wrap", group: "Editors", scope: .editor, conflictGroup: nil, available: false, defaultBindings: ["Alt+Z"]),
        .init(action: .editorCopyContext, title: "Copy Context", group: "Editors", scope: .editor, conflictGroup: nil, available: false, defaultBindings: ["Mod+Alt+C"]),
        .init(action: .editorPreviousChange, title: "Go to Previous Change", group: "Editors", scope: .editor, conflictGroup: nil, available: false, defaultBindings: ["Shift+F7"]),
        .init(action: .editorNextChange, title: "Go to Next Change", group: "Editors", scope: .editor, conflictGroup: nil, available: false, defaultBindings: ["F7"]),
        .init(action: .editorAddReviewNote, title: "Add Review Note", group: "Editors", scope: .editor, conflictGroup: nil, available: false, defaultBindings: ["Mod+Shift+A"]),
        .init(action: .sourceControlSendReviewNotes, title: "Send Review Notes to Agent", group: "Global", scope: .window, conflictGroup: "editor", available: false, defaultBindings: []),
        .init(action: .fileExplorerUndo, title: "Undo file operation", group: "File Explorer", scope: .fileExplorer, conflictGroup: nil, available: true, defaultBindings: ["Mod+Z"]),
        .init(action: .fileExplorerRedo, title: "Redo file operation", group: "File Explorer", scope: .fileExplorer, conflictGroup: nil, available: true, defaultBindings: ["Mod+Shift+Z"]),
        .init(action: .fileExplorerCopyPath, title: "Copy file path", group: "File Explorer", scope: .fileExplorer, conflictGroup: nil, available: false, defaultBindings: ["Mod+Alt+C"]),
        .init(action: .fileExplorerCopyRelativePath, title: "Copy relative file path", group: "File Explorer", scope: .fileExplorer, conflictGroup: nil, available: false, defaultBindings: ["Mod+Alt+Shift+C"]),
        .init(action: .fileExplorerDelete, title: "Delete file", group: "File Explorer", scope: .fileExplorer, conflictGroup: nil, available: false, defaultBindings: ["Mod+Backspace", "Delete"]),
        .init(action: .settingsSearch, title: "Search Settings", group: "Settings", scope: .settings, conflictGroup: nil, available: false, defaultBindings: ["Mod+F"]),
        .init(action: .terminalCopySelection, title: "Copy terminal selection", group: "Terminal Panes", scope: .terminal, conflictGroup: nil, available: true, defaultBindings: ["Mod+C"]),
        .init(action: .terminalSelectAll, title: "Select all terminal text", group: "Terminal Panes", scope: .terminal, conflictGroup: nil, available: true, defaultBindings: ["Mod+A"]),
        .init(action: .terminalPaste, title: "Paste into terminal", group: "Terminal Panes", scope: .terminal, conflictGroup: nil, available: true, defaultBindings: ["Mod+V"]),
        .init(action: .terminalSearch, title: "Search active pane", group: "Terminal Panes", scope: .terminal, conflictGroup: nil, available: true, defaultBindings: ["Mod+F"]),
        .init(action: .terminalClear, title: "Clear active pane", group: "Terminal Panes", scope: .terminal, conflictGroup: nil, available: true, defaultBindings: ["Mod+K"]),
        .init(action: .terminalFocusNextPane, title: "Focus next pane", group: "Terminal Panes", scope: .terminal, conflictGroup: nil, available: true, defaultBindings: ["Mod+BracketRight"]),
        .init(action: .terminalFocusPreviousPane, title: "Focus previous pane", group: "Terminal Panes", scope: .terminal, conflictGroup: nil, available: true, defaultBindings: ["Mod+BracketLeft"]),
        .init(action: .terminalEqualizePaneSizes, title: "Equalize pane sizes", group: "Terminal Panes", scope: .terminal, conflictGroup: nil, available: true, defaultBindings: []),
        .init(action: .terminalExpandPane, title: "Expand / collapse pane", group: "Terminal Panes", scope: .terminal, conflictGroup: nil, available: true, defaultBindings: ["Mod+Shift+Enter"]),
        .init(action: .terminalSetTitle, title: "Set Title…", group: "Terminal Panes", scope: .terminal, conflictGroup: nil, available: true, defaultBindings: []),
        .init(action: .chatFind, title: "Find in chat", group: "Chat", scope: .chat, conflictGroup: nil, available: false, defaultBindings: ["Mod+F"]),
        .init(action: .sidebarChildWorkspacesToggle, title: "Toggle Child Workspaces", group: "Global", scope: .window, conflictGroup: nil, available: false, defaultBindings: []),
        .init(action: .terminalClearPaneTitle, title: "Clear Pane Title", group: "Terminal Panes", scope: .terminal, conflictGroup: nil, available: true, defaultBindings: []),
        .init(action: .terminalClosePane, title: "Close active pane", group: "Terminal Panes", scope: .terminal, conflictGroup: nil, available: true, defaultBindings: ["Mod+W"]),
        .init(action: .terminalSplitRight, title: "Split terminal right", group: "Terminal Panes", scope: .terminal, conflictGroup: nil, available: true, defaultBindings: ["Mod+D"]),
        .init(action: .terminalSplitDown, title: "Split terminal down", group: "Terminal Panes", scope: .terminal, conflictGroup: nil, available: true, defaultBindings: ["Mod+Shift+D"]),
        .init(action: .terminalSwitchInputSource, title: "Switch input source / language (native)", group: "Terminal Panes", scope: .terminal, conflictGroup: nil, available: false, defaultBindings: []),
    ]

    public static let defaults: KeybindingRegistry = {
        KeybindingRegistry(bindings: Dictionary(uniqueKeysWithValues: definitions.map { definition in
            let chords = definition.defaultBindings.compactMap { try? KeyChord.parse($0) }
            return (definition.action, expandedDigits(chords, for: definition.action))
        }))
    }()

    private static func expandedDigits(_ chords: [KeyChord], for action: KeybindingAction) -> [KeyChord] {
        guard action == .tabSelectByIndex || action == .workspaceSelectByIndex else { return chords }
        return chords.flatMap { chord in (1...9).map { digit in
            var result = chord; result.key = String(digit); return result
        }}
    }

    public static let nativeCutChord = KeyChord(key: "X", command: true)
    public static let nativeNewWindowChord = KeyChord(key: "N", command: true)

    public func digitIndex(for chord: KeyChord, action: KeybindingAction) -> Int? {
        guard action == .tabSelectByIndex || action == .workspaceSelectByIndex,
              chords(for: action).contains(chord), let digit = Int(chord.key), (1...9).contains(digit) else { return nil }
        return digit - 1
    }

    /// Never take ordinary Ctrl-letter, Option-as-Meta, or typed text from a TUI.
    public static func allowedInTerminal(_ chord: KeyChord) -> Bool {
        chord.command || (chord.control && !chord.option && (chord.key == "Tab" || chord.key == "PageUp" || chord.key == "PageDown" || Int(chord.key).map { (1...9).contains($0) } == true))
    }

    public static func loading(from url: URL) -> (KeybindingRegistry, [KeybindingDiagnostic]) {
        do { return loading(overridesJSON: try Data(contentsOf: url)) }
        catch where (error as NSError).code == NSFileReadNoSuchFileError { return (.defaults, []) }
        catch { return (.defaults, [.init(severity: .error, message: "Cannot read keybindings.json: \(error)")]) }
    }

    /// Pairs allowed to share a chord on purpose (Cmd-W closes the pane, and the last pane closes the tab).
    private static let deliberatePairs: Set<Set<KeybindingAction>> = [[.tabClose, .terminalClosePane]]

    public func chords(for action: KeybindingAction) -> [KeyChord] {
        bindings[action] ?? []
    }

    /// First action in declaration order bound to the chord, optionally limited to one scope.
    public func action(for chord: KeyChord, scope: KeybindingScope? = nil) -> KeybindingAction? {
        KeybindingAction.allCases.first { action in
            (scope == nil || action.scope == scope) && chords(for: action).contains(chord)
        }
    }

    /// Applies an Orca `KeybindingOverrides` JSON object (`{"tab.close":["Mod+W"]}`).
    /// An empty array unbinds the action. Invalid input never throws: it yields diagnostics.
    public static func loading(overridesJSON: Data) -> (KeybindingRegistry, [KeybindingDiagnostic]) {
        var diagnostics: [KeybindingDiagnostic] = []
        var table = defaults.bindings

        let decoded: [String: [String]]
        do {
            decoded = try JSONDecoder().decode([String: [String]].self, from: overridesJSON)
        } catch {
            diagnostics.append(.init(severity: .error, message: "Keybinding overrides are not a JSON object of string arrays; using defaults."))
            return (defaults, diagnostics)
        }

        for id in decoded.keys.sorted() {
            guard let action = KeybindingAction(rawValue: id) else {
                diagnostics.append(.init(severity: .warning, message: "Unknown keybinding action '\(id)' ignored.", actionID: id))
                continue
            }
            var parsed: [KeyChord] = []
            var failed = false
            for text in decoded[id] ?? [] {
                do {
                    parsed.append(try KeyChord.parse(text))
                } catch {
                    failed = true
                    diagnostics.append(.init(severity: .error, message: "Invalid chord '\(text)' for '\(id)'; keeping the previous binding.", actionID: id))
                }
            }
            if action == .tabSelectByIndex || action == .workspaceSelectByIndex {
                if parsed.contains(where: { Int($0.key).map { !(1...9).contains($0) } ?? true }) {
                    failed = true
                    diagnostics.append(.init(severity: .error, message: "Index bindings must use a digit 1–9.", actionID: id))
                }
            }
            if !failed { table[action] = expandedDigits(parsed, for: action).reduce(into: []) { if !$0.contains($1) { $0.append($1) } } }
        }

        let registry = KeybindingRegistry(bindings: table)
        diagnostics.append(contentsOf: registry.conflicts())
        return (registry, diagnostics)
    }

    /// All actions, including unavailable ones, participate in editing diagnostics.
    public func conflicts() -> [KeybindingDiagnostic] {
        var owners: [String: [KeyChord: [KeybindingAction]]] = [:]
        for action in KeybindingAction.allCases {
            let definition = action.definition
            let buckets = Set([definition.scope.rawValue, definition.conflictGroup].compactMap { $0 })
            for bucket in buckets {
                for chord in Set(chords(for: action)) { owners[bucket, default: [:]][chord, default: []].append(action) }
            }
        }
        var seen = Set<String>()
        var result: [KeybindingDiagnostic] = []
        for bucket in owners.keys.sorted() {
            for (chord, actions) in owners[bucket]!.sorted(by: { $0.key.formatted < $1.key.formatted }) where actions.count > 1 {
                if actions.count == 2, Self.deliberatePairs.contains(Set(actions)) { continue }
                let names = actions.map(\.rawValue).joined(separator: ", ")
                guard seen.insert(chord.formatted + names).inserted else { continue }
                result.append(.init(severity: .error, message: "Chord \(chord.formatted) is bound to several actions in \(bucket): \(names).", actionID: actions[0].rawValue))
            }
        }
        return result
    }

    /// Other actions sharing `chord` with `action` in one of its conflict buckets; deliberate pairs excluded.
    public func conflictingActions(for action: KeybindingAction, chord: KeyChord) -> [KeybindingAction] {
        let buckets = Self.conflictBuckets(action)
        return KeybindingAction.allCases.filter { other in
            other != action && !Self.conflictBuckets(other).isDisjoint(with: buckets)
                && !Self.deliberatePairs.contains([action, other]) && chords(for: other).contains(chord)
        }
    }

    private static func conflictBuckets(_ action: KeybindingAction) -> Set<String> {
        Set([action.definition.scope.rawValue, action.definition.conflictGroup].compactMap { $0 })
    }

    public static func isDigitIndex(_ action: KeybindingAction) -> Bool {
        action == .tabSelectByIndex || action == .workspaceSelectByIndex
    }

    /// Chords as stored and edited: digit-index actions keep one representative chord ending in 1.
    public func representativeChords(for action: KeybindingAction) -> [KeyChord] {
        let all = chords(for: action)
        return Self.isDigitIndex(action) ? all.filter { $0.key == "1" } : all
    }
}

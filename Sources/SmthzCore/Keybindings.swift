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

/// The M3 subset of Orca action ids. Raw values are the Orca ids.
public enum KeybindingAction: String, CaseIterable, Sendable, Codable {
    case tabNewTerminal = "tab.newTerminal"
    case tabClose = "tab.close"
    case tabCloseAll = "tab.closeAll"
    case tabRename = "tab.rename"
    case tabReopenClosed = "tab.reopenClosed"
    case tabNextAllTypes = "tab.nextAllTypes"
    case tabPreviousAllTypes = "tab.previousAllTypes"
    case tabNextSameType = "tab.nextSameType"
    case tabPreviousSameType = "tab.previousSameType"
    case tabPreviousRecent = "tab.previousRecent"
    case tabNextTerminal = "tab.nextTerminal"
    case tabPreviousTerminal = "tab.previousTerminal"
    case tabSelectByIndex = "tab.selectByIndex"
    case terminalClosePane = "terminal.closePane"
    case terminalSplitRight = "terminal.splitRight"
    case terminalSplitDown = "terminal.splitDown"
    case terminalFocusNextPane = "terminal.focusNextPane"
    case terminalFocusPreviousPane = "terminal.focusPreviousPane"
    case terminalExpandPane = "terminal.expandPane"
    case terminalEqualizePaneSizes = "terminal.equalizePaneSizes"
    case terminalSetTitle = "terminal.setTitle"
    case terminalClearPaneTitle = "terminal.clearPaneTitle"
    case terminalCopySelection = "terminal.copySelection"
    case terminalPaste = "terminal.paste"
    case terminalSelectAll = "terminal.selectAll"
    case terminalSearch = "terminal.search"
    case terminalClear = "terminal.clear"
    case workspaceSelectByIndex = "workspace.selectByIndex"
    case worktreeNavigateUp = "worktree.navigateUp"
    case worktreeNavigateDown = "worktree.navigateDown"
    case worktreePalette = "worktree.palette"
    case worktreeHistoryBack = "worktree.history.back"
    case worktreeHistoryForward = "worktree.history.forward"
    case sidebarLeftToggle = "sidebar.left.toggle"
    case floatingTerminalToggle = "floatingTerminal.toggle"
    case zoomIn = "zoom.in"
    case zoomOut = "zoom.out"
    case zoomReset = "zoom.reset"

    /// Conflicts are only reported between actions of the same scope.
    public var scope: KeybindingScope {
        rawValue.hasPrefix("terminal.") ? .terminal : .window
    }
}

public enum KeybindingScope: String, Sendable {
    case window
    case terminal
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

    /// Orca 1.4.238 darwin defaults, M3 subset. The index actions expand
    /// Orca's representative chord (`Ctrl+1`, `Mod+1`) to digits 1 through 9.
    public static let defaults: KeybindingRegistry = {
        func chords(_ strings: [String]) -> [KeyChord] {
            strings.compactMap { try? KeyChord.parse($0) }
        }
        let digits = (1...9).map(String.init)
        let table: [KeybindingAction: [String]] = [
            .tabNewTerminal: ["Mod+T"],
            .tabClose: ["Mod+W"],
            .tabCloseAll: ["Mod+Alt+W"],
            .tabRename: ["Mod+R"],
            .tabReopenClosed: ["Mod+Shift+T"],
            .tabNextAllTypes: ["Mod+Shift+BracketRight"],
            .tabPreviousAllTypes: ["Mod+Shift+BracketLeft"],
            .tabNextSameType: ["Mod+Alt+BracketRight"],
            .tabPreviousSameType: ["Mod+Alt+BracketLeft"],
            .tabPreviousRecent: ["Ctrl+Tab"],
            .tabNextTerminal: ["Ctrl+PageDown"],
            .tabPreviousTerminal: ["Ctrl+PageUp"],
            .tabSelectByIndex: digits.map { "Ctrl+\($0)" },
            .terminalClosePane: ["Mod+W"],
            .terminalSplitRight: ["Mod+D"],
            .terminalSplitDown: ["Mod+Shift+D"],
            .terminalFocusNextPane: ["Mod+BracketRight"],
            .terminalFocusPreviousPane: ["Mod+BracketLeft"],
            .terminalExpandPane: ["Mod+Shift+Enter"],
            .terminalEqualizePaneSizes: [],
            .terminalSetTitle: [],
            .terminalClearPaneTitle: [],
            .terminalCopySelection: ["Mod+C"],
            .terminalPaste: ["Mod+V"],
            .terminalSelectAll: ["Mod+A"],
            .terminalSearch: ["Mod+F"],
            .terminalClear: ["Mod+K"],
            .workspaceSelectByIndex: digits.map { "Mod+\($0)" },
            .worktreeNavigateUp: ["Mod+Shift+ArrowUp"],
            .worktreeNavigateDown: ["Mod+Shift+ArrowDown"],
            .worktreePalette: ["Mod+J"],
            .worktreeHistoryBack: ["Mod+Alt+ArrowLeft"],
            .worktreeHistoryForward: ["Mod+Alt+ArrowRight"],
            .sidebarLeftToggle: ["Mod+B"],
            .floatingTerminalToggle: ["Mod+Alt+A"],
            .zoomIn: ["Mod+Equal", "Mod+Shift+Plus", "Mod+NumpadAdd"],
            .zoomOut: ["Mod+Minus", "Mod+NumpadSubtract"],
            .zoomReset: ["Mod+0"],
        ]
        return KeybindingRegistry(bindings: table.mapValues(chords))
    }()

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
            if !failed { table[action] = parsed }
        }

        let registry = KeybindingRegistry(bindings: table)
        diagnostics.append(contentsOf: registry.conflicts())
        return (registry, diagnostics)
    }

    /// Error diagnostics for two actions on one chord within the same scope.
    public func conflicts() -> [KeybindingDiagnostic] {
        var result: [KeybindingDiagnostic] = []
        for scope in [KeybindingScope.window, .terminal] {
            var owners: [KeyChord: [KeybindingAction]] = [:]
            for action in KeybindingAction.allCases where action.scope == scope {
                for chord in Set(chords(for: action)) { owners[chord, default: []].append(action) }
            }
            for (chord, actions) in owners.sorted(by: { $0.key.formatted < $1.key.formatted }) where actions.count > 1 {
                if actions.count == 2, Self.deliberatePairs.contains(Set(actions)) { continue }
                let names = actions.map(\.rawValue).joined(separator: ", ")
                result.append(.init(severity: .error, message: "Chord \(chord.formatted) is bound to several actions in the \(scope.rawValue) scope: \(names).", actionID: actions[0].rawValue))
            }
        }
        return result
    }
}

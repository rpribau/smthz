import Foundation
import Testing
@testable import SmthzCore

@Suite struct KeybindingsTests {
    /// Hard-coded copy of the M3 subset of Orca 1.4.238 darwin defaults (docs/M3-PLAN.md 1.3).
    /// The index actions are Orca's representative chord expanded to digits 1-9.
    static let expected: [String: [String]] = [
        "tab.newTerminal": ["Mod+T"],
        "tab.close": ["Mod+W"],
        "tab.closeAll": ["Mod+Alt+W"],
        "tab.rename": ["Mod+R"],
        "tab.reopenClosed": ["Mod+Shift+T"],
        "tab.nextAllTypes": ["Mod+Shift+BracketRight"],
        "tab.previousAllTypes": ["Mod+Shift+BracketLeft"],
        "tab.nextSameType": ["Mod+Alt+BracketRight"],
        "tab.previousSameType": ["Mod+Alt+BracketLeft"],
        "tab.previousRecent": ["Ctrl+Tab"],
        "tab.nextTerminal": ["Ctrl+PageDown"],
        "tab.previousTerminal": ["Ctrl+PageUp"],
        "tab.selectByIndex": (1...9).map { "Ctrl+\($0)" },
        "terminal.closePane": ["Mod+W"],
        "terminal.splitRight": ["Mod+D"],
        "terminal.splitDown": ["Mod+Shift+D"],
        "terminal.focusNextPane": ["Mod+BracketRight"],
        "terminal.focusPreviousPane": ["Mod+BracketLeft"],
        "terminal.expandPane": ["Mod+Shift+Enter"],
        "terminal.equalizePaneSizes": [],
        "terminal.setTitle": [],
        "terminal.clearPaneTitle": [],
        "terminal.copySelection": ["Mod+C"],
        "terminal.paste": ["Mod+V"],
        "terminal.selectAll": ["Mod+A"],
        "terminal.search": ["Mod+F"],
        "terminal.clear": ["Mod+K"],
        "workspace.selectByIndex": (1...9).map { "Mod+\($0)" },
        "worktree.navigateUp": ["Mod+Shift+ArrowUp"],
        "worktree.navigateDown": ["Mod+Shift+ArrowDown"],
        "worktree.palette": ["Mod+J"],
        "worktree.history.back": ["Mod+Alt+ArrowLeft"],
        "worktree.history.forward": ["Mod+Alt+ArrowRight"],
        "sidebar.left.toggle": ["Mod+B"],
        "floatingTerminal.toggle": ["Mod+Alt+A"],
        "zoom.in": ["Mod+Equal", "Mod+Shift+Plus", "Mod+NumpadAdd"],
        "zoom.out": ["Mod+Minus", "Mod+NumpadSubtract"],
        "zoom.reset": ["Mod+0"],
    ]

    static func json(_ object: [String: [String]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    @Test func defaultsEqualOrcaDarwinTable() {
        let registry = KeybindingRegistry.defaults
        #expect(KeybindingAction.allCases.count == Self.expected.count)
        for action in KeybindingAction.allCases {
            let actual = registry.chords(for: action).map(\.formatted)
            #expect(actual == Self.expected[action.rawValue], "\(action.rawValue)")
        }
    }

    @Test func parseFormatRoundTripForEveryDefault() throws {
        for action in KeybindingAction.allCases {
            for chord in KeybindingRegistry.defaults.chords(for: action) {
                let reparsed = try KeyChord.parse(chord.formatted)
                #expect(reparsed == chord)
                #expect(reparsed.formatted == chord.formatted)
            }
        }
    }

    @Test func parsesModifiersAndKeys() throws {
        let chord = try KeyChord.parse("Mod+Shift+BracketRight")
        #expect(chord == KeyChord(key: "BracketRight", command: true, shift: true))
        let ctrl = try KeyChord.parse("ctrl+pagedown")
        #expect(ctrl == KeyChord(key: "PageDown", control: true))
        let alt = try KeyChord.parse("Mod+Alt+ArrowLeft")
        #expect(alt == KeyChord(key: "ArrowLeft", command: true, option: true))
        #expect(try KeyChord.parse("Mod+t").key == "T")
        #expect(try KeyChord.parse("Mod++").key == "Plus")
    }

    @Test func rejectsInvalidChords() {
        #expect(throws: KeyChordParseError.self) { try KeyChord.parse("") }
        #expect(throws: KeyChordParseError.self) { try KeyChord.parse("Mod+") }
        #expect(throws: KeyChordParseError.self) { try KeyChord.parse("Hyper+T") }
        #expect(throws: KeyChordParseError.self) { try KeyChord.parse("Mod+Bogus") }
    }

    @Test func overrideReplacesBinding() throws {
        let (registry, diagnostics) = KeybindingRegistry.loading(overridesJSON: try Self.json(["tab.newTerminal": ["Mod+Alt+N"]]))
        #expect(diagnostics.isEmpty)
        #expect(registry.chords(for: .tabNewTerminal).map(\.formatted) == ["Mod+Alt+N"])
        let old = try KeyChord.parse("Mod+T")
        #expect(registry.action(for: old) == nil)
        #expect(registry.action(for: try KeyChord.parse("Mod+Alt+N")) == .tabNewTerminal)
        // Untouched actions keep their defaults.
        #expect(registry.chords(for: .zoomReset).map(\.formatted) == ["Mod+0"])
    }

    @Test func emptyListUnbinds() throws {
        let (registry, diagnostics) = KeybindingRegistry.loading(overridesJSON: try Self.json(["tab.rename": []]))
        #expect(diagnostics.isEmpty)
        #expect(registry.chords(for: .tabRename).isEmpty)
        #expect(registry.action(for: try KeyChord.parse("Mod+R")) == nil)
    }

    @Test func unknownActionIsWarning() throws {
        let (registry, diagnostics) = KeybindingRegistry.loading(overridesJSON: try Self.json(["tab.doesNotExist": ["Mod+Q"]]))
        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.severity == .warning)
        #expect(diagnostics.first?.actionID == "tab.doesNotExist")
        #expect(registry.chords(for: .tabClose).map(\.formatted) == ["Mod+W"])
    }

    @Test func conflictInSameScopeIsError() throws {
        let (registry, diagnostics) = KeybindingRegistry.loading(overridesJSON: try Self.json(["tab.rename": ["Mod+T"]]))
        let errors = diagnostics.filter { $0.severity == .error }
        #expect(errors.count == 1)
        #expect(errors.first?.message.contains("Mod+T") == true)
        #expect(errors.first?.message.contains("tab.rename") == true)
        // Deterministic: the first declared action wins the lookup.
        #expect(registry.action(for: try KeyChord.parse("Mod+T")) == .tabNewTerminal)
    }

    @Test func closeTabAndClosePaneShareCmdWWithoutConflict() throws {
        let (registry, diagnostics) = KeybindingRegistry.loading(overridesJSON: Data("{}".utf8))
        #expect(diagnostics.isEmpty)
        #expect(KeybindingRegistry.defaults.conflicts().isEmpty)
        let chord = try KeyChord.parse("Mod+W")
        #expect(registry.action(for: chord) == .tabClose)
        #expect(registry.action(for: chord, scope: .terminal) == .terminalClosePane)
    }

    @Test func invalidChordAndInvalidJSONProduceErrors() throws {
        let (registry, diagnostics) = KeybindingRegistry.loading(overridesJSON: try Self.json(["tab.close": ["Mod+Bogus"]]))
        #expect(diagnostics.contains { $0.severity == .error && $0.actionID == "tab.close" })
        #expect(registry.chords(for: .tabClose).map(\.formatted) == ["Mod+W"])

        let (fallback, bad) = KeybindingRegistry.loading(overridesJSON: Data("not json".utf8))
        #expect(bad.contains { $0.severity == .error })
        #expect(fallback.chords(for: .tabNewTerminal).map(\.formatted) == ["Mod+T"])
    }
}

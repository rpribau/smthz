import Foundation
import Testing
@testable import SmthzCore

@Suite struct KeybindingOverrideTests {
    private func makeFile() throws -> (KeybindingOverrideFile, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("smthz-kbo-\(UUID().uuidString)")
        return (KeybindingOverrideFile(url: dir.appendingPathComponent("state/keybindings.json")), dir)
    }

    private func chord(_ text: String) throws -> KeyChord { try KeyChord.parse(text) }

    @Test func missingFileHasNoEntriesAndDefaults() throws {
        let (file, dir) = try makeFile(); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try file.entries().isEmpty)
        #expect(!file.isModified(.tabNewTerminal))
        let (registry, diagnostics) = file.load()
        #expect(diagnostics.isEmpty)
        #expect(registry.chords(for: .tabNewTerminal) == [try chord("Mod+T")])
    }

    @Test func setBindingsWritesOverrideCreatesDirectoryAndReloads() throws {
        let (file, dir) = try makeFile(); defer { try? FileManager.default.removeItem(at: dir) }
        let diagnostics = try file.setBindings([try chord("Mod+Shift+Y")], for: .tabNewTerminal)
        #expect(diagnostics.isEmpty)
        #expect(try file.entries() == ["tab.newTerminal": ["Mod+Shift+Y"]])
        #expect(file.isModified(.tabNewTerminal))
        #expect(file.load().0.chords(for: .tabNewTerminal) == [try chord("Mod+Shift+Y")])
        let text = try String(contentsOf: file.url, encoding: .utf8)
        #expect(text.hasSuffix("\n"))
    }

    @Test func settingDefaultsRemovesTheEntry() throws {
        let (file, dir) = try makeFile(); defer { try? FileManager.default.removeItem(at: dir) }
        try file.setBindings([try chord("Mod+Shift+Y")], for: .tabNewTerminal)
        try file.setBindings([try chord("Mod+T")], for: .tabNewTerminal)
        #expect(try file.entries().isEmpty)
    }

    @Test func emptyListDisablesAndResetRestores() throws {
        let (file, dir) = try makeFile(); defer { try? FileManager.default.removeItem(at: dir) }
        try file.setBindings([], for: .terminalClear)
        #expect(try file.entries() == ["terminal.clear": []])
        #expect(file.load().0.chords(for: .terminalClear).isEmpty)
        try file.reset(.terminalClear)
        #expect(try file.entries().isEmpty)
        #expect(file.load().0.chords(for: .terminalClear) == [try chord("Mod+K")])
        // An action without defaults stays unmodified when cleared.
        try file.setBindings([], for: .terminalSetTitle)
        #expect(try file.entries().isEmpty)
    }

    @Test func conflictIsRefusedAndFileUnchanged() throws {
        let (file, dir) = try makeFile(); defer { try? FileManager.default.removeItem(at: dir) }
        try file.setBindings([try chord("Mod+Shift+Y")], for: .tabRename)
        #expect(throws: KeybindingEditError.conflict(chord: try chord("Mod+T"), actions: [.tabNewTerminal])) {
            try file.setBindings([try chord("Mod+T")], for: .tabReopenClosed)
        }
        #expect(try file.entries() == ["tab.rename": ["Mod+Shift+Y"]])
        let message = KeybindingEditError.conflict(chord: try chord("Mod+T"), actions: [.tabNewTerminal]).description
        #expect(message == "Mod+T conflicts with New terminal tab.")
    }

    @Test func deliberatePairAndOtherScopesAreNotConflicts() throws {
        let (file, dir) = try makeFile(); defer { try? FileManager.default.removeItem(at: dir) }
        // tab.close and terminal.closePane share Mod+W on purpose; scopes are separate buckets.
        #expect(KeybindingRegistry.defaults.conflictingActions(for: .tabClose, chord: try chord("Mod+W")).isEmpty)
        try file.setBindings([try chord("Mod+Shift+W")], for: .terminalClosePane)
        try file.setBindings([try chord("Mod+Shift+W")], for: .tabClose)
        // Editor and terminal scopes do not collide (Mod+F in both by default).
        try file.setBindings([try chord("Mod+F"), try chord("Mod+Alt+K")], for: .terminalSearch)
        #expect(try file.entries()["terminal.search"] == ["Mod+F", "Mod+Alt+K"])
    }

    @Test func conflictGroupsBridgeScopes() throws {
        // Quick Commands (tabs scope) shares the "global" group with window actions.
        let registry = KeybindingRegistry.defaults
        #expect(registry.conflictingActions(for: .tabOpenQuickCommandsMenu, chord: try chord("Mod+B")) == [.sidebarLeftToggle])
        let (file, dir) = try makeFile(); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: KeybindingEditError.self) {
            try file.setBindings([try chord("Mod+B")], for: .tabOpenQuickCommandsMenu)
        }
    }

    @Test func digitIndexActionsStoreOneRepresentativeChord() throws {
        let (file, dir) = try makeFile(); defer { try? FileManager.default.removeItem(at: dir) }
        try file.setBindings([try chord("Mod+Alt+4")], for: .tabSelectByIndex)
        #expect(try file.entries() == ["tab.selectByIndex": ["Mod+Alt+1"]])
        let registry = file.load().0
        #expect(registry.chords(for: .tabSelectByIndex).count == 9)
        #expect(registry.representativeChords(for: .tabSelectByIndex) == [try chord("Mod+Alt+1")])
        #expect(KeybindingOverrideFile.validate(try chord("Ctrl+K"), for: .tabSelectByIndex) == .failure(.digitRequired))
        #expect(KeybindingOverrideFile.validate(try chord("4"), for: .tabSelectByIndex) == .failure(.digitRequired))
    }

    @Test func captureValidationRules() throws {
        #expect(KeybindingOverrideFile.validate(try chord("K"), for: .terminalClear) == .failure(.modifierRequired))
        #expect(KeybindingOverrideFile.validate(try chord("Shift+K"), for: .terminalClear) == .failure(.modifierRequired))
        #expect(KeybindingOverrideFile.validate(try chord("F8"), for: .editorNextChange) == .success(try chord("F8")))
        #expect(KeybindingOverrideFile.validate(try chord("Mod+N"), for: .tabNewTerminal) == .failure(.reserved(KeybindingRegistry.nativeNewWindowChord)))
        #expect(KeybindingOverrideFile.validate(try chord("Mod+X"), for: .tabNewTerminal) == .failure(.reserved(KeybindingRegistry.nativeCutChord)))
        #expect(KeybindingOverrideFile.validate(try chord("Ctrl+Alt+K"), for: .terminalClear) == .success(try chord("Ctrl+Alt+K")))
    }

    @Test func unknownIdsArePreservedAndResetAllClears() throws {
        let (file, dir) = try makeFile(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"future.action":["Mod+Q"],"tab.close":["Mod+Shift+Q"]}"#.utf8).write(to: file.url)
        let diagnostics = try file.setBindings([try chord("Mod+Shift+Y")], for: .tabNewTerminal)
        #expect(diagnostics.contains { $0.actionID == "future.action" && $0.severity == .warning })
        #expect(try file.entries() == ["future.action": ["Mod+Q"], "tab.close": ["Mod+Shift+Q"], "tab.newTerminal": ["Mod+Shift+Y"]])
        try file.resetAll()
        #expect(try file.entries().isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.url.path))
    }

    @Test func malformedFileIsNeverOverwritten() throws {
        let (file, dir) = try makeFile(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("{ not json".utf8)
        try original.write(to: file.url)
        #expect(throws: KeybindingEditError.malformedFile) {
            try file.setBindings([try chord("Mod+Shift+Y")], for: .tabNewTerminal)
        }
        #expect(throws: KeybindingEditError.malformedFile) { try file.reset(.tabNewTerminal) }
        #expect(try Data(contentsOf: file.url) == original)
        #expect(file.load().1.first?.severity == .error)
    }

    @Test func atomicWriteLeavesNoTemporaryFiles() throws {
        let (file, dir) = try makeFile(); defer { try? FileManager.default.removeItem(at: dir) }
        for key in ["Y", "U", "I"] { try file.setBindings([try chord("Mod+Shift+\(key)")], for: .tabNewTerminal) }
        let names = try FileManager.default.contentsOfDirectory(atPath: file.url.deletingLastPathComponent().path)
        #expect(names == ["keybindings.json"])
    }
}

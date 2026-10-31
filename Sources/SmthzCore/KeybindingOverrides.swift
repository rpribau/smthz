import Foundation

/// Why an edit to the keybinding override file was refused. Messages follow Orca 1.4.238.
public enum KeybindingEditError: Error, Equatable, Sendable, CustomStringConvertible {
    case modifierRequired
    case digitRequired
    case reserved(KeyChord)
    case conflict(chord: KeyChord, actions: [KeybindingAction])
    case malformedFile
    case writeFailed(String)

    public var description: String {
        switch self {
        case .modifierRequired: "Include at least one modifier key."
        case .digitRequired: "Pick a number key 1–9 with a modifier, like Cmd+1 or Ctrl+1."
        case .reserved(let chord): "\(chord.formatted) is reserved by macOS editing and window commands."
        case .conflict(let chord, let actions):
            "\(chord.formatted) conflicts with \(actions.map(\.definition.title).joined(separator: ", "))."
        case .malformedFile: "keybindings.json is not a JSON object of string arrays; fix or reset it before editing here."
        case .writeFailed(let reason): "Failed to save shortcut: \(reason)"
        }
    }
}

/// Edits the user override file (`<state-dir>/keybindings.json`, Orca `KeybindingOverrides`).
/// Entries equal to the defaults are removed, an empty array disables an action, and unknown
/// ids are preserved. Every write is atomic and returns the reloaded file's diagnostics.
public struct KeybindingOverrideFile: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    /// Raw entries; a missing file is empty. A malformed file is never overwritten.
    public func entries() throws -> [String: [String]] {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch where (error as NSError).code == NSFileReadNoSuchFileError { return [:] }
        catch { throw KeybindingEditError.writeFailed("\(error.localizedDescription)") }
        guard let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            throw KeybindingEditError.malformedFile
        }
        return decoded
    }

    public func load() -> (KeybindingRegistry, [KeybindingDiagnostic]) { KeybindingRegistry.loading(from: url) }

    public func isModified(_ action: KeybindingAction) -> Bool {
        (try? entries())?[action.rawValue] != nil
    }

    /// Replaces an action's bindings, refusing chords that collide with another action.
    @discardableResult
    public func setBindings(_ chords: [KeyChord], for action: KeybindingAction) throws -> [KeybindingDiagnostic] {
        var canonical: [KeyChord] = []
        for chord in chords {
            let value = try Self.validate(chord, for: action).get()
            if !canonical.contains(value) { canonical.append(value) }
        }
        var next = try entries()
        let defaults = KeybindingRegistry.defaults.representativeChords(for: action)
        if canonical == defaults { next.removeValue(forKey: action.rawValue) }
        else { next[action.rawValue] = canonical.map(\.formatted) }

        let (registry, _) = KeybindingRegistry.loading(overridesJSON: try Self.encode(next))
        for chord in registry.chords(for: action) {
            let others = registry.conflictingActions(for: action, chord: chord)
            if !others.isEmpty { throw KeybindingEditError.conflict(chord: chord, actions: others) }
        }
        return try write(next)
    }

    /// Restores the default bindings of one action.
    @discardableResult
    public func reset(_ action: KeybindingAction) throws -> [KeybindingDiagnostic] {
        var next = try entries()
        next.removeValue(forKey: action.rawValue)
        return try write(next)
    }

    /// Restores every default. Unknown ids are dropped too: the file becomes `{}`.
    @discardableResult
    public func resetAll() throws -> [KeybindingDiagnostic] {
        try write([:])
    }

    /// Checks one captured chord for an action and canonicalizes digit-index chords to key 1.
    public static func validate(_ chord: KeyChord, for action: KeybindingAction) -> Result<KeyChord, KeybindingEditError> {
        var chord = chord
        if KeybindingRegistry.isDigitIndex(action) {
            guard let digit = Int(chord.key), (1...9).contains(digit),
                  chord.command || chord.control || chord.option else { return .failure(.digitRequired) }
            chord.key = "1"
        }
        if !chord.command && !chord.control && !chord.option {
            // Bare and Shift-only chords are allowed only where Orca's defaults use them (F7, Delete).
            let bareDefault = KeybindingRegistry.defaults.chords(for: action).contains { !$0.command && !$0.control && !$0.option }
            if !bareDefault && !(chord.shift && chord.key == "Insert") { return .failure(.modifierRequired) }
        }
        if chord == KeybindingRegistry.nativeCutChord || chord == KeybindingRegistry.nativeNewWindowChord {
            return .failure(.reserved(chord))
        }
        return .success(chord)
    }

    private static func encode(_ entries: [String: [String]]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys])
        data.append(0x0A)
        return data
    }

    private func write(_ entries: [String: [String]]) throws -> [KeybindingDiagnostic] {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encode(entries).write(to: url, options: .atomic)
        } catch {
            throw KeybindingEditError.writeFailed(error.localizedDescription)
        }
        return load().1
    }
}

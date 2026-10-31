import Carbon
import Foundation

/// Option-as-Alt (Settings → Terminal, key `terminal.optionAsAlt`), after Orca's
/// `detect-option-as-alt.ts`: "auto" sends Alt/Esc only on the standard ABC/US input sources,
/// because every other layout (and every IME) needs Option to compose characters and dead keys.
/// SwiftTerm has one switch for both Option keys, so "left"/"right" act as "both".
enum TerminalOptionKey {
    static let settingKey = "terminal.optionAsAlt"
    static let altInputSources: Set<String> = ["com.apple.keylayout.ABC", "com.apple.keylayout.US"]

    static func sendsAlt(setting: String?, inputSourceID: String?) -> Bool {
        switch setting ?? "auto" {
        case "off": false
        case "auto": inputSourceID.map(altInputSources.contains) ?? false
        default: true
        }
    }

    /// The selected input source (an IME when one is active, not its backing layout).
    static func currentInputSourceID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    static func sendsAlt(_ defaults: UserDefaults = .standard) -> Bool {
        sendsAlt(setting: defaults.string(forKey: settingKey), inputSourceID: currentInputSourceID())
    }
}

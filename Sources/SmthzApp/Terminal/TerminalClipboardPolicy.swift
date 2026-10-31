import Foundation

/// OSC 52 ("Manipulate Selection Data") policy, after Orca's `osc52-clipboard.ts`: TUIs (tmux,
/// Neovim, fzf) may write the system clipboard by default, writes are dropped while the session log
/// is replayed into a fresh emulator (no fresh intent), oversized payloads are dropped, and reads
/// (`ESC ] 52 ; c ; ?`) are always denied so nothing on the PTY can exfiltrate the clipboard.
/// The Settings → Terminal toggle stores `allowWritesKey`.
enum TerminalClipboardPolicy {
    static let allowWritesKey = "terminal.allowOsc52Clipboard"
    /// Orca caps the base64 payload at 128 KiB; this is the decoded equivalent.
    static let maximumWriteBytes = 96 * 1024

    static func writesEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: allowWritesKey) as? Bool ?? true
    }

    static func allowsWrite(settingEnabled: Bool, replaying: Bool, byteCount: Int) -> Bool {
        settingEnabled && !replaying && byteCount <= maximumWriteBytes
    }
}

import SmthzCore
import SwiftUI

/// A §1.6 keyboard keycap. Use `KeyCapView("⌘")` or `KeyCapView.combo(["⌘", "N"])`.
/// Pass display symbols from the active keybinding configuration rather than hardcoding actions.
struct KeyCapView: View {
    let key: String

    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(SmthzFont.ui(size: 12, weight: .medium))
            .foregroundStyle(SmthzTheme.mutedForeground)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .frame(minWidth: 24, minHeight: 20)
            .background(SmthzTheme.secondary.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(SmthzTheme.border.opacity(0.8), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
    }

    /// Display the same chord the command registry uses, including user overrides.
    static func symbols(for chord: KeyChord) -> [String] {
        var symbols: [String] = []
        if chord.control { symbols.append("⌃") }
        if chord.option { symbols.append("⌥") }
        if chord.shift { symbols.append("⇧") }
        if chord.command { symbols.append("⌘") }
        let names = ["ArrowUp": "↑", "ArrowDown": "↓", "ArrowLeft": "←", "ArrowRight": "→",
                     "Enter": "↩", "Escape": "Esc", "Tab": "⇥", "Space": "Space",
                     "BracketLeft": "[", "BracketRight": "]", "Minus": "−", "Equal": "=",
                     "Plus": "+", "Backspace": "⌫", "PageUp": "⇞", "PageDown": "⇟"]
        symbols.append(names[chord.key] ?? chord.key)
        return symbols
    }

    static func combo(_ keys: [String]) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in KeyCapView(key) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(keys.joined(separator: " + "))
    }
}

#Preview("Shortcut keycaps") {
    VStack(spacing: 12) {
        KeyCapView.combo(["⌘", "⇧", "N"])
        KeyCapView.combo(["⌘", "↑"])
    }.padding(24).background(SmthzTheme.background)
}

import AppKit
import SwiftTerm

/// Terminal palettes and metrics from UI-SPEC §6. Self-contained on purpose: no dependency on the
/// shared smthz theme, so the terminal can be restyled or reused without it.
struct TerminalTheme: Sendable {
    let background: NSColor
    let foreground: NSColor
    let cursor: NSColor
    let selection: NSColor
    /// ANSI colours 0–15 as 8-bit RGB triples.
    let ansi: [(UInt8, UInt8, UInt8)]

    static let fontSize: CGFloat = 14
    static let padding: CGFloat = 4
    static let inactiveOpacity: CGFloat = 0.9
    static let regularWeight = NSFont.Weight(rawValue: 0.23) // CSS 500
    static let boldWeight = NSFont.Weight.bold              // CSS 700

    /// "Ghostty Default Style Dark".
    static let ghosttyDark = TerminalTheme(
        background: .hex(0x282c34), foreground: .hex(0xffffff), cursor: .hex(0xffffff),
        selection: .hex(0x5a7898),
        ansi: [0x1d1f21, 0xcc6666, 0xb5bd68, 0xf0c674, 0x81a2be, 0xb294bb, 0x8abeb7, 0xc5c8c6,
               0x666666, 0xd54e53, 0xb9ca4a, 0xe7c547, 0x7aa6da, 0xc397d8, 0x70c0b1, 0xeaeaea].map(rgb))

    /// "Builtin Tango Light".
    static let tangoLight = TerminalTheme(
        background: .hex(0xffffff), foreground: .hex(0x2e3434), cursor: .hex(0x2e3434),
        selection: .hex(0xaccef7),
        ansi: [0x2e3436, 0xcc0000, 0x4e9a06, 0x8e7700, 0x3465a4, 0x75507b, 0x05727e, 0x6a6a6a,
               0x555753, 0xef2929, 0x1b7a1b, 0x6d5a00, 0x204a87, 0xad7fa8, 0x034b50, 0x3d3d3d].map(rgb))

    static func resolve(for appearance: NSAppearance) -> TerminalTheme {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ghosttyDark : tangoLight
    }

    /// SF Mono at the requested size; the bold variant is derived by SwiftTerm from this base.
    static func font(size: CGFloat) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: regularWeight)
    }

    @MainActor
    func apply(to view: TerminalView) {
        view.nativeBackgroundColor = background
        view.nativeForegroundColor = foreground
        view.caretColor = cursor
        view.selectedTextBackgroundColor = selection
        view.installColors(ansi.map {
            Color(red8: UInt16($0.0), green8: UInt16($0.1), blue8: UInt16($0.2))
        })
        view.setCursorStyle(.blinkBlock)
        view.layer?.backgroundColor = background.cgColor
    }

    private static func rgb(_ value: UInt32) -> (UInt8, UInt8, UInt8) {
        (UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff))
    }
}

private extension NSColor {
    static func hex(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255,
                blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }
}

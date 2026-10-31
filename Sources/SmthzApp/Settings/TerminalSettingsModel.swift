import AppKit
import SwiftUI
import SwiftTerm

/// Persisted settings contract for UI-29 and terminal surfaces. Read a fresh snapshot on defaults
/// changes, then call apply(to:isActive:) from makeNSView/updateNSView after the base theme.
/// Padding, line height, copy-on-select and split metrics need terminal/split integration; their
/// controls remain disabled rather than saving preferences that have no effect.
@MainActor
struct TerminalSettingsModel {
    enum Key {
        static let appTheme = "appearance.theme"
        static let fontSize = "terminal.fontSize"
        static let fontFamily = "terminal.fontFamily"
        static let fontWeight = "terminal.fontWeight"
        static let cursorShape = "terminal.cursorShape"
        static let cursorBlink = "terminal.cursorBlink"
        static let themeMode = "terminal.themeMode"
        static let darkTheme = "terminal.darkTheme"
        static let lightTheme = "terminal.lightTheme"
        static let inactiveOpacity = "terminal.inactiveOpacity"
        static let scrollbackRows = "terminal.scrollbackRows"
        static let optionAsAlt = "terminal.optionAsAlt"
        /// Absent = Automatic (Orca: 4.5 on light backgrounds, 3 on dark); 1 = Off.
        static let minimumContrast = "terminal.minimumContrastRatio"
        static let scrollSensitivity = "terminal.scrollSensitivity"
        static let cursorOpacity = "terminal.cursorOpacity"
        static let gpuAcceleration = "terminal.gpuAcceleration"
    }

    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var fontSize: Double { number(Key.fontSize, fallback: 14, range: 8...40) }
    var fontFamily: String { defaults.string(forKey: Key.fontFamily) ?? "SF Mono" }
    var fontWeight: Double { number(Key.fontWeight, fallback: 500, range: 100...900) }
    var cursorShape: String { defaults.string(forKey: Key.cursorShape) ?? "block" }
    var cursorBlink: Bool { defaults.object(forKey: Key.cursorBlink) as? Bool ?? true }
    var themeMode: String { defaults.string(forKey: Key.themeMode) ?? "system" }
    var inactiveOpacity: Double { number(Key.inactiveOpacity, fallback: 0.9, range: 0.2...1) }
    var scrollbackRows: Int { Int(number(Key.scrollbackRows, fallback: 10_000, range: 100...100_000)) }
    var optionAsAlt: String { defaults.string(forKey: Key.optionAsAlt) ?? "auto" }
    var customMinimumContrast: Double? {
        defaults.object(forKey: Key.minimumContrast) == nil ? nil : number(Key.minimumContrast, fallback: 1, range: 1...21)
    }
    var scrollSensitivity: Double { number(Key.scrollSensitivity, fallback: 1, range: 0.5...3) }
    var cursorOpacity: Double { number(Key.cursorOpacity, fallback: 1, range: 0.1...1) }
    var gpuAcceleration: String { defaults.string(forKey: Key.gpuAcceleration) ?? "auto" }

    func minimumContrast(for background: NSColor) -> Double {
        if let customMinimumContrast { return customMinimumContrast }
        let rgb = background.usingColorSpace(.sRGB) ?? background
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return luminance > 0.5 ? 4.5 : 3
    }

    var font: NSFont {
        let weight: NSFont.Weight
        switch fontWeight {
        case ..<450: weight = .regular
        case ..<550: weight = .medium
        case ..<650: weight = .semibold
        default: weight = .bold
        }
        let base = fontFamily == "SF Mono"
            ? NSFont.monospacedSystemFont(ofSize: fontSize, weight: weight)
            : NSFont(name: fontFamily, size: fontSize)
                ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: weight)
        let descriptor = base.fontDescriptor.addingAttributes([
            .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue]
        ])
        return NSFont(descriptor: descriptor, size: fontSize) ?? base
    }

    func palette(for appearance: NSAppearance) -> TerminalTheme {
        switch themeMode {
        case "dark": TerminalTheme.ghosttyDark
        case "light": TerminalTheme.tangoLight
        default: TerminalTheme.resolve(for: appearance)
        }
    }

    func apply(to terminal: TerminalView, isActive: Bool = true) {
        let palette = palette(for: terminal.effectiveAppearance)
        palette.apply(to: terminal)
        terminal.caretColor = palette.cursor.withAlphaComponent(cursorOpacity)
        terminal.minimumContrastRatio = minimumContrast(for: palette.background)
        terminal.scrollSensitivity = scrollSensitivity
        // Automatic keeps SwiftTerm's renderer choice; On/Off switch it explicitly.
        if gpuAcceleration != "auto" { try? terminal.setUseMetal(gpuAcceleration == "on") }
        if terminal.font != font { terminal.font = font }
        switch (cursorShape, cursorBlink) {
        case ("bar", true): terminal.setCursorStyle(.blinkBar)
        case ("bar", false): terminal.setCursorStyle(.steadyBar)
        case ("underline", true): terminal.setCursorStyle(.blinkUnderline)
        case ("underline", false): terminal.setCursorStyle(.steadyUnderline)
        case (_, false): terminal.setCursorStyle(.steadyBlock)
        default: terminal.setCursorStyle(.blinkBlock)
        }
        terminal.optionAsMetaKey = TerminalOptionKey.sendsAlt(defaults)
        terminal.changeScrollback(scrollbackRows)
        terminal.alphaValue = isActive ? 1 : inactiveOpacity
    }

    /// Immediate changes for mounted terminals; creation applies the same snapshot.
    func applyToOpenTerminals() {
        func visit(_ view: NSView) {
            if let terminal = view as? TerminalView {
                apply(to: terminal, isActive: (terminal.superview as? TerminalContainerView)?.isActive ?? true)
            }
            for child in view.subviews { visit(child) }
        }
        for window in NSApp.windows {
            if let content = window.contentView { visit(content) }
        }
    }

    static func applyAppTheme(_ mode: String) {
        switch mode {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: NSApp.appearance = nil
        }
    }

    private func number(_ key: String, fallback: Double, range: ClosedRange<Double>) -> Double {
        guard let value = defaults.object(forKey: key) as? NSNumber,
              value.doubleValue.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, value.doubleValue))
    }
}

import AppKit
import CoreText
import SmthzCore
import SwiftUI

/// UI fonts (UI-SPEC §1.3). Geist is bundled in `Contents/Resources/Fonts` by
/// `scripts/package-app.sh` and registered at runtime; if it is missing
/// (for example under `swift run`) every call falls back to the system font.
enum SmthzFont {
    /// Letter spacing applied to body text, `0.01em` in Orca.
    static let bodyTrackingEm: CGFloat = 0.01
    /// `tracking-tight` (−0.025em) used by the sidebar nav rows.
    static let tightTrackingEm: CGFloat = -0.025

    private static let familyName = "Geist"
    private static let wghtAxis = 2003265652  // 'wght'

    /// True when the bundled Geist font registered (or was already installed).
    static let isGeistAvailable: Bool = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Fonts/Geist-Variable.ttf"),
           FileManager.default.fileExists(atPath: url.path) {
            var error: Unmanaged<CFError>?
            _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        }
        return NSFont(name: "Geist-Regular", size: 12) != nil
            || NSFontManager.shared.availableFontFamilies.contains(familyName)
    }()

    /// Numeric weight (100–900) for a SwiftUI weight.
    static func numericWeight(_ weight: Font.Weight) -> CGFloat {
        switch weight {
        case .ultraLight: return 100
        case .thin: return 200
        case .light: return 300
        case .regular: return 400
        case .medium: return 500
        case .semibold: return 600
        case .bold: return 700
        case .heavy: return 800
        case .black: return 900
        default: return 400
        }
    }

    private static func systemWeight(_ wght: CGFloat) -> NSFont.Weight {
        switch wght {
        case ..<150: return .ultraLight
        case ..<250: return .thin
        case ..<350: return .light
        case ..<450: return .regular
        case ..<550: return .medium
        case ..<650: return .semibold
        case ..<750: return .bold
        case ..<850: return .heavy
        default: return .black
        }
    }

    /// `NSFont` for UI text at an exact variable weight (e.g. 450 for menu items).
    static func nsUI(size: CGFloat, wght: CGFloat) -> NSFont {
        if isGeistAvailable {
            let base = NSFont(name: "Geist-Regular", size: size)
                ?? NSFont(descriptor: NSFontDescriptor(fontAttributes: [.family: familyName]), size: size)
            if let base {
                let descriptor = base.fontDescriptor.addingAttributes([
                    NSFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): [wghtAxis: wght]
                ])
                if let font = NSFont(descriptor: descriptor, size: size) { return font }
                return base
            }
        }
        return NSFont.systemFont(ofSize: size, weight: systemWeight(wght))
    }

    static func nsUI(size: CGFloat, weight: Font.Weight = .regular) -> NSFont {
        nsUI(size: size, wght: numericWeight(weight))
    }

    /// Geist (or system fallback) at `size`; contract name used by other workers.
    static func ui(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font(nsUI(size: size, weight: weight))
    }

    /// Same, with an exact numeric weight such as 450.
    static func ui(size: CGFloat, wght: CGFloat) -> Font {
        Font(nsUI(size: size, wght: wght))
    }

    /// Monospace for branch names and pane titles. SF Mono, falling back to the system monospace.
    static func nsMono(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    static func mono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    // Common presets from the type ramp.
    static var row: Font { ui(size: CGFloat(UIFontSizes.row), weight: .medium) }
    static var tab: Font { ui(size: CGFloat(UIFontSizes.xs)) }
    static var meta: Font { ui(size: CGFloat(UIFontSizes.size2XS)) }
    static var menuItem: Font { ui(size: CGFloat(UIFontSizes.xs), wght: 450) }
}

extension View {
    /// smthz body letter spacing (0.01em) at the given point size.
    func smthzTracking(size: CGFloat, em: CGFloat = SmthzFont.bodyTrackingEm) -> some View {
        tracking(size * em)
    }
}

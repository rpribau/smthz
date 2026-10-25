import Foundation

/// UI-free design tokens mirroring Orca 1.4.238 (`docs/UI-SPEC.md` §1).
/// The SwiftUI layer (`SmthzTheme`) reads from here so values are unit-testable.

/// An sRGB colour with straight alpha, components in 0...1.
public struct TokenColor: Equatable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// `0xRRGGBB` plus an optional alpha.
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    /// Uppercase-free lowercase `#rrggbb` (alpha ignored).
    public var hexString: String {
        func byte(_ v: Double) -> Int { Int((v * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(red), byte(green), byte(blue))
    }

    /// Composites `self` over an opaque background.
    public func composited(over background: TokenColor) -> TokenColor {
        TokenColor(
            red: red * alpha + background.red * (1 - alpha),
            green: green * alpha + background.green * (1 - alpha),
            blue: blue * alpha + background.blue * (1 - alpha),
            alpha: 1
        )
    }
}

/// A token with a light and a dark value.
public struct TokenPair: Equatable, Sendable {
    public var light: TokenColor
    public var dark: TokenColor

    public init(light: TokenColor, dark: TokenColor) {
        self.light = light
        self.dark = dark
    }

    public init(light: UInt32, dark: UInt32) {
        self.init(light: TokenColor(hex: light), dark: TokenColor(hex: dark))
    }

    public func value(dark isDark: Bool) -> TokenColor { isDark ? dark : light }
}

public enum UITokens {
    private static let white = TokenColor(hex: 0xFFFFFF)

    public static let background = TokenPair(light: 0xFFFFFF, dark: 0x0A0A0A)
    public static let foreground = TokenPair(light: 0x0A0A0A, dark: 0xFAFAFA)
    public static let card = TokenPair(light: 0xFFFFFF, dark: 0x171717)
    public static let popover = TokenPair(light: 0xFFFFFF, dark: 0x171717)
    public static let primary = TokenPair(light: 0x171717, dark: 0xE5E5E5)
    public static let primaryForeground = TokenPair(light: 0xFAFAFA, dark: 0x171717)
    public static let secondary = TokenPair(light: 0xF5F5F5, dark: 0x262626)
    public static let secondaryForeground = TokenPair(light: 0x171717, dark: 0xFAFAFA)
    public static let muted = TokenPair(light: 0xF5F5F5, dark: 0x262626)
    public static let mutedForeground = TokenPair(light: 0x737373, dark: 0xA1A1A1)
    public static let accent = TokenPair(light: 0xF5F5F5, dark: 0x404040)
    public static let accentForeground = TokenPair(light: 0x171717, dark: 0xFAFAFA)
    public static let border = TokenPair(light: TokenColor(hex: 0xE5E5E5), dark: TokenColor(hex: 0xFFFFFF, alpha: 0.07))
    public static let input = TokenPair(light: TokenColor(hex: 0xE5E5E5), dark: TokenColor(hex: 0xFFFFFF, alpha: 0.15))
    public static let ring = TokenPair(light: 0xA1A1A1, dark: 0x737373)
    public static let destructive = TokenPair(light: 0xE40014, dark: 0xFF6568)
    public static let editorSurface = TokenPair(light: 0xFFFFFF, dark: 0x1E1E1E)
    public static let worktreeSidebar = TokenPair(light: 0xF5F5F5, dark: 0x2A2A2A)
    public static let worktreeSidebarForeground = TokenPair(light: 0x0A0A0A, dark: 0xFAFAFA)
    public static let worktreeSidebarAccent = TokenPair(light: 0xEAEAEA, dark: 0x353535)
    public static let worktreeSidebarBorder = TokenPair(light: TokenColor(hex: 0xE5E5E5), dark: TokenColor(hex: 0xFFFFFF, alpha: 0.07))
    public static let worktreeSidebarRing = TokenPair(light: 0xA1A1A1, dark: 0x737373)
    public static let sidebar = TokenPair(light: 0xFAFAFA, dark: 0x171717)
    public static let sidebarAccent = TokenPair(light: 0xF5F5F5, dark: 0x262626)
    public static let sidebarPrimary = TokenPair(light: 0x171717, dark: 0x1447E6)
    public static let statusSuccess = TokenPair(light: 0x15803D, dark: 0x86EFAC)
    public static let statusWarning = TokenPair(light: 0xCA8A04, dark: 0xEAB308)
    public static let agentQuestion = TokenPair(light: 0xEA580C, dark: 0xF97316)
    public static let agentWorking = TokenPair(light: 0xEAB308, dark: 0xEAB308)
    public static let terminalPaneLocate = TokenPair(light: 0x2563EB, dark: 0x60A5FA)
    public static let tabGroupSplitDivider = TokenPair(light: 0x868690, dark: 0x71717A)
    public static let tabGroupSplitDividerStrong = TokenPair(light: 0x71717A, dark: 0xA1A1AA)
    public static let terminalSplitDivider = TokenPair(light: 0xD4D4D8, dark: 0x3F3F46)

    public static let gitAdded = TokenPair(light: 0x587C0C, dark: 0x81B88B)
    public static let gitModified = TokenPair(light: 0x895503, dark: 0xE2C08D)
    public static let gitDeleted = TokenPair(light: 0xAD0707, dark: 0xC74E39)
    public static let gitUntracked = TokenPair(light: 0x007100, dark: 0x73C991)

    /// Composited values from UI-SPEC §1.1 (opaque).
    public static let borderOverCard = TokenPair(
        light: border.light.composited(over: card.light),
        dark: border.dark.composited(over: card.dark)
    )
    public static let borderOverWorktreeSidebar = TokenPair(
        light: worktreeSidebarBorder.light.composited(over: worktreeSidebar.light),
        dark: worktreeSidebarBorder.dark.composited(over: worktreeSidebar.dark)
    )
    /// Sidebar search field fill: foreground at 5 % over the sidebar.
    public static let sidebarSearchFill = overlay(worktreeSidebarForeground, 0.05, over: worktreeSidebar)
    /// Sidebar nav hover: foreground at 8 %.
    public static let sidebarNavHover = overlay(worktreeSidebarForeground, 0.08, over: worktreeSidebar)
    /// Sidebar nav inactive text: foreground at 60 %.
    public static let sidebarNavInactiveText = overlay(worktreeSidebarForeground, 0.60, over: worktreeSidebar)
    /// Sidebar nav inactive icon: foreground at 30 %.
    public static let sidebarNavInactiveIcon = overlay(worktreeSidebarForeground, 0.30, over: worktreeSidebar)
    /// Active tab fill: foreground at 6 % over card.
    public static let activeTabFill = overlay(foreground, 0.06, over: card)

    private static func overlay(_ top: TokenPair, _ alpha: Double, over base: TokenPair) -> TokenPair {
        func mix(_ c: TokenColor, _ b: TokenColor) -> TokenColor {
            TokenColor(red: c.red, green: c.green, blue: c.blue, alpha: alpha).composited(over: b)
        }
        return TokenPair(light: mix(top.light, base.light), dark: mix(top.dark, base.dark))
    }
}

/// Layout metrics in points (UI-SPEC §2–§8).
public enum UIMetrics {
    public static let titleBandHeight: Double = 36
    public static let tabStripHeight: Double = 32
    public static let statusBarHeight: Double = 24
    public static let leftSidebarWidth: Double = 280
    public static let leftSidebarMin: Double = 220
    public static let leftSidebarMax: Double = 500
    public static let rightSidebarWidth: Double = 350
    public static let rightSidebarMin: Double = 220
    public static let tabWidth: Double = 180
    public static let tabWidthWide: Double = 220
    public static let tabWidthMin: Double = 72
    public static let tabWideWindowThreshold: Double = 1280
    public static let windowMinWidth: Double = 600
    public static let windowMinHeight: Double = 400
    public static let trafficLightX: Double = 16
    public static let trafficLightCenterY: Double = 18

    public static let radius: Double = 10
    public static let radiusSM: Double = 6
    public static let radiusMD: Double = 8
    public static let radiusLG: Double = 10
    public static let radiusXL: Double = 14
    public static let radius2XL: Double = 18
    public static let radiusMenu: Double = 11

    public static let iconButtonXS: Double = 24
    public static let navRowHeight: Double = 32
    public static let projectHeaderHeight: Double = 28
}

/// Type ramp (UI-SPEC §1.3).
public enum UIFontSizes {
    public static let size3XS: Double = 10
    public static let size2XS: Double = 11
    public static let xs: Double = 12
    public static let row: Double = 13
    public static let sm: Double = 14
    public static let lg: Double = 18
    public static let xl2: Double = 24
    public static let xl4: Double = 36
    public static let landingTitle: Double = 48
}

/// Motion durations in seconds (UI-SPEC §1.5).
public enum UIMotion {
    public static let sidebar: Double = 0.200
    public static let card: Double = 0.200
    public static let splitDivider: Double = 0.100
    public static let menu: Double = 0.150
    public static let dialog: Double = 0.200
    public static let settingsEnter: Double = 0.180
    public static let terminalPane: Double = 0.140
    public static let paneFocusFlash: Double = 1.5
}

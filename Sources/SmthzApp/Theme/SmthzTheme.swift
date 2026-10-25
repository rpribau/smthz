import AppKit
import SmthzCore
import SwiftUI

/// Dynamic colours (light/dark) read from `UITokens`. See docs/UI-SPEC.md §1, §16.
enum SmthzTheme {
    static func dynamicNSColor(_ pair: TokenPair) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = pair.value(dark: isDark)
            return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
        }
    }

    static func color(_ pair: TokenPair) -> Color { Color(nsColor: dynamicNSColor(pair)) }

    static let background = color(UITokens.background)
    static let foreground = color(UITokens.foreground)
    static let card = color(UITokens.card)
    static let popover = color(UITokens.popover)
    static let primary = color(UITokens.primary)
    static let primaryForeground = color(UITokens.primaryForeground)
    static let secondary = color(UITokens.secondary)
    static let secondaryForeground = color(UITokens.secondaryForeground)
    static let muted = color(UITokens.muted)
    static let mutedForeground = color(UITokens.mutedForeground)
    static let accent = color(UITokens.accent)
    static let accentForeground = color(UITokens.accentForeground)
    static let border = color(UITokens.border)
    static let input = color(UITokens.input)
    static let ring = color(UITokens.ring)
    static let destructive = color(UITokens.destructive)
    static let editorSurface = color(UITokens.editorSurface)
    static let worktreeSidebar = color(UITokens.worktreeSidebar)
    static let worktreeSidebarForeground = color(UITokens.worktreeSidebarForeground)
    static let worktreeSidebarAccent = color(UITokens.worktreeSidebarAccent)
    static let worktreeSidebarBorder = color(UITokens.worktreeSidebarBorder)
    static let worktreeSidebarRing = color(UITokens.worktreeSidebarRing)
    static let sidebar = color(UITokens.sidebar)
    static let sidebarAccent = color(UITokens.sidebarAccent)
    static let statusSuccess = color(UITokens.statusSuccess)
    static let statusWarning = color(UITokens.statusWarning)
    static let agentQuestion = color(UITokens.agentQuestion)
    static let agentWorking = color(UITokens.agentWorking)
    static let terminalPaneLocate = color(UITokens.terminalPaneLocate)
    static let tabGroupSplitDivider = color(UITokens.tabGroupSplitDivider)
    static let tabGroupSplitDividerStrong = color(UITokens.tabGroupSplitDividerStrong)
    static let terminalSplitDivider = color(UITokens.terminalSplitDivider)

    // Composites (UI-SPEC §1.1)
    static let borderOverCard = color(UITokens.borderOverCard)
    static let borderOverWorktreeSidebar = color(UITokens.borderOverWorktreeSidebar)
    static let sidebarSearchFill = color(UITokens.sidebarSearchFill)
    static let sidebarNavHover = color(UITokens.sidebarNavHover)
    static let sidebarNavInactiveText = color(UITokens.sidebarNavInactiveText)
    static let sidebarNavInactiveIcon = color(UITokens.sidebarNavInactiveIcon)
    static let activeTabFill = color(UITokens.activeTabFill)
}

/// Layout metrics in points. Values come from `UIMetrics` (UI-SPEC §2–§8).
enum SmthzMetrics {
    static let titleBandHeight: CGFloat = UIMetrics.titleBandHeight
    static let tabStripHeight: CGFloat = UIMetrics.tabStripHeight
    static let statusBarHeight: CGFloat = UIMetrics.statusBarHeight
    static let leftSidebarWidth: CGFloat = UIMetrics.leftSidebarWidth
    static let leftSidebarMin: CGFloat = UIMetrics.leftSidebarMin
    static let leftSidebarMax: CGFloat = UIMetrics.leftSidebarMax
    static let rightSidebarWidth: CGFloat = UIMetrics.rightSidebarWidth
    static let rightSidebarMin: CGFloat = UIMetrics.rightSidebarMin
    static let tabWidth: CGFloat = UIMetrics.tabWidth
    static let tabWidthWide: CGFloat = UIMetrics.tabWidthWide
    static let tabWidthMin: CGFloat = UIMetrics.tabWidthMin
    static let tabWideWindowThreshold: CGFloat = UIMetrics.tabWideWindowThreshold
    static let windowMinWidth: CGFloat = UIMetrics.windowMinWidth
    static let windowMinHeight: CGFloat = UIMetrics.windowMinHeight
    static let trafficLightX: CGFloat = UIMetrics.trafficLightX
    static let trafficLightCenterY: CGFloat = UIMetrics.trafficLightCenterY

    static let radius: CGFloat = UIMetrics.radius
    static let radiusSM: CGFloat = UIMetrics.radiusSM
    static let radiusMD: CGFloat = UIMetrics.radiusMD
    static let radiusLG: CGFloat = UIMetrics.radiusLG
    static let radiusXL: CGFloat = UIMetrics.radiusXL
    static let radius2XL: CGFloat = UIMetrics.radius2XL
    static let radiusMenu: CGFloat = UIMetrics.radiusMenu

    static let iconButtonXS: CGFloat = UIMetrics.iconButtonXS
    static let navRowHeight: CGFloat = UIMetrics.navRowHeight
    static let projectHeaderHeight: CGFloat = UIMetrics.projectHeaderHeight
}

/// Motion durations in seconds (UI-SPEC §1.5).
enum SmthzMotion {
    static let sidebar: Double = UIMotion.sidebar
    static let card: Double = UIMotion.card
    static let splitDivider: Double = UIMotion.splitDivider
    static let menu: Double = UIMotion.menu
    static let dialog: Double = UIMotion.dialog
    static let settingsEnter: Double = UIMotion.settingsEnter
    static let terminalPane: Double = UIMotion.terminalPane
    static let paneFocusFlash: Double = UIMotion.paneFocusFlash
}

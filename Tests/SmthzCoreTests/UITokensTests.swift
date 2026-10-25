import Testing
@testable import SmthzCore

@Suite("UITokens")
struct UITokensTests {
    @Test func coreSurfaceHex() {
        #expect(UITokens.background.light.hexString == "#ffffff")
        #expect(UITokens.background.dark.hexString == "#0a0a0a")
        #expect(UITokens.foreground.dark.hexString == "#fafafa")
        #expect(UITokens.card.dark.hexString == "#171717")
        #expect(UITokens.worktreeSidebar.light.hexString == "#f5f5f5")
        #expect(UITokens.worktreeSidebar.dark.hexString == "#2a2a2a")
        #expect(UITokens.worktreeSidebarAccent.light.hexString == "#eaeaea")
        #expect(UITokens.worktreeSidebarAccent.dark.hexString == "#353535")
        #expect(UITokens.sidebar.light.hexString == "#fafafa")
        #expect(UITokens.destructive.light.hexString == "#e40014")
        #expect(UITokens.destructive.dark.hexString == "#ff6568")
        #expect(UITokens.mutedForeground.light.hexString == "#737373")
        #expect(UITokens.mutedForeground.dark.hexString == "#a1a1a1")
    }

    @Test func darkBorderIsTranslucentWhite() {
        let b = UITokens.border.dark
        #expect(b.hexString == "#ffffff")
        #expect(abs(b.alpha - 0.07) < 1e-9)
        #expect(UITokens.border.light.alpha == 1)
        #expect(abs(UITokens.input.dark.alpha - 0.15) < 1e-9)
    }

    @Test func compositesMatchSpecTable() {
        #expect(UITokens.borderOverCard.dark.hexString == "#272727")
        #expect(UITokens.borderOverWorktreeSidebar.dark.hexString == "#393939")
        #expect(UITokens.sidebarSearchFill.light.hexString == "#e9e9e9")
        #expect(UITokens.sidebarSearchFill.dark.hexString == "#343434")
        #expect(UITokens.sidebarNavHover.light.hexString == "#e2e2e2")
        #expect(UITokens.sidebarNavHover.dark.hexString == "#3b3b3b")
        #expect(UITokens.sidebarNavInactiveText.light.hexString == "#686868")
        #expect(UITokens.sidebarNavInactiveText.dark.hexString == "#a7a7a7")
        #expect(UITokens.sidebarNavInactiveIcon.light.hexString == "#aeaeae")
        #expect(UITokens.sidebarNavInactiveIcon.dark.hexString == "#686868")
        #expect(UITokens.activeTabFill.light.hexString == "#f0f0f0")
        #expect(UITokens.activeTabFill.dark.hexString == "#252525")
    }

    @Test func valueSelectsAppearance() {
        let pair = UITokens.background
        #expect(pair.value(dark: false) == pair.light)
        #expect(pair.value(dark: true) == pair.dark)
    }

    @Test func metricsMatchContract() {
        #expect(UIMetrics.titleBandHeight == 36)
        #expect(UIMetrics.tabStripHeight == 32)
        #expect(UIMetrics.statusBarHeight == 24)
        #expect(UIMetrics.leftSidebarWidth == 280)
        #expect(UIMetrics.leftSidebarMin == 220)
        #expect(UIMetrics.leftSidebarMax == 500)
        #expect(UIMetrics.rightSidebarWidth == 350)
        #expect(UIMetrics.tabWidth == 180)
        #expect(UIMetrics.tabWidthWide == 220)
        #expect(UIMetrics.windowMinWidth == 600)
        #expect(UIMetrics.windowMinHeight == 400)
        #expect(UIMetrics.radiusMenu == 11)
        #expect(UIFontSizes.row == 13)
    }
}

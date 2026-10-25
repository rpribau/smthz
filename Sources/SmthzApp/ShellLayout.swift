import AppKit
import SwiftUI

/// Flat shell geometry; each slot has an independent replacement boundary.
struct ShellLayout<Sidebar: View, Tabs: View, Content: View, Right: View, Status: View>: View {
    @Environment(\.smthzShellActions) private var actions
    @AppStorage("shell.showStatusBar") private var showStatusBar = true
    @AppStorage("shell.leftSidebarWidth") private var storedLeftWidth = 280.0
    @AppStorage("shell.rightSidebarWidth") private var storedRightWidth = 350.0
    @Binding var sidebarOpen: Bool
    @Binding var rightSidebarOpen: Bool
    @State private var leftDragStart: CGFloat?
    @State private var rightDragStart: CGFloat?
    @State private var hoveringLeft = false
    @State private var hoveringRight = false
    let sidebar: Sidebar
    let tabs: Tabs
    let content: Content
    let right: Right
    let status: Status

    var body: some View {
        GeometryReader { geometry in
            let leftWidth = min(max(CGFloat(storedLeftWidth), SmthzMetrics.leftSidebarMin),
                                min(SmthzMetrics.leftSidebarMax, max(0, geometry.size.width - 320)))
            let available = geometry.size.width - (sidebarOpen ? leftWidth : 0)
            let showRight = rightSidebarOpen && available >= 540
            let rightWidth = min(max(220, CGFloat(storedRightWidth)), max(220, available - 320))
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    if sidebarOpen {
                        sidebar
                            .frame(width: leftWidth)
                            .overlay(alignment: .trailing) {
                                resizeHandle(left: true, width: leftWidth)
                                    .offset(x: 6)
                            }
                            .zIndex(2)
                    }
                    VStack(spacing: 0) {
                        WindowDragRegion()
                            .frame(height: SmthzMetrics.titleBandHeight - SmthzMetrics.tabStripHeight)
                            .background(SmthzTheme.card)
                        tabs
                            .padding(.leading, sidebarOpen ? 0 : 220)
                            .frame(height: SmthzMetrics.tabStripHeight)
                            .background(SmthzTheme.card)
                        content.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .leading) { SmthzTheme.border.frame(width: 1).allowsHitTesting(false) }
                    if showRight {
                        right.frame(width: rightWidth)
                            .overlay(alignment: .leading) { resizeHandle(left: false, width: rightWidth) }
                    }
                }
                if showStatusBar { status.frame(height: SmthzMetrics.statusBarHeight) }
            }
            .overlay(alignment: .topLeading) {
                if !sidebarOpen {
                    ShellTitleControls(sidebarOpen: $sidebarOpen)
                        .frame(width: 220, height: SmthzMetrics.titleBandHeight)
                        .background(SmthzTheme.card)
                        .overlay(alignment: .trailing) { SmthzTheme.border.frame(width: 1) }
                }
            }
            .overlay(alignment: .topTrailing) {
                if !showRight {
                    Button { rightSidebarOpen.toggle() } label: {
                        SmthzIcon.view(.panelRight).frame(width: 32, height: SmthzMetrics.titleBandHeight)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(SmthzTheme.mutedForeground)
                    .background(SmthzTheme.card)
                    .smthzTooltip("Toggle right sidebar (⌘L)")
                    .accessibilityLabel("Toggle right sidebar")
                }
            }
        }
        .focusedSceneValue(\.smthzShellActions, actions)
        .background(SmthzTheme.background)
        .foregroundStyle(SmthzTheme.foreground)
    }

    private func resizeHandle(left: Bool, width: CGFloat) -> some View {
        let hovering = left ? hoveringLeft : hoveringRight
        let dragging = left ? leftDragStart != nil : rightDragStart != nil
        return ZStack {
            Color.clear
            SmthzTheme.ring.opacity(dragging ? 1 : hovering ? 0.5 : 0)
                .frame(width: 1)
        }
        .frame(width: left ? 12 : 4)
        .contentShape(Rectangle())
        .onHover { inside in
            if left { hoveringLeft = inside } else { hoveringRight = inside }
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if left {
                    if leftDragStart == nil { leftDragStart = width }
                    storedLeftWidth = min(SmthzMetrics.leftSidebarMax,
                        max(SmthzMetrics.leftSidebarMin, (leftDragStart ?? width) + value.translation.width))
                } else {
                    if rightDragStart == nil { rightDragStart = width }
                    storedRightWidth = max(220, (rightDragStart ?? width) - value.translation.width)
                }
            }
            .onEnded { _ in
                if left { leftDragStart = nil } else { rightDragStart = nil }
            })
        .accessibilityLabel(left ? "Resize left sidebar" : "Resize right sidebar")
        .accessibilityAdjustableAction { direction in
            let delta = direction == .increment ? 20.0 : -20.0
            if left {
                storedLeftWidth = min(SmthzMetrics.leftSidebarMax, max(SmthzMetrics.leftSidebarMin, storedLeftWidth + delta))
            } else { storedRightWidth = max(220, storedRightWidth + delta) }
        }
    }
}

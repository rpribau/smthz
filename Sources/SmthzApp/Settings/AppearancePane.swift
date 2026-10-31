import SwiftUI

// VISUAL-ONLY: rows built with SmthzUnavailableSetting wait for window, file explorer and status indicator backends.
struct AppearancePane: View {
    @Binding var sidebarOpen: Bool
    @Binding var rightSidebarOpen: Bool
    @State private var tab = "interface"
    @AppStorage(TerminalSettingsModel.Key.appTheme) private var theme = "system"
    @AppStorage("sidebar.showTasksButton") private var showTasks = true
    @AppStorage("sidebar.showAutomationsButton") private var showAutomations = true
    @AppStorage("sidebar.showMobileButton") private var showMobile = true
    @AppStorage("statusBar.showResourceManager") private var showResources = true
    @AppStorage("shell.uiZoom") private var uiZoom = 1.0
    @AppStorage("shell.showTitlebarAppName") private var showAppName = true
    @AppStorage("shell.showStatusBar") private var showStatusBar = true
    /// Shared with the sidebar's Workspace options menu.
    @AppStorage(WorkspaceOptions.Key.cardLayout) private var cardLayout = WorkspaceOptions.CardLayout.detailed.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ViewThatFits(in: .horizontal) {
                tabButtons(horizontal: true)
                tabButtons(horizontal: false)
            }
            switch tab {
            case "terminal": SmthzTerminalSettingsControls()
            case "window": windowAndSidebar
            default: interface
            }
        }
        .onAppear { TerminalSettingsModel.applyAppTheme(theme) }
        .onChange(of: theme) { _, value in TerminalSettingsModel.applyAppTheme(value) }
    }

    private func tabButtons(horizontal: Bool) -> some View {
        let layout = horizontal ? AnyLayout(HStackLayout(spacing: 4)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
        return layout {
            tabButton("Interface", icon: "app-window", id: "interface")
            tabButton("Terminal", icon: "square-terminal", id: "terminal")
            tabButton("Window & Sidebar", icon: "panel-left", id: "window")
        }
        .padding(4)
        .background(SmthzTheme.muted, in: RoundedRectangle(cornerRadius: 8))
    }

    private func tabButton(_ title: String, icon: String, id: String) -> some View {
        Button { tab = id } label: {
            HStack(spacing: 8) {
                if icon == "app-window" {
                    Image(systemName: "macwindow").resizable().frame(width: 14, height: 14)
                } else {
                    SmthzIcon.image(icon).resizable().frame(width: 14, height: 14)
                }
                Text(title).font(SmthzFont.ui(size: 13, weight: tab == id ? .medium : .regular))
            }
            .padding(.horizontal, 12).frame(height: 32)
            .background(tab == id ? SmthzTheme.background : .clear, in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(tab == id ? SmthzTheme.foreground : SmthzTheme.mutedForeground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(id == "window" ? "Sidebar, status bar, and file explorer" : title)
        .accessibilityAddTraits(tab == id ? .isSelected : [])
    }

    private var interface: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsRow("Theme") {
                SettingsSegmented(options: [("System", "system"), ("Dark", "dark"), ("Light", "light")],
                                  selection: $theme, accessibilityLabel: "Theme")
            }
            SettingsRow("Language") { SettingsValueText("English") }
            // ⌘= / ⌘− still change terminal font size (M3 D7), so no shortcut hint here.
            SettingsRow("UI Zoom", detail: "Scale the whole interface. Terminal text keeps its own font size.") {
                HStack(spacing: 8) {
                    Button { uiZoom = Self.zoomStep(uiZoom, by: -1) } label: {
                        SmthzIcon.view("minus", size: 12).frame(width: 24, height: 24)
                    }
                    .buttonStyle(SmthzButtonStyle(.outline, size: .iconXS)).disabled(uiZoom <= 0.75)
                    .accessibilityLabel("Zoom out interface")
                    Button("\(Int((min(1.5, max(0.75, uiZoom)) * 100).rounded()))%") { uiZoom = 1 }
                        .buttonStyle(.plain).font(SmthzFont.mono(size: 13)).monospacedDigit().frame(minWidth: 48)
                        .help("Reset zoom").accessibilityLabel("UI Zoom, reset to 100%")
                    Button { uiZoom = Self.zoomStep(uiZoom, by: 1) } label: {
                        SmthzIcon.view(.plus, size: 12).frame(width: 24, height: 24)
                    }
                    .buttonStyle(SmthzButtonStyle(.outline, size: .iconXS)).disabled(uiZoom >= 1.5)
                    .accessibilityLabel("Zoom in interface")
                }
            }
            SettingsRow("IDE Font") { SettingsValueText("Default font · Geist") }
            SettingsRow("Titlebar App Name", detail: "Show the app name in the titlebar.") {
                SettingsToggle(title: "Titlebar App Name", isOn: $showAppName)
            }
            SmthzUnavailableSetting("App Icon", detail: "Choose the app icon shown in the Dock and window switcher.", value: "Default")
            SmthzUnavailableSetting("Minimize to Tray on Close", value: "Off")
            SmthzUnavailableSetting("Show Menu Bar Icon", detail: "Keep a smthz shortcut and activity indicator in the macOS menu bar.", value: "Off")
            SmthzUnavailableSetting("Follow symlinked directories", value: "Off")
        }
    }

    private static func zoomStep(_ value: Double, by direction: Double) -> Double {
        min(1.5, max(0.75, ((value + direction * 0.1) * 10).rounded() / 10))
    }

    private var windowAndSidebar: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsGroupTitle(title: "Status Bar")
            Text("Choose which indicators appear in the status bar.")
                .font(SmthzFont.ui(size: 13)).foregroundStyle(SmthzTheme.mutedForeground)
            SettingsRow("Show Status Bar") { SettingsToggle(title: "Show Status Bar", isOn: $showStatusBar) }
            SettingsRow("Resource Manager") {
                SettingsToggle(title: "Resource Manager", isOn: $showResources)
            }
            SmthzUnavailableSetting("Remote Hosts", value: "Off")
            SmthzUnavailableSetting("Ports", value: "Off")
            SmthzUnavailableSetting("Usage percentages", value: "Used / Remaining")
            Divider().overlay(SmthzTheme.border).padding(.vertical, 8)
            SettingsGroupTitle(title: "Sidebar")
            SettingsRow("Workspace Card Layout", detail: "Same choice as the sidebar's workspace options menu.") {
                SettingsSegmented(options: WorkspaceOptions.CardLayout.allCases.map { ($0.title, $0.rawValue) },
                                  selection: $cardLayout, accessibilityLabel: "Workspace Card Layout")
            }
            SettingsRow("Show Tasks Button") { SettingsToggle(title: "Show Tasks Button", isOn: $showTasks) }
            SettingsRow("Show Automations Button") { SettingsToggle(title: "Show Automations Button", isOn: $showAutomations) }
            SettingsRow("Show smthz Mobile Button", detail: "Show the smthz Mobile shortcut in the sidebar. It remains available from Toolbox.") {
                SettingsToggle(title: "Show smthz Mobile Button", isOn: $showMobile)
            }
            SmthzUnavailableSetting("Also show pinned worktrees in their original lists", value: "Off")
            SettingsRow("Left sidebar") { SettingsToggle(title: "Left sidebar", isOn: $sidebarOpen) }
            SettingsRow("Right sidebar") { SettingsToggle(title: "Right sidebar", isOn: $rightSidebarOpen) }
            Divider().overlay(SmthzTheme.border).padding(.vertical, 8)
            SettingsGroupTitle(title: "File Explorer")
            SmthzUnavailableSetting("Show Git-Ignored Files", detail: "Files matched by .gitignore.", value: "Off")
        }
    }
}

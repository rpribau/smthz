import SwiftUI

// VISUAL-ONLY: stub data until window, file explorer and additional status indicator settings exist.
struct AppearancePane: View {
    @Binding var sidebarOpen: Bool
    @Binding var rightSidebarOpen: Bool
    @State private var tab = "interface"
    @AppStorage(TerminalSettingsModel.Key.appTheme) private var theme = "system"
    @AppStorage("sidebar.showTasksButton") private var showTasks = true
    @AppStorage("sidebar.showAutomationsButton") private var showAutomations = true
    @AppStorage("sidebar.showMobileButton") private var showMobile = true
    @AppStorage("statusBar.showResourceManager") private var showResources = true

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
            SmthzUnavailableSetting("UI Zoom", detail: "Adjust the interface when not in a terminal pane.", value: "100%")
            SettingsRow("IDE Font") { SettingsValueText("Default font · Geist") }
            SmthzUnavailableSetting("Titlebar App Name", value: "smthz")
            SmthzUnavailableSetting("App Icon", detail: "Choose the app icon shown in the Dock and window switcher.", value: "Default")
            SmthzUnavailableSetting("Minimize to Tray on Close", value: "Off")
            SmthzUnavailableSetting("Show Menu Bar Icon", detail: "Keep a smthz shortcut and activity indicator in the macOS menu bar.", value: "Off")
            SmthzUnavailableSetting("Follow symlinked directories", value: "Off")
        }
    }

    private var windowAndSidebar: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsGroupTitle(title: "Status Bar")
            Text("Choose which indicators appear in the status bar.")
                .font(SmthzFont.ui(size: 13)).foregroundStyle(SmthzTheme.mutedForeground)
            SettingsRow("Resource Manager") {
                SettingsToggle(title: "Resource Manager", isOn: $showResources)
            }
            SmthzUnavailableSetting("Remote Hosts", value: "Off")
            SmthzUnavailableSetting("Ports", value: "Off")
            SmthzUnavailableSetting("Usage percentages", value: "Used / Remaining")
            Divider().overlay(SmthzTheme.border).padding(.vertical, 8)
            SettingsGroupTitle(title: "Sidebar")
            SmthzUnavailableSetting("Workspace Card Layout", value: "Detailed / Compact")
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

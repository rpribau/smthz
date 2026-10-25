import AppKit
import SwiftUI

// VISUAL-ONLY: stub data until terminal shell, rendering, split-pane and interaction settings integration.
struct TerminalSettingsPane: View {
    let model: WorkspaceModel

    var body: some View {
        SmthzTerminalSettingsControls(onFontSizeChange: { model.terminalFontSize = $0 })
    }
}

/// Shared by the Terminal settings destination and Appearance's Terminal tab.
/// All enabled preferences use the same keys; UI-29 consumes TerminalSettingsModel in surfaces.
struct SmthzTerminalSettingsControls: View {
    var onFontSizeChange: ((Double) -> Void)?
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(TerminalSettingsModel.Key.fontSize) private var fontSize = 14.0
    @AppStorage(TerminalSettingsModel.Key.fontFamily) private var fontFamily = "SF Mono"
    @AppStorage(TerminalSettingsModel.Key.fontWeight) private var fontWeight = 500.0
    @AppStorage(TerminalSettingsModel.Key.cursorShape) private var cursorShape = "block"
    @AppStorage(TerminalSettingsModel.Key.cursorBlink) private var cursorBlink = true
    @AppStorage(TerminalSettingsModel.Key.themeMode) private var themeMode = "system"
    @AppStorage(TerminalSettingsModel.Key.darkTheme) private var darkTheme = "ghostty-dark"
    @AppStorage(TerminalSettingsModel.Key.lightTheme) private var lightTheme = "tango-light"
    @AppStorage(TerminalSettingsModel.Key.inactiveOpacity) private var inactiveOpacity = 0.9
    @AppStorage(TerminalSettingsModel.Key.scrollbackRows) private var scrollbackRows = 10_000
    @AppStorage(TerminalSettingsModel.Key.optionAsAlt) private var optionAsAlt = "auto"
    @State private var previewDivider = false

    private var settingsSignature: String {
        "\(fontSize)|\(fontFamily)|\(fontWeight)|\(cursorShape)|\(cursorBlink)|\(themeMode)|\(darkTheme)|\(lightTheme)|\(inactiveOpacity)|\(scrollbackRows)|\(optionAsAlt)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 40) {
            shell
            typography
            rendering
            cursor
            themes
            panes
            interaction
            window
            advanced
        }
        .onAppear { onFontSizeChange?(TerminalSettingsModel().fontSize) }
        .onChange(of: settingsSignature) { _, _ in
            onFontSizeChange?(TerminalSettingsModel().fontSize)
            TerminalSettingsModel().applyToOpenTerminals()
        }
    }

    private var shell: some View {
        VStack(alignment: .leading, spacing: 24) {
            SmthzUnavailableSetting("Terminal shell", value: "System shell (/bin/zsh)")
            SmthzUnavailableSetting("Shell arguments", value: "-l (default)")
        }
    }

    private var typography: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsGroupTitle(title: "Typography")
            SettingsRow("Font Size") {
                SettingsStepper(value: $fontSize, range: 8...40, unit: "px", accessibilityLabel: "terminal font size")
            }
            SettingsRow("Font Family") {
                Picker("Font Family", selection: $fontFamily) {
                    ForEach(["SF Mono", "Menlo", "Monaco", "Courier"], id: \.self) { Text($0).tag($0) }
                }.labelsHidden().frame(width: 180).accessibilityLabel("Font Family")
            }
            SettingsRow("Font Weight") {
                Picker("Font Weight", selection: $fontWeight) {
                    Text("Regular · 400").tag(400.0)
                    Text("Medium · 500").tag(500.0)
                    Text("Semibold · 600").tag(600.0)
                    Text("Bold · 700").tag(700.0)
                }.labelsHidden().frame(width: 180).accessibilityLabel("Font Weight")
            }
            SmthzUnavailableSetting("Bold Font Weight", value: "700")
            SmthzUnavailableSetting("Line Height", value: "1.0")
            SmthzUnavailableSetting("Font Ligatures", value: "Auto / On / Off")
            unavailableButton("Import from Ghostty")
        }
    }

    private var rendering: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsGroupTitle(title: "Rendering")
            SmthzUnavailableSetting("GPU Acceleration", value: "Auto / On / Off")
            SmthzUnavailableSetting("Color Contrast", value: "Automatic / Off / Custom")
            SmthzUnavailableSetting("Inline Images", value: "Off")
        }
    }

    private var cursor: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsGroupTitle(title: "Cursor")
            SettingsRow("Cursor Shape") {
                SettingsSegmented(options: [("Bar", "bar"), ("Block", "block"), ("Underline", "underline")],
                                  selection: $cursorShape, accessibilityLabel: "Cursor Shape")
            }
            SettingsRow("Blinking Cursor") { SettingsToggle(title: "Blinking Cursor", isOn: $cursorBlink) }
            SmthzUnavailableSetting("Cursor Opacity", value: "100%")
        }
    }

    private var themes: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsGroupTitle(title: "Themes")
            SettingsRow("Theme Mode") {
                Picker("Theme Mode", selection: $themeMode) {
                    Text("Dark").tag("dark")
                    Text("Light").tag("light")
                    Text("Match dark mode").tag("system")
                }.labelsHidden().frame(width: 180).accessibilityLabel("Theme Mode")
            }
            SettingsRow("Dark Theme") {
                SmthzTerminalPalettePicker(isDark: true, selection: $darkTheme)
            }
            SettingsRow("Light Theme") {
                SmthzTerminalPalettePicker(isDark: false, selection: $lightTheme)
            }
            SmthzUnavailableSetting("Dark Divider Color", value: "#3f3f46")
            SmthzUnavailableSetting("Light Divider Color", value: "#d4d4d8")
            HStack(spacing: 12) { unavailableButton("Import from YAML"); unavailableButton("Import from Warp") }
            terminalPreview
            Toggle("Show pane divider in preview", isOn: $previewDivider)
                .toggleStyle(.checkbox).font(SmthzFont.ui(size: 13))
        }
    }

    private var terminalPreview: some View {
        let dark = themeMode == "dark" || (themeMode == "system" && colorScheme == .dark)
        let palette = dark ? TerminalTheme.ghosttyDark : TerminalTheme.tangoLight
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: dark ? "moon" : "sun.max").resizable().frame(width: 14, height: 14)
                Text("Terminal preview").font(SmthzFont.ui(size: 12))
                Spacer()
            }.foregroundStyle(SmthzTheme.mutedForeground)
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("smthz ~ % echo hello")
                    Text("hello").foregroundStyle(Color(nsColor: palette.cursor))
                    HStack(spacing: 0) {
                        Text("smthz ~ % ")
                        Text(cursorShape == "bar" ? "▏" : cursorShape == "underline" ? "▁" : "█")
                            .accessibilityLabel("\(cursorShape) cursor")
                    }
                }
                if previewDivider {
                    Rectangle().fill(dark ? Color(nsColor: .darkGray) : Color(nsColor: .lightGray))
                        .frame(width: 3, height: 80)
                    Text("Inactive pane").opacity(inactiveOpacity)
                }
                Spacer(minLength: 0)
            }
            .font(Font(TerminalSettingsModel().font))
            .foregroundStyle(Color(nsColor: palette.foreground))
            .padding(16).frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
            .background(Color(nsColor: palette.background), in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(SmthzTheme.border, lineWidth: 1) }
        }
    }

    private var panes: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsGroupTitle(title: "Panes")
            SettingsRow("Inactive Pane Opacity") {
                HStack(spacing: 8) {
                    Slider(value: $inactiveOpacity, in: 0.2...1, step: 0.05).frame(width: 120)
                        .accessibilityLabel("Inactive Pane Opacity")
                    Text("\(Int((inactiveOpacity * 100).rounded()))%").monospacedDigit().frame(width: 40)
                }.font(SmthzFont.ui(size: 13))
            }
            SmthzUnavailableSetting("Divider Thickness", value: "3 px")
        }
    }

    private var interaction: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsGroupTitle(title: "Interaction")
            SmthzUnavailableSetting("Scroll Speed", value: "Normal / Fast / TUI")
            SmthzUnavailableSetting("Right-click to paste", value: "Off")
            SmthzUnavailableSetting("Focus Follows Mouse", value: "Off")
            SmthzUnavailableSetting("Copy on Select", value: "Off")
            SmthzUnavailableSetting("Trim Gutter on Copy", value: "Off")
            SmthzUnavailableSetting("Allow TUI Clipboard Writes (OSC 52)", value: "Off")
            SmthzUnavailableSetting("Ask Before Closing Running Terminals", value: "On")
        }
    }

    private var window: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsGroupTitle(title: "Window")
            SmthzUnavailableSetting("Background Opacity", value: "100%")
            SmthzUnavailableSetting("Window Blur", detail: "Restart required", value: "Off")
            SmthzUnavailableSetting("Horizontal Padding", value: "4 px")
            SmthzUnavailableSetting("Vertical Padding", value: "4 px")
            SmthzUnavailableSetting("Hide Mouse While Typing", value: "On")
            SmthzUnavailableSetting("Color Overrides", value: "Default")
            unavailableButton("Reset all color overrides")
            unavailableButton("Manage Sessions")
        }
    }

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsGroupTitle(title: "Advanced")
            SettingsRow("Scrollback Rows", detail: "Terminal emulator history; host replay storage is managed separately.") {
                Picker("Scrollback Rows", selection: $scrollbackRows) {
                    ForEach([1_000, 5_000, 10_000, 50_000, 100_000], id: \.self) { rows in
                        Text("\(rows.formatted()) rows").tag(rows)
                    }
                }.labelsHidden().frame(width: 180).accessibilityLabel("Scrollback Rows")
            }
            SmthzUnavailableSetting("Word Separators", value: "Default")
            SettingsRow("Option as Alt") {
                Picker("Option as Alt", selection: $optionAsAlt) {
                    Text("Auto").tag("auto")
                    Text("Both").tag("both")
                    Text("Left · Not available yet").tag("left").disabled(true)
                    Text("Right · Not available yet").tag("right").disabled(true)
                    Text("Off").tag("off")
                }.labelsHidden().frame(width: 180).accessibilityLabel("Option as Alt")
            }
            SmthzUnavailableSetting("JIS Yen (¥) to Backslash", value: "Off")
        }
    }

    private func unavailableButton(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(title) {}.buttonStyle(SmthzButtonStyle(.outline)).disabled(true)
            Text("Not available yet").font(SmthzFont.ui(size: 11)).foregroundStyle(SmthzTheme.mutedForeground)
        }
    }
}

/// A disabled control always explains its availability inline, including for keyboard users.
struct SmthzUnavailableSetting: View {
    let title: String
    var detail: String?
    let value: String
    init(_ title: String, detail: String? = nil, value: String) {
        self.title = title; self.detail = detail; self.value = value
    }
    var body: some View {
        SettingsRow(title, detail: [detail, "Not available yet"].compactMap { $0 }.joined(separator: " · ")) {
            Button(value) {}.buttonStyle(SmthzButtonStyle(.outline)).disabled(true)
        }
    }
}

private struct SmthzTerminalPalettePicker: View {
    let isDark: Bool
    @Binding var selection: String
    @State private var open = false
    @State private var search = ""
    private var title: String { isDark ? "Ghostty Default Style Dark" : "Builtin Tango Light" }
    var body: some View {
        Button(title) { search = ""; open.toggle() }
            .buttonStyle(SmthzButtonStyle(.outline))
            .popover(isPresented: $open) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Built-in").font(SmthzFont.ui(size: 13, weight: .medium))
                        Spacer()
                        Text("Imported · Not available yet").foregroundStyle(SmthzTheme.mutedForeground)
                    }
                    TextField("Search terminal themes", text: $search).textFieldStyle(.roundedBorder)
                    if search.isEmpty || title.localizedCaseInsensitiveContains(search) {
                        Button {
                            selection = isDark ? "ghostty-dark" : "tango-light"
                            open = false
                        } label: {
                            HStack {
                                Text(title)
                                Spacer()
                                SmthzIcon.image("check").resizable().frame(width: 14, height: 14)
                            }.padding(8).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    } else {
                        Text("No themes found.").foregroundStyle(SmthzTheme.mutedForeground).padding(8)
                    }
                }
                .font(SmthzFont.ui(size: 12)).padding(16).frame(width: 340)
            }
    }
}

#Preview("Appearance · Light") {
    AppearancePane(sidebarOpen: .constant(true), rightSidebarOpen: .constant(true))
        .padding(32).frame(width: 820).preferredColorScheme(.light)
}

#Preview("Terminal · Dark") {
    ScrollView { SmthzTerminalSettingsControls().padding(32) }
        .frame(width: 820, height: 760).preferredColorScheme(.dark)
}

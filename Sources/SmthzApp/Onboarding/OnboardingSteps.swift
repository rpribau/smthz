import AppKit
import SwiftUI
import UserNotifications

struct SmthzOnboardingLanguageStep: View {
    private var systemLanguage: String {
        let identifier = Locale.preferredLanguages.first ?? "en"
        return Locale(identifier: "en").localizedString(forIdentifier: identifier) ?? identifier
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Display language").font(SmthzFont.ui(size: 24, weight: .semibold))
            Text("System language: \(systemLanguage)").foregroundStyle(SmthzTheme.mutedForeground)
            HStack {
                Text("English")
                Spacer()
                SmthzIcon.image("check").resizable().scaledToFit().frame(width: 16, height: 16)
            }
            .padding(14).background(SmthzTheme.secondary, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("English, selected")
            Button("Other language…") {}.buttonStyle(SmthzButtonStyle(.outline)).disabled(true)
                .help("smthz is currently available in English only")
        }
    }
}

// VISUAL-ONLY: stub data until M5 agent discovery, launch and provider preferences.
// No agent is presented as detected, selected or installed.
struct SmthzOnboardingAgentStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pick your default agent").font(SmthzFont.ui(size: 24, weight: .semibold))
            Text("Detected on your system").font(SmthzFont.ui(size: 14, weight: .medium))
            Text("Agent detection is not available yet.").foregroundStyle(SmthzTheme.mutedForeground)
            Text("Popular agents").font(SmthzFont.ui(size: 14, weight: .medium))
            HStack(spacing: 10) {
                ForEach(["Claude Code", "Codex", "Gemini CLI"], id: \.self) { name in
                    Button(name) {}.buttonStyle(SmthzButtonStyle(.outline)).disabled(true)
                        .help("Not available yet")
                }
            }
            Toggle("Yolo mode", isOn: .constant(false)).disabled(true).help("Not available yet")
        }
    }
}

struct SmthzOnboardingAppearanceStep: View {
    @Binding var theme: String
    private let choices = [("system", "System", "Match OS"), ("dark", "Dark", "Easy on the eyes"),
                           ("light", "Light", "Bright & crisp")]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Make it feel like home").font(SmthzFont.ui(size: 24, weight: .semibold))
            HStack(spacing: 10) {
                ForEach(choices, id: \.0) { mode, title, subtitle in
                    Button {
                        theme = mode
                        TerminalSettingsModel.applyAppTheme(mode)
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(mode == "dark" ? Color(white: 0.04) : mode == "light" ? .white : .gray)
                                .overlay(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 5).fill(.gray.opacity(0.3)).frame(width: 26)
                                }
                                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(SmthzTheme.border))
                                .frame(height: 58).accessibilityHidden(true)
                            Text(title).font(SmthzFont.ui(size: 14, weight: .medium))
                            Text(subtitle).font(SmthzFont.ui(size: 12)).foregroundStyle(SmthzTheme.mutedForeground)
                        }
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(SmthzTheme.card, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(theme == mode ? SmthzTheme.ring : SmthzTheme.border,
                                          lineWidth: theme == mode ? 2 : 1))
                    }
                    .buttonStyle(.plain).accessibilityAddTraits(theme == mode ? .isSelected : [])
                }
            }
            Text("You can change your theme and terminal appearance in Settings.")
                .foregroundStyle(SmthzTheme.mutedForeground)
        }
    }
}

/// Requests the native permission only after an explicit click. Does not install
/// a delegate or deliver sample notifications; those belong to the host integration.
struct SmthzOnboardingNotificationsStep: View {
    @State private var status = ""
    @State private var requesting = false
    @State private var authorized = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set up notifications").font(SmthzFont.ui(size: 24, weight: .semibold))
            Text("Allow notifications for smthz").font(SmthzFont.ui(size: 14, weight: .medium))
            Text("Stay informed when work needs your attention.").foregroundStyle(SmthzTheme.mutedForeground)
            Button(requesting ? "Requesting permission…" : authorized ? "Notifications allowed" : "Allow notifications for smthz") {
                Task { await requestPermission() }
            }
            .buttonStyle(SmthzButtonStyle(.outline)).disabled(requesting || authorized)
            Button("Open System Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }.buttonStyle(SmthzButtonStyle(.ghost))
            if !status.isEmpty {
                Text(status).font(SmthzFont.ui(size: 12)).foregroundStyle(SmthzTheme.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await refreshStatus() }
    }

    @MainActor private func refreshStatus() async {
        // UNUserNotificationCenter requires a bundled application identity.
        guard Bundle.main.bundleIdentifier != nil else {
            status = "Open the packaged smthz app to enable notifications."
            return
        }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        if authorized { status = "Notifications are allowed." }
        else if settings.authorizationStatus == .denied { status = "Notifications are off. You can enable them in System Settings." }
    }

    @MainActor private func requestPermission() async {
        guard Bundle.main.bundleIdentifier != nil else {
            status = "Open the packaged smthz app to enable notifications."
            return
        }
        requesting = true
        defer { requesting = false }
        do {
            authorized = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            status = authorized ? "Notifications are allowed." : "Notifications are off. You can enable them in System Settings."
        } catch {
            status = "Couldn't request notification permission: \(error.localizedDescription)"
        }
    }
}

// VISUAL-ONLY: stub data until GitHub/Linear task providers and account integration.
// Controls are disabled rather than claiming a CLI or account has been detected.
struct SmthzOnboardingIntegrationsStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set up GitHub tasks").font(SmthzFont.ui(size: 24, weight: .semibold))
            Text("GitHub CLI").font(SmthzFont.ui(size: 14, weight: .medium))
            HStack(spacing: 8) {
                ForEach(["Install gh", "Sign in", "Re-check"], id: \.self) { title in
                    Button(title) {}.buttonStyle(SmthzButtonStyle(.outline)).disabled(true)
                        .help("Not available yet")
                }
            }
            Text("Linear").font(SmthzFont.ui(size: 14, weight: .medium))
            Button("Connect Linear") {}.buttonStyle(SmthzButtonStyle(.outline)).disabled(true)
                .help("Not available yet")
            Text("Task integrations are not available yet.").foregroundStyle(SmthzTheme.mutedForeground)
        }
    }
}

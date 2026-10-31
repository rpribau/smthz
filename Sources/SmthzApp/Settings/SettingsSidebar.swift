import SmthzCore
import SwiftUI

/// One settings page (UI-DETAIL §11.1). `id` is stable and used for routing.
struct SettingsPage: Identifiable, Hashable {
    let id: String
    let title: String
    let icon: SmthzIcon.Name
    var badge: SettingsBadge?
    let description: String
    /// Hidden by default (Linear, Computer Use, Voice, smthz Account, Mobile, Dev Tools).
    var conditional = false
}

struct SettingsGroup: Identifiable {
    let title: String
    let pages: [SettingsPage]
    var id: String { title }

    static let all: [SettingsGroup] = [
        .init(title: "AI Capabilities", pages: [
            .init(id: "agents", title: "Agents", icon: "bot", badge: .optional,
                  description: "Manage AI agents, set a default, and customize commands."),
            .init(id: "accounts", title: "AI Provider Accounts", icon: "user-cog", badge: .optional,
                  description: "Optional account switching and usage setup for Claude, Codex, Gemini, OpenCode Go, MiniMax, and Grok."),
            .init(id: "orchestration", title: "Orchestration", icon: "network",
                  description: "Coordinate multiple coding agents through smthz."),
            .init(id: "linear", title: "Linear", icon: "blocks",
                  description: "How Linear works in smthz, setup checklist, agent skill, and example prompts.",
                  conditional: true),
            .init(id: "computer-use", title: "Computer Use", icon: "mouse-pointer-click",
                  description: "Enable agents to control any app on your computer.", conditional: true),
            .init(id: "voice", title: "Voice", icon: "mic",
                  description: "Local speech-to-text dictation with on-device models.", conditional: true)]),
        .init(title: "Set Up", pages: [
            .init(id: "smthz-account", title: "smthz Account", icon: "circle-user-round",
                  description: "Share work instantly and reach your desktop from smthz Mobile wherever you are.",
                  conditional: true),
            .init(id: "onboarding", title: "Onboarding checklist", icon: "circle-check",
                  description: "Finish the onboarding checklist for core smthz workflows."),
            .init(id: "general", title: "General", icon: "sliders-horizontal",
                  description: "Workspace defaults, app setup, and maintenance."),
            .init(id: "integrations", title: "Integrations", icon: "blocks",
                  description: "Connect GitHub, GitLab, Linear, and source-hosting services."),
            .init(id: "mobile", title: "Mobile", icon: "smartphone",
                  description: "Control terminals and agents from your phone.", conditional: true)]),
        .init(title: "Workflows", pages: [
            .init(id: "automations", title: "Automations", icon: "calendar-clock", badge: .beta,
                  description: "Schedule agent work and choose whether Automations appears in the sidebar."),
            .init(id: "artifacts", title: "Artifacts", icon: "files", badge: .beta,
                  description: "Share HTML and Markdown files with your team and manage their public links."),
            .init(id: "share-skills", title: "Share Skills", icon: "book-open", badge: .beta,
                  description: "Share your skills with an unlisted link. Anyone who has it can install them."),
            .init(id: "session-search", title: "Agent Session Search", icon: "history",
                  description: "Search everything your agents have said and done, on this computer and on any paired smthz server."),
            .init(id: "git", title: "Git & Source Control", icon: "git-branch",
                  description: "Branch naming, base refs, and Git AI Author."),
            .init(id: "task-sources", title: "Task Sources", icon: "list-checks",
                  description: "Connect providers, install the Linear skill, and choose what appears in Tasks."),
            .init(id: "terminal", title: "Terminal", icon: "square-terminal",
                  description: "Shells, renderer, sessions, and terminal behavior."),
            .init(id: "quick-commands", title: "Quick Commands", icon: "play",
                  description: "Saved terminal commands, scoped globally or per project."),
            .init(id: "browser", title: "Browser", icon: "globe",
                  description: "Home page, link routing, and session cookies."),
            .init(id: "emulator", title: "Mobile Emulator", icon: "tablet-smartphone",
                  description: "Configure mobile emulator support for smthz and coding agents."),
            .init(id: "floating-workspace", title: "Floating Workspace", icon: "panels-top-left",
                  description: "Configure the floating workspace panel.")]),
        .init(title: "Interface", pages: [
            .init(id: "appearance", title: "Appearance", icon: "palette",
                  description: "Theme, zoom, app and terminal appearance, sidebars, and status bar."),
            .init(id: "chat", title: "Chat", icon: "message-square",
                  description: "Choose how chats look and behave."),
            .init(id: "input", title: "Input & Editing", icon: "text-cursor-input",
                  description: "Selection and editing behavior."),
            .init(id: "notifications", title: "Notifications", icon: "bell",
                  description: "Native desktop notifications for agent and terminal events."),
            .init(id: "shortcuts", title: "Shortcuts", icon: "keyboard",
                  description: "Keyboard shortcuts for common actions."),
            .init(id: "stats", title: "Stats & Usage", icon: "chart-no-axes-column",
                  description: "smthz stats plus Claude, Codex, OpenCode, Muse token analytics and Grok subscription usage.")]),
        .init(title: "Remote Hosts", pages: [
            .init(id: "ssh-hosts", title: "SSH Hosts", icon: "cable",
                  description: "Use existing machines over SSH for files, terminals, Git, and workspaces."),
            .init(id: "servers", title: "Remote smthz Servers", icon: "server",
                  description: "Pair with other smthz servers and use their terminals, files, and workspaces.")]),
        .init(title: "Privacy & Security", pages: [
            .init(id: "permissions", title: "macOS Permissions", icon: "shield-check",
                  description: "macOS privacy access for terminal-launched developer tools."),
            .init(id: "privacy", title: "Privacy & Telemetry", icon: "lock",
                  description: "Anonymous usage data and telemetry controls.")]),
        .init(title: "Advanced", pages: [
            .init(id: "advanced", title: "Advanced", icon: "wrench",
                  description: "Low-level compatibility settings for troubleshooting."),
            .init(id: "dev-tools", title: "Dev Tools", icon: "bug", badge: .dev,
                  description: "Dev-only tools for exercising UI states.", conditional: true)]),
        .init(title: "Experimental", pages: [
            .init(id: "experimental", title: "Experimental", icon: "flask-conical",
                  description: "New features that are still taking shape. Give them a try."),
            .init(id: "plugins", title: "Plugins", icon: "blocks",
                  description: "Install and manage experimental smthz plugins.")])
    ]

    static func page(id: String) -> SettingsPage? {
        all.lazy.flatMap(\.pages).first { $0.id == id }
    }

    /// Groups visible for the given search text and conditional-page visibility.
    static func visible(search: String, showConditional: Set<String> = []) -> [SettingsGroup] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return all.compactMap { group in
            let pages = group.pages.filter { page in
                guard !page.conditional || showConditional.contains(page.id) else { return false }
                guard !query.isEmpty else { return true }
                return page.title.localizedCaseInsensitiveContains(query)
                    || page.description.localizedCaseInsensitiveContains(query)
                    || (page.id == "shortcuts" && KeybindingRegistry.definitions.contains {
                        $0.title.localizedCaseInsensitiveContains(query)
                    })
            }
            return pages.isEmpty ? nil : SettingsGroup(title: group.title, pages: pages)
        }
    }
}

/// A project row in the trailing "Projects" group. Per-project pages arrive with the M4 project model.
struct SettingsProjectItem: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    var isRemote = false
}

struct SettingsSidebar: View {
    /// Page id, or `project:<id>` for a project page.
    @Binding var selection: String
    @Binding var search: String
    var projects: [SettingsProjectItem] = []
    /// Conditional pages that should currently be listed (empty by default).
    var shownConditionalPages: Set<String> = []
    let onBack: () -> Void
    @FocusState private var searchFocused: Bool

    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var groups: [SettingsGroup] { SettingsGroup.visible(search: search, showConditional: shownConditionalPages) }
    private var matchingProjects: [SettingsProjectItem] {
        query.isEmpty ? projects : projects.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onBack) {
                HStack(spacing: 8) {
                    SmthzIcon.view(.arrowLeft)
                    Text("Back to app")
                    Spacer()
                }
                .font(SmthzFont.ui(size: 13))
                .foregroundStyle(SmthzTheme.mutedForeground)
                .frame(height: 32)
            }
            .buttonStyle(SmthzButtonStyle(.ghost))
            .accessibilityLabel("Back to app")
            .padding(12)
            .overlay(alignment: .bottom) { SmthzTheme.worktreeSidebarBorder.frame(height: 1) }
            HStack(spacing: 8) {
                SmthzIcon.view(.search).foregroundStyle(SmthzTheme.mutedForeground)
                TextField("Search settings", text: $search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .accessibilityLabel("Search settings")
                if search.isEmpty { KeyCapView.combo(["⌘", "F"]) }
            }
            .font(SmthzFont.ui(size: 13))
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(SmthzTheme.background.opacity(0.6), in: RoundedRectangle(cornerRadius: SmthzMetrics.radiusMD))
            .overlay { RoundedRectangle(cornerRadius: SmthzMetrics.radiusMD).strokeBorder(SmthzTheme.input, lineWidth: 1) }
            .padding(12)
            .background {
                Button("Search settings") { searchFocused = true }
                    .keyboardShortcut("f", modifiers: .command).hidden()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            groupTitle(group.title)
                            ForEach(group.pages) { page in
                                SettingsNavigationRow(title: page.title, icon: page.icon,
                                                      selected: selection == page.id) { selection = page.id }
                            }
                        }
                    }
                    projectsGroup
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
        }
        .frame(width: SmthzMetrics.leftSidebarWidth)
        .frame(maxHeight: .infinity)
        .background(SmthzTheme.worktreeSidebar)
        .foregroundStyle(SmthzTheme.worktreeSidebarForeground)
        .overlay(alignment: .trailing) { SmthzTheme.worktreeSidebarBorder.frame(width: 1) }
    }

    @ViewBuilder private var projectsGroup: some View {
        VStack(alignment: .leading, spacing: 4) {
            groupTitle("Projects")
            if projects.isEmpty {
                emptyNote("No projects added yet.")
            } else if matchingProjects.isEmpty {
                emptyNote("No matching project settings.")
            } else {
                ForEach(matchingProjects) { project in
                    SettingsNavigationRow(title: project.name, icon: "folder",
                                          selected: selection == "project:\(project.id)",
                                          trailingIcon: project.isRemote ? "server" : nil) {
                        selection = "project:\(project.id)"
                    }
                }
            }
        }
    }

    private func groupTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(SmthzFont.ui(size: 11, weight: .medium))
            .tracking(11 * 0.18)
            .foregroundStyle(SmthzTheme.mutedForeground)
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text).font(SmthzFont.ui(size: 13)).foregroundStyle(SmthzTheme.mutedForeground)
            .padding(.horizontal, 12).padding(.vertical, 6)
    }
}

private struct SettingsNavigationRow: View {
    let title: String
    let icon: SmthzIcon.Name
    let selected: Bool
    var trailingIcon: SmthzIcon.Name?
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                SmthzIcon.view(icon)
                Text(title).font(SmthzFont.ui(size: 13, weight: selected ? .medium : .regular)).lineLimit(1)
                Spacer(minLength: 0)
                if let trailingIcon { SmthzIcon.view(trailingIcon, size: 12) }
            }
            .foregroundStyle(SmthzTheme.worktreeSidebarForeground.opacity(selected ? 1 : 0.6))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .background(selected ? SmthzTheme.worktreeSidebarAccent : hovered ? SmthzTheme.accent.opacity(0.6) : .clear,
                        in: RoundedRectangle(cornerRadius: SmthzMetrics.radiusLG))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: SmthzMetrics.radiusLG).strokeBorder(SmthzTheme.ring.opacity(0.25), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

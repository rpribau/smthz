import SwiftUI

// Live section is real (AG4, agent.status.list). VISUAL-ONLY: session history below stays stub data until the agents history backend.
struct AgentsPanel: View {
    struct Session: Identifiable {
        let id: String
        let title: String
        let agent: String
        let folder: String
        let time: String
    }

    var sessions: [Session] = []
    var isScanning = false
    var onRefresh: (() -> Void)?
    var onResume: ((Session) -> Void)?
    var onSessionAction: ((String, Session) -> Void)?
    @State private var query = ""
    @State private var scope = "Workspace"
    @State private var groupBy = "Folder"
    @State private var hideEmpty = true
    @State private var historyDepth = "Recommended"
    @State private var selectedAgents: Set<String>?
    @State private var expanded: Set<String> = []

    private var agents: [String] { Array(Set(sessions.map(\.agent))).sorted() }
    private var filtered: [Session] {
        sessions.filter {
            (selectedAgents?.contains($0.agent) ?? true) &&
            (query.isEmpty || "\($0.title) \($0.agent) \($0.folder)".localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Agents").font(SmthzFont.ui(size: 13, weight: .semibold))
                        Text("Resume past sessions").font(SmthzFont.ui(size: 11))
                            .foregroundStyle(SmthzTheme.mutedForeground)
                    }
                    Spacer(minLength: 0)
                    PanelIconButton(icon: "refresh-cw", label: "Refresh Session History", enabled: onRefresh != nil) { onRefresh?() }
                }
                PanelSearchField(icon: .search, prompt: "Search sessions", text: $query, clearLabel: "Clear search")
                HStack(spacing: 4) {
                    ForEach(["Workspace", "Project", "All"], id: \.self) { value in
                        Button { scope = value } label: {
                            Text(value).font(SmthzFont.ui(size: 12, weight: .medium))
                                .frame(maxWidth: .infinity).frame(height: 24)
                                .background(scope == value ? SmthzTheme.background : .clear, in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain).accessibilityAddTraits(scope == value ? .isSelected : [])
                    }
                }
                .padding(3).background(SmthzTheme.muted, in: RoundedRectangle(cornerRadius: 10))
                HStack(spacing: 4) {
                    Menu {
                        Button("Local host") {}
                    } label: {
                        HStack(spacing: 4) {
                            SmthzIcon.view(.server, size: 12)
                            Text("Local host").font(SmthzFont.ui(size: 12))
                            SmthzIcon.view(.chevronDown, size: 12)
                        }
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                    .disabled(true).help("Not available yet")
                    Spacer(minLength: 0)
                    viewOptions
                }
            }
            .padding(8)
            liveSection
            HStack {
                Text(query.isEmpty ? "\(filtered.count) sessions" : "\(filtered.count) of \(sessions.count) sessions")
                Spacer(minLength: 0)
                Menu {
                    Picker("History depth", selection: $historyDepth) {
                        ForEach(["Recommended", "Unlimited", "May be slower", "Slowest"], id: \.self) { Text($0).tag($0) }
                    }
                } label: {
                    HStack(spacing: 3) { Text(historyDepth); SmthzIcon.view(.chevronDown, size: 10) }
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help("History depth")
            }
            .font(SmthzFont.ui(size: 11)).foregroundStyle(SmthzTheme.mutedForeground)
            .padding(.horizontal, 10).frame(height: 28)
            .overlay(alignment: .bottom) { SmthzTheme.border.frame(height: 1) }
            if isScanning {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Scanning sessions").font(SmthzFont.ui(size: 12))
                }
                .foregroundStyle(SmthzTheme.mutedForeground).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                PanelEmptyState(icon: .history, title: query.isEmpty ? "No agent sessions" : "No sessions found", detail: "Resume past sessions")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(Set(filtered.map { groupBy == "Folder" ? $0.folder : $0.agent })).sorted(), id: \.self) { group in
                            Text(group).font(SmthzFont.ui(size: 11, weight: .medium))
                                .foregroundStyle(SmthzTheme.mutedForeground).padding(.horizontal, 8).padding(.top, 8)
                            ForEach(filtered.filter { (groupBy == "Folder" ? $0.folder : $0.agent) == group }) { session in
                                sessionRow(session)
                            }
                        }
                    }.padding(6)
                }
            }
        }
        .foregroundStyle(SmthzTheme.foreground).background(SmthzTheme.sidebar)
    }

    @ViewBuilder private var liveSection: some View {
        let live = AgentStatusModel.shared
        if !live.agentSessionIDs.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Live").font(SmthzFont.ui(size: 11, weight: .medium))
                    .foregroundStyle(SmthzTheme.mutedForeground).padding(.horizontal, 8)
                ForEach(live.agentSessionIDs, id: \.self) { id in liveRow(id, live) }
            }
            .padding(.horizontal, 6).padding(.bottom, 6)
        }
    }

    private func liveRow(_ id: String, _ live: AgentStatusModel) -> some View {
        let row = live.status(id)
        // Not a Button: the nested restart chip must receive its own clicks.
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                AgentStateIcon(state: live.exited(id) ? "idle" : row?.state ?? "idle")
                Text(live.agentName(id)).font(SmthzFont.ui(size: 12)).lineLimit(1)
                Spacer(minLength: 0)
                if live.exited(id) { AgentRestartChip(sessionID: id) }
                else if let row { Text(AgentStatusBadge.label(row)).font(SmthzFont.ui(size: 10)).foregroundStyle(SmthzTheme.mutedForeground) }
            }
            if let tool = row?.toolName {
                Text("Tool: \(tool)" + (row?.toolInputPreview.map { " · \($0)" } ?? ""))
                    .font(SmthzFont.ui(size: 11)).foregroundStyle(SmthzTheme.mutedForeground).lineLimit(1)
            }
            if let prompt = row?.prompt {
                Text(prompt).font(SmthzFont.ui(size: 11)).foregroundStyle(SmthzTheme.mutedForeground).lineLimit(2)
            }
        }
        .padding(6).frame(maxWidth: .infinity, alignment: .leading)
        .background(SmthzTheme.card, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle()).onTapGesture { live.pendingSelection = id }
        .accessibilityElement(children: .contain).accessibilityLabel("Agent \(live.agentName(id))")
        .accessibilityAction(named: "Show tab") { live.pendingSelection = id }
    }

    private var viewOptions: some View {
        Menu {
            Section("Agents") {
                Button("Select all") { selectedAgents = Set(agents) }
                Button("Clear") { selectedAgents = [] }
                ForEach(agents, id: \.self) { agent in
                    Toggle(agent, isOn: Binding(get: { selectedAgents?.contains(agent) ?? true }, set: {
                        var selection = selectedAgents ?? Set(agents)
                        if $0 { selection.insert(agent) } else { selection.remove(agent) }
                        selectedAgents = selection
                    }))
                }
            }
            Picker("Group by", selection: $groupBy) { Text("Folder").tag("Folder"); Text("Agent").tag("Agent") }
            Toggle("Hide empty sessions", isOn: $hideEmpty)
            Button("Reset view") { selectedAgents = nil; groupBy = "Folder"; hideEmpty = true; scope = "Workspace" }
        } label: {
            SmthzIcon.view("list-filter", size: 14).frame(width: 24, height: 24)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("View options").accessibilityLabel("View options")
    }

    private func sessionRow(_ session: Session) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                SmthzIcon.view(.bot, size: 14).foregroundStyle(SmthzTheme.mutedForeground)
                Text(session.title).font(SmthzFont.ui(size: 12)).lineLimit(1)
                Spacer(minLength: 0)
                Text(session.time).font(SmthzFont.ui(size: 10)).foregroundStyle(SmthzTheme.mutedForeground)
                PanelIconButton(icon: .play, label: "Continue in CLI", enabled: onResume != nil) { onResume?(session) }
                PanelIconButton(icon: .chevronDown, label: expanded.contains(session.id) ? "Hide Details" : "Show Details") {
                    if !expanded.insert(session.id).inserted { expanded.remove(session.id) }
                }
            }
            if expanded.contains(session.id) {
                Text("\(session.agent) · \(session.folder)").font(SmthzFont.ui(size: 11))
                    .foregroundStyle(SmthzTheme.mutedForeground).textSelection(.enabled)
            }
        }
        .padding(6).background(SmthzTheme.card, in: RoundedRectangle(cornerRadius: 6))
        .contextMenu {
            Button("Continue in CLI") { onResume?(session) }.disabled(onResume == nil)
            ForEach(["Jump to Original Pane", "Jump to Folder/Worktree", "Copy Resume Command", "Hand Off to Another Agent", "Open Log", "Reveal Log", "Open Working Directory", "Copy Session ID", "Copy Log Path", "Delete"], id: \.self) { action in
                Button(action) { onSessionAction?(action, session) }.disabled(onSessionAction == nil)
            }
        }
    }
}

#if DEBUG
#Preview("Agents · Empty") { AgentsPanel().frame(width: 320, height: 560) }
#Preview("Agents · Scanning") { AgentsPanel(isScanning: true).frame(width: 320, height: 560) }
#Preview("Agents · Indexed history") {
    AgentsPanel(sessions: [
        .init(id: "preview-1", title: "Review terminal layout", agent: "Codex", folder: "smthz", time: "2m"),
        .init(id: "preview-2", title: "Investigate checks", agent: "Claude", folder: "smthz", time: "1h")
    ]).frame(width: 320, height: 560)
}
#endif

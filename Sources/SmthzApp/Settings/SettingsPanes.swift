import SmthzCore
import SwiftUI

/// WP-SETTINGS-2: panes whose backend already exists (hostSettings RPC, quick command store,
/// agent.list, repo.show/update) or that only store local preferences.

/// One RPC off the main actor; failures read as "code: detail".
private func settingsCall(_ socket: String, _ method: String,
                          _ params: [String: HostJSON] = [:]) async throws -> [String: HostJSON] {
    try await Task.detached {
        let client = try HostClient(socketPath: socket)
        defer { client.disconnect() }
        return try client.json(method, params, timeoutMilliseconds: 30_000)
    }.value
}

private func settingsError(_ error: any Error) -> String {
    if case HostClientError.detailedHostError(let code, let detail) = error { return detail.map { "\(code): \($0)" } ?? code }
    if case HostClientError.hostNotRunning = error { return "Host not running." }
    return String(describing: error)
}

/// `hostSettings.get/set` values shared by the General and Git panes.
@MainActor @Observable
final class HostSettingsStore {
    private(set) var values: [String: HostJSON] = [:]
    private(set) var error: String?
    let socketPath: String
    init(socketPath: String) { self.socketPath = socketPath }

    func load() async {
        do { values = try await settingsCall(socketPath, "hostSettings.get")["values"]?.object ?? [:]; error = nil }
        catch { self.error = settingsError(error) }
    }

    func set(_ key: String, _ value: HostJSON) {
        Task {
            do {
                values = try await settingsCall(socketPath, "hostSettings.set", ["values": .object([key: value])])["values"]?.object ?? values
                error = nil
            } catch { self.error = settingsError(error) }
        }
    }

    func bool(_ key: String) -> Binding<Bool> {
        Binding(get: { self.values[key] == .bool(true) }, set: { self.set(key, .bool($0)) })
    }
}

private struct HostSettingsErrorText: View {
    let error: String?
    var body: some View {
        if let error {
            Text(error).font(SmthzFont.ui(size: 12)).foregroundStyle(SmthzTheme.destructive)
        }
    }
}

/// Text field committed on Return or focus loss, so the host only sees finished values.
private struct SettingsCommitField: View {
    let placeholder: String
    let value: String
    let commit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $draft)
            .textFieldStyle(.roundedBorder).font(SmthzFont.mono(size: 12)).frame(width: 280)
            .focused($focused)
            .onSubmit { commit(draft) }
            .onChange(of: focused) { _, now in if !now, draft != value { commit(draft) } }
            .onAppear { draft = value }
            .onChange(of: value) { _, new in draft = new }
            .accessibilityLabel(placeholder)
    }
}

/// Inverts a `confirmations.skip*` key into an "ask before" switch.
private func askBinding(_ storage: Binding<Bool>) -> Binding<Bool> {
    Binding(get: { !storage.wrappedValue }, set: { storage.wrappedValue = !$0 })
}

// MARK: General

struct GeneralSettingsPane: View {
    @State var store: HostSettingsStore
    @AppStorage(SmthzDeleteWorkspaceDialog.preferenceKey) private var skipDeleteWorkspace = false
    @AppStorage(SmthzCloseConfirmationCoordinator.pinnedPreferenceKey) private var skipPinnedTab = false
    @AppStorage(SmthzCloseConfirmationCoordinator.runningPreferenceKey) private var skipRunningTerminal = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsGroupTitle(title: "Workspace")
            SettingsRow("Workspace Directory", detail: "Root directory where workspace folders are created.") {
                SettingsCommitField(placeholder: "Workspace directory",
                                    value: store.values["workspaceDir"]?.string ?? "") {
                    store.set("workspaceDir", .string($0))
                }
            }
            SettingsRow("Nest Workspaces", detail: "Create workspaces inside a repo-named subfolder.") {
                SettingsToggle(title: "Nest Workspaces", isOn: store.bool("nestWorkspaces"))
            }
            HostSettingsErrorText(error: store.error)
            SettingsRow("Ask Before Deleting Workspaces", detail: "Show a confirmation dialog before deleting a workspace.") {
                SettingsToggle(title: "Ask Before Deleting Workspaces", isOn: askBinding($skipDeleteWorkspace))
            }
            SettingsRow("Confirm before closing pinned tabs", detail: "Show a confirmation dialog before a pinned tab is closed.") {
                SettingsToggle(title: "Confirm before closing pinned tabs", isOn: askBinding($skipPinnedTab))
            }
            SettingsRow("Confirm before closing running terminals",
                        detail: "Ask before stopping a running agent or command when closing a terminal.") {
                SettingsToggle(title: "Confirm before closing running terminals", isOn: askBinding($skipRunningTerminal))
            }
            // VISUAL-ONLY: no backend for Open In Apps, CLI registration, agent skill install or updates yet.
            SettingsGroupTitle(title: "App")
            SettingsRow("smthz CLI", detail: "Register or remove the smthz CLI command.") {
                Button("Register") {}.buttonStyle(SmthzButtonStyle(.outline, size: .small)).disabled(true)
            }
            SettingsRow("Check for Updates", detail: "Check for app updates and install a newer smthz version.") {
                Button("Check Now") {}.buttonStyle(SmthzButtonStyle(.outline, size: .small)).disabled(true)
            }
        }
        .task { await store.load() }
    }
}

// MARK: Git

struct GitSettingsPane: View {
    @State var store: HostSettingsStore

    var body: some View {
        let mode = Binding(get: { store.values["branchPrefix"]?.string ?? "git-username" },
                           set: { store.set("branchPrefix", .string($0)) })
        VStack(alignment: .leading, spacing: 20) {
            SettingsRow("Branch Prefix", detail: "Prefix added to branch names when creating worktrees.") {
                SettingsSegmented(options: [("Git Username", "git-username"), ("Custom", "custom"), ("None", "none")],
                                  selection: mode, accessibilityLabel: "Branch Prefix")
            }
            if mode.wrappedValue == "custom" {
                SettingsRow("Custom Prefix") {
                    SettingsCommitField(placeholder: "Custom prefix",
                                        value: store.values["branchPrefixCustom"]?.string ?? "") {
                        store.set("branchPrefixCustom", .string($0))
                    }
                }
            }
            SettingsRow("Keep Local Main Up to Date",
                        detail: "When you create a workspace, smthz refreshes the remote base and safely fast-forwards your matching local branch, such as main or master.") {
                SettingsToggle(title: "Keep Local Main Up to Date", isOn: store.bool("refreshLocalBaseRefOnCreate"))
            }
            // shortcut: Jira key casing, Source Control group order and default compare base have no backend; add with those features.
            HostSettingsErrorText(error: store.error)
        }
        .task { await store.load() }
    }
}

// MARK: Quick Commands

struct QuickCommandsSettingsPane: View {
    var store: SmthzQuickCommandStore = .shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(store.commands.count) saved").font(SmthzFont.ui(size: 13)).foregroundStyle(SmthzTheme.mutedForeground)
                Spacer()
                Button("Add Command") { store.editor = SmthzQuickCommand() }
                    .buttonStyle(SmthzButtonStyle(.outline, size: .small))
            }
            if store.commands.isEmpty {
                SettingsValueText("No quick commands yet. Add one to run it from any terminal.")
            }
            ForEach(store.commands) { command in
                SettingsRow(command.label, detail: "\(command.command)  ·  \(command.scope.rawValue)") {
                    HStack(spacing: 6) {
                        Button("Edit") { store.editor = command }.buttonStyle(SmthzButtonStyle(.outline, size: .small))
                        Button("Delete") { store.pendingDeletion = command }.buttonStyle(SmthzButtonStyle(.outline, size: .small))
                    }
                }
            }
        }
    }
}

// MARK: Agents

struct AgentsSettingsPane: View {
    let socketPath: String
    @AppStorage("agents.defaultAgent") private var defaultAgent = ""
    @State private var detected: [AgentID: DetectedAgent]?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsRow("Default Agent", detail: "Agent preselected when launching new work.") {
                Picker("Default Agent", selection: $defaultAgent) {
                    Text("None").tag("")
                    ForEach(AgentID.allCases, id: \.rawValue) { Text($0.displayName).tag($0.rawValue) }
                }.labelsHidden().frame(width: 220)
            }
            SettingsGroupTitle(title: "Detected Agents")
            if let error { Text(error).font(SmthzFont.ui(size: 12)).foregroundStyle(SmthzTheme.destructive) }
            if let detected {
                ForEach(AgentID.allCases.sorted { (detected[$0] != nil ? 0 : 1, $0.displayName) < (detected[$1] != nil ? 0 : 1, $1.displayName) },
                        id: \.rawValue) { id in
                    let agent = detected[id]
                    SettingsRow(id.displayName, detail: agent.map { [$0.executable, $0.version].compactMap { $0 }.joined(separator: "  ·  ") }) {
                        SettingsValueText(agent == nil ? "Not detected" : "Detected")
                    }
                }
            } else if error == nil {
                SettingsValueText("Detecting agents…")
            }
        }
        .task {
            do {
                let agents = try await Task.detached { [socketPath] in
                    let client = try HostClient(socketPath: socketPath)
                    defer { client.disconnect() }
                    return try client.listAgents()
                }.value
                detected = Dictionary(agents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            } catch { self.error = settingsError(error) }
        }
    }
}

// MARK: Privacy

struct PrivacySettingsPane: View {
    @AppStorage("privacy.shareUsageData") private var shareUsage = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsRow("Share Anonymous Usage Data", detail: "Help improve smthz by sending anonymous feature-usage events.") {
                SettingsToggle(title: "Share Anonymous Usage Data", isOn: $shareUsage)
            }
            SettingsValueText("smthz does not send telemetry yet; this preference is stored on this Mac only.")
        }
    }
}

// MARK: Notifications

struct NotificationsSettingsPane: View {
    @AppStorage("notifications.enabled") private var enabled = true
    @AppStorage("notifications.agentTaskComplete") private var agentComplete = true
    @AppStorage("notifications.terminalBell") private var bell = false
    @AppStorage("notifications.suppressWhenFocused") private var suppress = true

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsValueText("Preferences are saved; desktop notification delivery is not available yet.")
            SettingsRow("Enable Notifications", detail: "Master switch for smthz desktop notifications.") {
                SettingsToggle(title: "Enable Notifications", isOn: $enabled)
            }
            Group {
                SettingsRow("Agent Task Complete", detail: "Notify when a coding agent transitions from working to idle.") {
                    SettingsToggle(title: "Agent Task Complete", isOn: $agentComplete)
                }
                SettingsRow("Terminal Bell", detail: "Notify when a background terminal emits a bell character.") {
                    SettingsToggle(title: "Terminal Bell", isOn: $bell)
                }
                SettingsRow("Suppress While Focused", detail: "Avoid notifying when smthz is focused on the active worktree.") {
                    SettingsToggle(title: "Suppress While Focused", isOn: $suppress)
                }
                // VISUAL-ONLY: no delivery path yet.
                SettingsRow("Send Test Notification", detail: "Trigger a sample desktop notification using the native delivery path.") {
                    Button("Send Test") {}.buttonStyle(SmthzButtonStyle(.outline, size: .small)).disabled(true)
                }
            }
            .disabled(!enabled)
        }
    }
}

// MARK: Repository (Projects group)

/// Project page body: the existing repository settings sheet, inline. Cancel reverts by reloading.
struct RepositorySettingsPane: View {
    let repoID: String
    let socketPath: String
    @State private var lifecycle: WorktreeLifecycleModel?
    @State private var reload = 0

    var body: some View {
        Group {
            if let lifecycle {
                SmthzRepositorySettingsSheet(repoID: repoID, lifecycle: lifecycle, onDismiss: { reload += 1 })
                    .id("\(repoID)-\(reload)")
            }
        }
        .onAppear { if lifecycle == nil { lifecycle = WorktreeLifecycleModel(socketPath: socketPath) } }
    }
}

/// Registered repos for the Projects group when the caller passed none.
func settingsLoadProjects(socketPath: String) async -> [SettingsProjectItem] {
    let repos = (try? await settingsCall(socketPath, "repo.list"))?["repos"]
    guard case .array(let items) = repos ?? .null else { return [] }
    return items.compactMap(\.object).compactMap { repo in
        guard let id = repo["id"]?.string else { return nil }
        let name = repo["displayName"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            ?? repo["path"]?.string.map { ($0 as NSString).lastPathComponent } ?? id
        return SettingsProjectItem(id: id, name: name)
    }
}

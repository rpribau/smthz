import SmthzCore
import SwiftUI

typealias SourceControlEntry = HostGitStatus.Entry

/// Source Control state and actions. Every Git read and write goes through the host
/// (`git.*` RPC); only the work tree top level is discovered in-process from the active cwd.
@MainActor @Observable
final class SourceControlModel {
    enum State: Equatable { case idle, loading, notGit, loaded, failed(String) }
    struct Failure: Equatable { let title: String; let detail: String?; let code: String? }
    var state: State = .idle
    var status: HostGitStatus?
    var branches: [HostGitBranch] = []
    var stashes: [HostGitStash] = []
    var filter = ""
    var busy: String?
    var failure: Failure?
    private(set) var root: String?
    private let socketPath = HostController.socketPath

    func load(directory: URL) async {
        if status == nil { state = .loading }
        let resolved: String?
        do {
            resolved = try await GitService().repository(at: directory).flatMap { $0.isBare ? nil : $0.root.path }
        } catch {
            state = .failed(String(describing: error)); return
        }
        guard let resolved else { state = .notGit; status = nil; root = nil; return }
        if resolved != root { status = nil }
        root = resolved
        await refresh()
    }

    func refresh() async {
        guard let root else { return }
        let socket = socketPath
        do {
            let (status, branches, stashes) = try await Task.detached {
                let client = try HostClient(socketPath: socket)
                defer { client.disconnect() }
                return (try client.gitStatus(worktreePath: root), try client.gitBranches(worktreePath: root),
                        try client.gitStashList(worktreePath: root))
            }.value
            guard root == self.root else { return }
            self.status = status; self.branches = branches; self.stashes = stashes
            state = .loaded
        } catch HostClientError.hostNotRunning {
            state = .failed("Host not running")
        } catch {
            state = .failed(Self.describe(error).detail ?? Self.describe(error).code ?? "\(error)")
        }
    }

    /// Runs one host call off the main actor, shows its failure, then refreshes status.
    @discardableResult
    func perform(_ label: String, _ body: @escaping @Sendable (HostClient, String) throws -> Void) async -> Bool {
        guard let root, busy == nil else { return false }
        busy = label; failure = nil
        let socket = socketPath
        let result = await Task.detached { () -> Result<Void, any Error> in
            Result {
                let client = try HostClient(socketPath: socket)
                defer { client.disconnect() }
                try body(client, root)
            }
        }.value
        busy = nil
        if case .failure(let error) = result {
            let d = Self.describe(error)
            failure = Failure(title: "\(label) failed", detail: d.detail, code: d.code)
        }
        await refresh()
        if case .success = result { return true }
        return false
    }

    /// Push, pull, fetch and sync are host jobs; the call waits for the job off the main actor.
    func runJob(_ label: String, _ method: String, forceWithLease: Bool = false) async {
        await perform(label) { client, root in
            try client.waitForJob(id: try client.gitStartJob(method, worktreePath: root, forceWithLease: forceWithLease))
        }
    }

    private static func describe(_ error: any Error) -> (code: String?, detail: String?) {
        switch error {
        case HostClientError.detailedHostError(let code, let detail): (code, detail)
        case HostClientError.hostError(let code): (code, nil)
        case HostClientError.hostNotRunning: ("hostNotRunning", "Host not running")
        default: (nil, String(describing: error))
        }
    }

    private var visible: [SourceControlEntry] {
        guard let status else { return [] }
        return filter.isEmpty ? status.entries : status.entries.filter { $0.path.localizedCaseInsensitiveContains(filter) }
    }
    var staged: [SourceControlEntry] {
        visible.filter { ($0.kind == "ordinary" || $0.kind == "renamed") && $0.index != "." }
    }
    var changes: [SourceControlEntry] {
        visible.filter { ($0.kind == "ordinary" || $0.kind == "renamed") && $0.worktree != "." }
    }
    var untracked: [SourceControlEntry] { visible.filter { $0.kind == "untracked" } }
    var conflicts: [SourceControlEntry] { visible.filter { $0.kind == "unmerged" } }
    var unstagedCount: Int {
        (status?.entries ?? []).filter { $0.kind == "untracked" || $0.kind == "unmerged" || $0.worktree != "." }.count
    }
    var stagedCount: Int {
        (status?.entries ?? []).filter { ($0.kind == "ordinary" || $0.kind == "renamed") && $0.index != "." }.count
    }
    var primary: SourceControlPrimaryAction {
        SourceControlPrimaryAction.resolve(status, staged: stagedCount, unstaged: unstagedCount)
    }
}

struct SourceControlPanel: View {
    /// Workspace root (the active session's cwd); nil means no workspace.
    let rootURL: URL?
    @State private var model = SourceControlModel()
    @State private var message = ""
    @State private var viewAsTree = false
    @State private var refreshTick = 0
    @State private var discard: SmthzDiscardChangesDialog.Request?
    @State private var confirmPushedAmend = false
    @State private var newBranchName = ""
    @State private var creatingBranch = false

    var body: some View {
        Group {
            if rootURL == nil {
                PanelEmptyState(icon: .gitBranch, title: "Select a workspace to view changes", detail: nil)
            } else if model.state == .notGit {
                PanelEmptyState(icon: .gitBranch, title: "Source Control is only available for Git repositories", detail: nil)
            } else if case .failed(let reason) = model.state, model.status == nil {
                PanelEmptyState(icon: .alertTriangle, title: "Could not read Git status", detail: reason)
            } else {
                loadedBody
            }
        }
        .task(id: "\(rootURL?.path ?? "")#\(refreshTick)") {
            guard let rootURL else { return }
            await model.load(directory: rootURL)
            // Interim until fs.changes (WP-M4-FILES) pushes index/HEAD changes: poll status while visible.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                if Task.isCancelled { break }
                if model.busy == nil { await model.refresh() }
            }
        }
        .overlay {
            if let request = discard {
                ZStack {
                    Color.black.opacity(0.45).onTapGesture { discard = nil }
                    SmthzDiscardChangesDialog(request: request, onCancel: { discard = nil }) {
                        discard = nil
                        Task {
                            await model.perform(request.untracked ? "Delete" : "Discard") { client, root in
                                try client.gitDiscard(worktreePath: root, paths: request.paths, includeUntracked: request.untracked)
                            }
                        }
                    }
                    .padding(8)
                }
            }
        }
        .alert("Amend a pushed commit?", isPresented: $confirmPushedAmend) {
            Button("Cancel", role: .cancel) {}
            Button("Amend", role: .destructive) { commit(amend: true, confirmPushed: true) }
        } message: {
            Text("The last commit is already on the remote. Amending rewrites it, and the next push will need Force Push with Lease.")
        }
        .alert("Create Branch", isPresented: $creatingBranch) {
            TextField("Branch name", text: $newBranchName)
            Button("Cancel", role: .cancel) { newBranchName = "" }
            Button("Create") {
                let name = newBranchName; newBranchName = ""
                Task { await model.perform("Create branch") { try $0.gitCreateBranch(worktreePath: $1, name: name) } }
            }
        } message: {
            Text("The new branch starts at the current commit and is checked out.")
        }
    }

    private var loadedBody: some View {
        VStack(spacing: 0) {
            header
            if let status = model.status, status.operation != .none { operationBanner(status.operation) }
            if let failure = model.failure { failureBanner(failure) }
            PanelSearchField(icon: .search, prompt: "Filter files…", text: $model.filter, clearLabel: "Clear filter")
                .padding(.horizontal, 8).padding(.bottom, 6)
            SourceControlCommitBox(message: $message, action: model.primary, busy: model.busy != nil, onPrimary: primaryAction)
            if model.state == .loading && model.status == nil {
                Spacer()
            } else if model.status?.entries.isEmpty ?? true {
                Text("No changes on this branch")
                    .font(SmthzFont.ui(size: 12)).foregroundStyle(SmthzTheme.mutedForeground)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        section(.conflicts, model.conflicts)
                        section(.staged, model.staged)
                        section(.changes, model.changes)
                        section(.untracked, model.untracked)
                    }
                    .padding(.horizontal, 6)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            SmthzIcon.view(.gitBranch, size: 12).foregroundStyle(SmthzTheme.mutedForeground)
            Text(model.status?.branch ?? "No branch")
                .font(SmthzFont.ui(size: 12, weight: .medium)).lineLimit(1)
                .help("Current branch: \(model.status?.branch ?? "none")" + (model.status?.upstream.map { " → \($0)" } ?? ""))
            if let status = model.status, status.upstream != nil, status.ahead + status.behind > 0 {
                Text("↑\(status.ahead) ↓\(status.behind)")
                    .font(SmthzFont.ui(size: 11)).foregroundStyle(SmthzTheme.mutedForeground)
                    .help("\(status.ahead) ahead, \(status.behind) behind \(status.upstream ?? "")")
            }
            Spacer(minLength: 0)
            PanelIconButton(icon: viewAsTree ? "list-tree" : .list,
                            label: viewAsTree ? "View as list" : "View as tree") { viewAsTree.toggle() }
            // VISUAL-ONLY: stub data until a notes store exists
            PanelIconButton(icon: .messageSquare, label: "Notes", enabled: false) {}
            PanelIconButton(icon: "refresh-cw", label: "Refresh") { refreshTick += 1 }
            moreMenu
        }
        .foregroundStyle(SmthzTheme.foreground)
        .padding(.horizontal, 8).padding(.vertical, 6)
    }

    private var moreMenu: some View {
        let status = model.status
        let localBranches = model.branches.filter { !$0.isRemote && !$0.isCurrent }
        return Menu {
            Button("Commit") { commit(amend: false) }.disabled(model.stagedCount == 0 || message.isEmpty)
            Button("Commit (Amend)") { commit(amend: true) }.disabled(status?.head == nil || status?.head == "(initial)")
            Divider()
            Button("Push") { Task { await model.runJob("Push", "git.push") } }
            Button("Pull") { Task { await model.runJob("Pull", "git.pull") } }.disabled(status?.upstream == nil)
            Button("Fetch") { Task { await model.runJob("Fetch", "git.fetch") } }
            Button("Sync") { Task { await model.runJob("Sync", "git.sync") } }.disabled(status?.upstream == nil)
            // Shown only when local and remote history diverged (e.g. after an amend or rebase).
            if let status, status.ahead > 0, status.behind > 0 {
                Button("Force Push with Lease") { Task { await model.runJob("Force push", "git.push", forceWithLease: true) } }
            }
            Divider()
            Button("Stage All Changes") { Task { await model.perform("Stage") { try $0.gitStageAll(worktreePath: $1) } } }
            Button("Unstage All Changes") { Task { await model.perform("Unstage") { try $0.gitUnstageAll(worktreePath: $1) } } }
                .disabled(model.stagedCount == 0)
            Divider()
            Button("Stash Changes") { Task { await model.perform("Stash") { try $0.gitStash(worktreePath: $1) } } }
            Button("Stash Changes (Include Untracked)") {
                Task { await model.perform("Stash") { try $0.gitStash(worktreePath: $1, includeUntracked: true) } }
            }
            Button("Pop Latest Stash") { Task { await model.perform("Pop stash") { try $0.gitStashPop(worktreePath: $1) } } }
                .disabled(model.stashes.isEmpty)
            Divider()
            Button("Create Branch…") { creatingBranch = true }
            Menu("Switch Branch") {
                ForEach(localBranches, id: \.name) { branch in
                    Button(branch.name) {
                        Task { await model.perform("Switch branch") { try $0.gitSwitchBranch(worktreePath: $1, name: branch.name) } }
                    }
                }
            }
            .disabled(localBranches.isEmpty)
            Divider()
            // AI actions stay disabled until M5 (agents).
            Button("Generate Commit Message with AI") {}.disabled(true)
        } label: {
            SmthzIcon.view(.ellipsis, size: 14).foregroundStyle(SmthzTheme.mutedForeground).frame(width: 24, height: 24)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .disabled(model.busy != nil || model.status == nil)
        .help("More source control actions").accessibilityLabel("More source control actions")
    }

    private func operationBanner(_ operation: GitOperation) -> some View {
        let name = switch operation {
        case .merge: "Merge"
        case .rebase: "Rebase"
        case .cherryPick: "Cherry-pick"
        case .revert: "Revert"
        case .none: ""
        }
        return HStack(spacing: 6) {
            SmthzIcon.view(.gitMerge, size: 12)
            Text("\(name) in progress").font(SmthzFont.ui(size: 12, weight: .medium))
            Spacer(minLength: 0)
            if operation == .merge || operation == .rebase {
                Button("Abort") {
                    Task {
                        await model.perform("Abort \(name.lowercased())") { client, root in
                            if operation == .merge { try client.gitAbortMerge(worktreePath: root) }
                            else { try client.gitAbortRebase(worktreePath: root) }
                        }
                    }
                }
                .buttonStyle(SmthzButtonStyle(.outline, size: .xs))
            }
            Button("Continue") {
                Task { await model.perform("Continue \(name.lowercased())") { try $0.gitContinueOperation(worktreePath: $1) } }
            }
            .buttonStyle(SmthzButtonStyle(.primary, size: .xs))
            .disabled(!model.conflicts.isEmpty)
            .help(model.conflicts.isEmpty ? "Continue the \(name.lowercased())" : "Resolve and stage every conflict first")
        }
        .padding(8)
        .background(SmthzTheme.statusWarning.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 8).padding(.bottom, 6)
    }

    private func failureBanner(_ failure: SourceControlModel.Failure) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                SmthzIcon.view(.alertTriangle, size: 12).foregroundStyle(SmthzTheme.destructive)
                Text(failure.title).font(SmthzFont.ui(size: 12, weight: .medium))
                Spacer(minLength: 0)
                Button { model.failure = nil } label: { SmthzIcon.view(.x, size: 12) }
                    .buttonStyle(.plain).foregroundStyle(SmthzTheme.mutedForeground)
                    .help("Dismiss").accessibilityLabel("Dismiss error")
            }
            if let detail = failure.detail, !detail.isEmpty {
                ScrollView {
                    Text(detail).font(SmthzFont.mono(size: 11)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120).fixedSize(horizontal: false, vertical: true)
            }
            if failure.code == "pushRejected" {
                Text("The remote has commits you do not have. Pull first, or use Force Push with Lease if you rewrote history.")
                    .font(SmthzFont.ui(size: 11)).foregroundStyle(SmthzTheme.mutedForeground)
            }
        }
        .padding(8)
        .background(SmthzTheme.destructive.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 8).padding(.bottom, 6)
        .accessibilityElement(children: .contain)
    }

    private func primaryAction() {
        switch model.primary {
        case .stageAll: Task { await model.perform("Stage") { try $0.gitStageAll(worktreePath: $1) } }
        case .commit: commit(amend: false)
        case .publish, .push: Task { await model.runJob("Push", "git.push") }
        case .pull: Task { await model.runJob("Pull", "git.pull") }
        case .sync: Task { await model.runJob("Sync", "git.sync") }
        }
    }

    private func commit(amend: Bool, confirmPushed: Bool = false) {
        let text = message
        Task {
            let ok = await model.perform(amend ? "Amend" : "Commit") { client, root in
                try client.gitCommit(worktreePath: root, message: text, amend: amend, confirmPushedAmend: confirmPushed)
            }
            if ok { message = "" }
            else if model.failure?.code == "amendPushedCommit" { model.failure = nil; confirmPushedAmend = true }
        }
    }

    @ViewBuilder
    private func section(_ kind: SourceControlSection.Kind, _ entries: [SourceControlEntry]) -> some View {
        if !entries.isEmpty {
            SourceControlSection(kind: kind, entries: entries, enabled: model.busy == nil) { action, paths in
                handle(action, paths: paths, kind: kind)
            }
        }
    }

    private func handle(_ action: SourceControlSection.Action, paths: [String], kind: SourceControlSection.Kind) {
        switch action {
        case .stage: Task { await model.perform("Stage") { try $0.gitStage(worktreePath: $1, paths: paths) } }
        case .unstage: Task { await model.perform("Unstage") { try $0.gitUnstage(worktreePath: $1, paths: paths) } }
        case .discard: discard = .init(paths: paths, untracked: kind == .untracked)
        }
    }
}

private struct SourceControlSection: View {
    enum Kind { case conflicts, staged, changes, untracked }
    enum Action { case stage, unstage, discard }
    let kind: Kind
    let entries: [SourceControlEntry]
    let enabled: Bool
    let onAction: (Action, [String]) -> Void
    @State private var collapsed = false

    private var title: String {
        switch kind {
        case .conflicts: "Merge Conflicts"
        case .staged: "Staged Changes"
        case .changes: "Changes"
        case .untracked: "Untracked Files"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button { collapsed.toggle() } label: {
                    HStack(spacing: 4) {
                        SmthzIcon.view(.chevronRight, size: 12).rotationEffect(.degrees(collapsed ? 0 : 90))
                        Text(title).font(SmthzFont.ui(size: 11, weight: .semibold)).textCase(.uppercase)
                        Text("\(entries.count)").font(SmthzFont.ui(size: 11)).foregroundStyle(SmthzTheme.mutedForeground)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                let paths = entries.map(\.path)
                switch kind {
                case .staged:
                    PanelIconButton(icon: "minus", label: "Unstage all", enabled: enabled) { onAction(.unstage, paths) }
                case .changes:
                    PanelIconButton(icon: "undo-2", label: "Discard all", enabled: enabled) { onAction(.discard, paths) }
                    PanelIconButton(icon: .plus, label: "Stage all", enabled: enabled) { onAction(.stage, paths) }
                case .untracked:
                    PanelIconButton(icon: .trash2, label: "Delete all", enabled: enabled) { onAction(.discard, paths) }
                    PanelIconButton(icon: .plus, label: "Stage all", enabled: enabled) { onAction(.stage, paths) }
                case .conflicts:
                    PanelIconButton(icon: .plus, label: "Mark all resolved", enabled: enabled) { onAction(.stage, paths) }
                }
            }
            .foregroundStyle(SmthzTheme.foreground)
            .padding(.leading, 4).frame(height: 28)
            if !collapsed {
                ForEach(entries, id: \.path) { entry in
                    SourceControlRow(entry: entry, kind: kind, letter: letter(for: entry), enabled: enabled) {
                        onAction($0, [entry.path])
                    }
                }
            }
        }
    }

    private func letter(for entry: SourceControlEntry) -> String {
        switch kind {
        case .untracked: "U"
        case .conflicts: "!"
        case .staged: entry.index
        case .changes: entry.worktree
        }
    }
}

private struct SourceControlRow: View {
    let entry: SourceControlEntry
    let kind: SourceControlSection.Kind
    let letter: String
    let enabled: Bool
    let onAction: (SourceControlSection.Action) -> Void
    @State private var hovering = false

    private var tint: Color {
        switch letter {
        case "A", "U": SmthzTheme.statusSuccess
        case "D", "!": SmthzTheme.destructive
        default: SmthzTheme.statusWarning
        }
    }

    var body: some View {
        let name = (entry.path as NSString).lastPathComponent
        let dir = (entry.path as NSString).deletingLastPathComponent
        HStack(spacing: 6) {
            SmthzIcon.view("file-text", size: 12).foregroundStyle(SmthzTheme.mutedForeground)
            Text(name).font(SmthzFont.ui(size: 12)).lineLimit(1)
            if !dir.isEmpty {
                Text(dir).font(SmthzFont.ui(size: 11)).foregroundStyle(SmthzTheme.mutedForeground)
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 0)
            if hovering {
                switch kind {
                case .staged:
                    PanelIconButton(icon: "minus", label: "Unstage changes", enabled: enabled) { onAction(.unstage) }
                case .changes:
                    PanelIconButton(icon: "undo-2", label: "Discard changes", enabled: enabled) { onAction(.discard) }
                    PanelIconButton(icon: .plus, label: "Stage changes", enabled: enabled) { onAction(.stage) }
                case .untracked:
                    PanelIconButton(icon: .trash2, label: "Delete file", enabled: enabled) { onAction(.discard) }
                    PanelIconButton(icon: .plus, label: "Stage file", enabled: enabled) { onAction(.stage) }
                case .conflicts:
                    PanelIconButton(icon: .plus, label: "Mark resolved", enabled: enabled) { onAction(.stage) }
                }
            }
            Text(letter).font(SmthzFont.ui(size: 11, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 14)
        }
        .foregroundStyle(SmthzTheme.foreground)
        .padding(.horizontal, 8).frame(height: 24)
        .background(hovering ? SmthzTheme.accent.opacity(0.5) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .onHover { hovering = $0 }
        .help(entry.originalPath.map { "\($0) → \(entry.path)" } ?? entry.path)
        .contextMenu {
            switch kind {
            case .staged: Button("Unstage Changes") { onAction(.unstage) }
            case .changes:
                Button("Stage Changes") { onAction(.stage) }
                Button("Discard Changes…") { onAction(.discard) }
            case .untracked:
                Button("Stage File") { onAction(.stage) }
                Button("Delete File…") { onAction(.discard) }
            case .conflicts: Button("Mark Resolved") { onAction(.stage) }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

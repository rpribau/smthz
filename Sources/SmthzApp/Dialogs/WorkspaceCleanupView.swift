import AppKit
import Observation
import SmthzCore
import SwiftUI

/// Clean up workspaces (WP-M4-CLEANUP, Orca `WorkspaceCleanupDialog`): `worktree.cleanupScan`
/// candidates with search, filter, sort and multi-select; bulk delete through one
/// `worktree.remove` job per row, then the preserved-branches review. Opened from the
/// Resource Manager popover in its own window, so it needs no shell wiring.
@MainActor @Observable
final class WorkspaceCleanupModel {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", ready = "Ready", review = "Needs force", protected = "Protected", dismissed = "Dismissed"
        var id: String { rawValue }
    }
    enum Sort: String, CaseIterable, Identifiable {
        case activity = "Last activity", size = "Size", name = "Name"
        var id: String { rawValue }
    }
    struct Outcome { var removed = 0; var failures: [(String, String)] = []; var preserved: [String: String] = [:] }

    private(set) var candidates: [WorkspaceCleanup.Candidate] = []
    private(set) var scannedAt: Date?
    private(set) var scanning = false
    private(set) var scanProgress: (done: Int, total: Int)?
    private(set) var deleting: Set<String> = []
    var error: String?
    var selection: Set<String> = []
    var search = ""
    var filter: Filter = .all
    var sort: Sort = .activity
    let socketPath: String
    let lifecycle: WorktreeLifecycleModel

    init(socketPath: String = HostController.socketPath) {
        self.socketPath = socketPath
        lifecycle = WorktreeLifecycleModel(socketPath: socketPath)
    }

    func rows(_ filter: Filter, query rawQuery: String) -> [WorkspaceCleanup.Candidate] {
        let query = rawQuery.trimmingCharacters(in: .whitespaces).lowercased()
        return candidates.filter { c in
            guard query.isEmpty || [c.displayName, c.branch, c.path, c.repoName].contains(where: { $0.lowercased().contains(query) }) else { return false }
            switch filter {
            case .all: return !c.isDismissed
            case .ready: return c.isReady
            case .review: return c.canQueue && c.needsForce && !c.isDismissed
            case .protected: return !c.isReady && !c.isDismissed && (!c.canQueue || !c.needsForce)
            case .dismissed: return c.isDismissed
            }
        }
    }
    var visible: [WorkspaceCleanup.Candidate] {
        let rows = rows(filter, query: search)
        switch sort {
        case .activity: return rows.sorted { ($0.lastActivityAt, $0.displayName) < ($1.lastActivityAt, $1.displayName) }
        case .size: return rows.sorted { ($0.sizeBytes ?? -1) > ($1.sizeBytes ?? -1) }
        case .name: return rows.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        }
    }
    var selected: [WorkspaceCleanup.Candidate] { candidates.filter { selection.contains($0.worktreeId) } }
    func count(_ filter: Filter) -> Int { rows(filter, query: "").count }

    func scan() async {
        guard !scanning else { return }
        scanning = true; error = nil; scanProgress = nil
        defer { scanning = false; scanProgress = nil }
        let socket = socketPath
        do {
            let result = try await Task.detached { () throws -> HostJSON in
                let client = try HostClient(socketPath: socket)
                defer { client.disconnect() }
                let started = try client.json("worktree.cleanupScan", [:], timeoutMilliseconds: 30_000)
                guard let jobID = started["jobId"]?.string else { throw HostRPCError("badResponse") }
                return try client.waitForJob(jobID)
            }.value
            guard case .array(let items) = result.object?["candidates"] ?? .null else { throw HostRPCError("badResponse") }
            candidates = try items.map { try JSONDecoder().decode(WorkspaceCleanup.Candidate.self, from: JSONEncoder().encode($0)) }
            scannedAt = Date()
            let ids = Set(candidates.filter(\.canQueue).map(\.worktreeId))
            selection = selection.intersection(ids)
        } catch HostClientError.detailedHostError(let code, let detail) {
            error = WorkspaceComposerLogic.message(code: code, detail: detail)
        } catch {
            self.error = "Could not scan workspaces: \(error.localizedDescription)"
        }
    }

    func toggle(_ c: WorkspaceCleanup.Candidate) {
        guard c.canQueue, !deleting.contains(c.worktreeId) else { return }
        if selection.contains(c.worktreeId) { selection.remove(c.worktreeId) }
        else if selection.count < WorkspaceCleanup.targetBatchLimit { selection.insert(c.worktreeId) }
    }

    /// Orca bulk select: every queueable visible row except dismissed ones, capped at the batch limit.
    func selectVisible() {
        let ids = visible.filter { $0.canQueue && !$0.isDismissed }.map(\.worktreeId)
        selection = Set(ids.prefix(WorkspaceCleanup.targetBatchLimit))
    }
    func selectReady() { selection = Set(candidates.filter(\.isReady).map(\.worktreeId).prefix(WorkspaceCleanup.targetBatchLimit)) }

    func dismiss(_ c: WorkspaceCleanup.Candidate, undo: Bool = false) async {
        do {
            _ = try await call("worktree.cleanupDismiss", ["worktreeId": .string(c.worktreeId),
                                                            "fingerprint": undo ? .null : .string(c.fingerprint)])
            selection.remove(c.worktreeId)
            await scan()
        } catch { self.error = error.localizedDescription }
    }

    /// Removes the selected rows one job at a time; rows needing force are skipped unless `force`.
    func removeSelected(force: Bool) async -> Outcome {
        var outcome = Outcome()
        let rows = selected.prefix(WorkspaceCleanup.targetBatchLimit).filter { $0.canQueue && (force || !$0.needsForce) }
        for row in rows {
            deleting.insert(row.worktreeId)
            var options = WorkspaceComposerLogic.RemoveOptions()
            options.force = row.needsForce
            do {
                if let branch = try await lifecycle.remove(row.worktreeId, options: options) { outcome.preserved[row.repoId] = branch }
                outcome.removed += 1
                selection.remove(row.worktreeId)
                candidates.removeAll { $0.worktreeId == row.worktreeId }
            } catch {
                outcome.failures.append((row.displayName, error.localizedDescription))
            }
            deleting.remove(row.worktreeId)
        }
        await scan()
        return outcome
    }

    private func call(_ method: String, _ params: [String: HostJSON]) async throws -> [String: HostJSON] {
        let socket = socketPath
        do {
            return try await Task.detached {
                let client = try HostClient(socketPath: socket)
                defer { client.disconnect() }
                return try client.json(method, params, timeoutMilliseconds: 30_000)
            }.value
        } catch HostClientError.detailedHostError(let code, let detail) {
            throw WorktreeLifecycleModel.Failure(code: code, detail: detail)
        }
    }
}

struct WorkspaceCleanupView: View {
    @State var model: WorkspaceCleanupModel
    var onClose: () -> Void = {}
    @State private var confirming = false
    @State private var forceRisky = false
    @State private var working = false
    @State private var notice: String?
    @State private var review: (repoID: String, title: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(SmthzTheme.border)
            toolbar
            Divider().overlay(SmthzTheme.border)
            list
            Divider().overlay(SmthzTheme.border)
            footer
        }
        .font(SmthzFont.ui(size: 12))
        .foregroundStyle(SmthzTheme.foreground)
        .background(SmthzTheme.background)
        .frame(minWidth: 640, minHeight: 420)
        .smthzDialog(isPresented: $confirming, title: confirmTitle, description: confirmDescription) {
            confirmContent
        } footer: {
            Button("Cancel") { confirming = false }.buttonStyle(SmthzButtonStyle(.outline, size: .small))
            Button(removableCount == 1 ? "Delete Workspace" : "Delete \(removableCount) Workspaces", role: .destructive) { delete() }
                .buttonStyle(SmthzDestructiveDialogButtonStyle()).disabled(removableCount == 0 || working)
        }
        .overlay {
            if let review {
                ZStack {
                    Color.black.opacity(0.55).ignoresSafeArea()
                    SmthzPreservedBranchesDialog(repoID: review.repoID, projectTitle: review.title,
                                                 lifecycle: model.lifecycle, onDismiss: { self.review = nil })
                        .padding(24)
                }
            }
        }
        .task { await model.scan() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Clean up workspaces").font(SmthzFont.ui(size: 16, weight: .semibold))
                Text("Workspaces idle for 30 days, or archived for 7, that are clean and pushed are ready to delete. Others need force or are protected.")
                    .foregroundStyle(SmthzTheme.mutedForeground).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button { Task { await model.scan() } } label: {
                HStack(spacing: 4) { SmthzIcon.view("refresh-cw", size: 12); Text(model.scanning ? "Scanning…" : "Rescan") }
            }
            .buttonStyle(SmthzButtonStyle(.outline, size: .xs)).disabled(model.scanning)
        }
        .padding(16)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                SmthzIcon.view(.search, size: 12).foregroundStyle(SmthzTheme.mutedForeground)
                TextField("Search name, branch or path", text: $model.search).textFieldStyle(.plain)
            }
            .padding(.horizontal, 8).frame(height: 26)
            .background(SmthzTheme.muted, in: RoundedRectangle(cornerRadius: 6))
            Picker("Show", selection: $model.filter) {
                ForEach(WorkspaceCleanupModel.Filter.allCases) { f in Text("\(f.rawValue) (\(model.count(f)))").tag(f) }
            }
            .labelsHidden().fixedSize()
            Picker("Sort", selection: $model.sort) {
                ForEach(WorkspaceCleanupModel.Sort.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().fixedSize()
            Menu("Select") {
                Button("Ready workspaces") { model.selectReady() }
                Button("All shown") { model.selectVisible() }
                Button("None") { model.selection = [] }
            }
            .fixedSize()
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.visible, id: \.worktreeId) { c in
                    WorkspaceCleanupRow(candidate: c, selected: model.selection.contains(c.worktreeId),
                                        deleting: model.deleting.contains(c.worktreeId),
                                        onToggle: { model.toggle(c) },
                                        onDismiss: { Task { await model.dismiss(c, undo: c.isDismissed) } })
                    Divider().overlay(SmthzTheme.border.opacity(0.5))
                }
                if model.visible.isEmpty {
                    Text(model.scanning ? "Scanning workspaces…" : (model.candidates.isEmpty ? "No workspaces found." : "Nothing matches this view."))
                        .foregroundStyle(SmthzTheme.mutedForeground).padding(24)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let error = model.error {
                Text(error).foregroundStyle(SmthzTheme.destructive).lineLimit(2)
            } else if let notice {
                Text(notice).foregroundStyle(SmthzTheme.mutedForeground).lineLimit(2)
            } else if let at = model.scannedAt {
                Text("\(model.candidates.count) workspaces · scanned \(at.formatted(date: .omitted, time: .shortened))")
                    .foregroundStyle(SmthzTheme.mutedForeground)
            }
            Spacer(minLength: 8)
            Button("Close", action: onClose).buttonStyle(SmthzButtonStyle(.outline, size: .xs))
            Button(model.selection.isEmpty ? "Delete" : "Delete \(model.selection.count)…") {
                forceRisky = false; confirming = true
            }
            .buttonStyle(SmthzButtonStyle(.primary, size: .xs))
            .disabled(model.selection.isEmpty || working || model.scanning)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    // MARK: Confirmation

    private var risky: [WorkspaceCleanup.Candidate] { model.selected.filter(\.needsForce) }
    private var removableCount: Int { model.selected.filter { forceRisky || !$0.needsForce }.count }
    private var confirmTitle: String { model.selection.count == 1 ? "Delete 1 workspace?" : "Delete \(model.selection.count) workspaces?" }
    private var confirmDescription: String {
        "Each worktree folder is removed and its branch deleted when merged; branches with unmerged commits are kept for review."
    }
    @ViewBuilder private var confirmContent: some View {
        let protected = model.selected.filter { !$0.isReady && !$0.needsForce }
        VStack(alignment: .leading, spacing: 8) {
            if !protected.isEmpty {
                Text("\(protected.count) selected \(protected.count == 1 ? "workspace is" : "workspaces are") pinned, active or running a terminal; running terminals are closed.")
                    .foregroundStyle(SmthzTheme.statusWarning).fixedSize(horizontal: false, vertical: true)
            }
            if !risky.isEmpty {
                Toggle(isOn: $forceRisky) {
                    Text("Also force-delete \(risky.count) with uncommitted, unpushed or unverified work")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(SmthzCheckboxStyle())
                Text(risky.prefix(5).map { "\($0.displayName): \(WorkspaceCleanupRow.label($0.blockers.first { WorkspaceCleanup.forceRemoveBlockers.contains($0) || $0 == .gitStatusError } ?? .unknownBase))" }.joined(separator: "\n"))
                    .font(SmthzFont.ui(size: 11)).foregroundStyle(SmthzTheme.mutedForeground)
            }
        }
    }

    private func delete() {
        working = true; confirming = false; notice = nil
        let force = forceRisky
        Task {
            let outcome = await model.removeSelected(force: force)
            working = false
            var parts = ["Deleted \(outcome.removed) \(outcome.removed == 1 ? "workspace" : "workspaces")."]
            if let first = outcome.failures.first { parts.append("\(outcome.failures.count) failed (\(first.0): \(first.1)).") }
            notice = parts.joined(separator: " ")
            if let repo = outcome.preserved.keys.sorted().first {
                review = (repo, model.candidates.first { $0.repoId == repo }?.repoName ?? "this project")
            }
        }
    }
}

private struct WorkspaceCleanupRow: View {
    let candidate: WorkspaceCleanup.Candidate
    let selected: Bool
    let deleting: Bool
    let onToggle: () -> Void
    let onDismiss: () -> Void
    @State private var hovering = false

    static func label(_ blocker: WorkspaceCleanup.Blocker) -> String {
        switch blocker {
        case .mainWorktree: "Main checkout"
        case .folderRepo: "Folder project"
        case .pinned: "Pinned"
        case .activeWorkspace: "Active workspace"
        case .runningTerminal: "Running terminal"
        case .gitStatusError: "Git status unavailable"
        case .dirtyFiles: "Uncommitted changes"
        case .unpushedCommits: "Unpushed commits"
        case .unknownBase: "Could not verify unpushed commits"
        case .dismissed: "Dismissed"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(get: { selected }, set: { _ in onToggle() }))
                .toggleStyle(SmthzCheckboxStyle()).labelsHidden()
                .disabled(!candidate.canQueue || deleting)
                .accessibilityLabel("Select \(candidate.displayName)")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(candidate.displayName).font(SmthzFont.ui(size: 13, weight: .medium)).lineLimit(1)
                    if !candidate.branch.isEmpty {
                        Text(candidate.branch).font(SmthzFont.mono(size: 11)).foregroundStyle(SmthzTheme.mutedForeground).lineLimit(1)
                    }
                    if deleting { ProgressView().controlSize(.mini) }
                }
                Text(detail).font(SmthzFont.ui(size: 11)).foregroundStyle(SmthzTheme.mutedForeground)
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 4) {
                    if candidate.isReady { chip("Ready", SmthzTheme.statusSuccess) }
                    ForEach(candidate.reasons, id: \.self) { chip($0 == .archived ? "Archived" : "Idle", SmthzTheme.mutedForeground) }
                    ForEach(candidate.blockers, id: \.self) { b in
                        chip(Self.label(b), WorkspaceCleanup.forceRemoveBlockers.contains(b) || b == .gitStatusError ? SmthzTheme.statusWarning : SmthzTheme.mutedForeground)
                    }
                }
            }
            Spacer(minLength: 8)
            if hovering || candidate.isDismissed, candidate.canQueue {
                Button(candidate.isDismissed ? "Restore" : "Dismiss", action: onDismiss)
                    .buttonStyle(SmthzButtonStyle(.ghost, size: .xs))
                    .help(candidate.isDismissed ? "Show this workspace again" : "Hide until its Git state or activity changes")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(hovering ? SmthzTheme.accent.opacity(0.5) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onHover { hovering = $0 }
    }

    private var detail: String {
        var parts = [candidate.repoName]
        if candidate.lastActivityAt > 0 {
            parts.append("active " + RelativeDateTimeFormatter().localizedString(for: Date(timeIntervalSince1970: candidate.lastActivityAt), relativeTo: Date()))
        }
        if let bytes = candidate.sizeBytes {
            parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + (candidate.sizeTruncated ? "+" : ""))
        }
        if candidate.git.clean == true {
            var git = "clean"
            if let ahead = candidate.git.upstreamAhead { git += " · ↑\(ahead) ↓\(candidate.git.upstreamBehind ?? 0)" }
            parts.append(git)
        }
        if candidate.sessionCount > 0 { parts.append("\(candidate.runningSessionCount)/\(candidate.sessionCount) terminals running") }
        parts.append((candidate.path as NSString).abbreviatingWithTildeInPath)
        return parts.joined(separator: " · ")
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text).font(SmthzFont.ui(size: 10, weight: .medium)).foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
    }
}

/// One cleanup window per app; reopening brings it forward and rescans.
@MainActor
enum WorkspaceCleanupWindow {
    private static var window: NSWindow?

    static func show(socketPath: String = HostController.socketPath) {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil); NSApp.activate(); return
        }
        let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                               styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        created.title = "Clean up workspaces"
        created.isReleasedWhenClosed = false
        created.contentViewController = NSHostingController(rootView: WorkspaceCleanupView(
            model: WorkspaceCleanupModel(socketPath: socketPath), onClose: { [weak created] in created?.close() }))
        created.setContentSize(NSSize(width: 760, height: 560))
        created.center()
        window = created
        created.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

import SwiftUI
import SmthzCore

// Real for project workspaces since WP-M4-WORKTREE-APP (creation progress, failure/Retry, rename);
// agent statuses and badges remain VISUAL-ONLY until M5.
struct WorkspaceCardData: Identifiable, Equatable {
    enum Status: CaseIterable, Equatable { case idle, live, working, monitoring, question, error, interrupted, branch, review }
    let id: String
    var title: String
    var branch: String?
    var detail: String?
    var status: Status = .idle
    var isActive = false
    var isMultiSelected = false
    var isUnread = false
    var isPinned = false
    var isSleeping = false
    var isDeleting = false
    var isDisconnected = false
    var directory: URL?
    var repositoryName: String?
    var hostName: String?
    var isPrimary = false
    var isSparse = false
    var isDetached = false
    var conflict: String?
    var notes: String?
    var badges: [Badge] = []
    var hasParent = false
    var descendantCount = 0
    var isFolder = true
    var deletionFailure: String?
    var isQueuedForDeletion = false
    /// Worktree create job in progress (phase label, 0...1, Cancel requested).
    var creation: Creation?
    /// Failed create (host error text); the card offers Retry and Delete.
    var creationFailure: String?

    struct Creation: Equatable {
        var phase: String
        var fraction: Double
        var cancelling = false
    }

    struct Badge: Equatable, Identifiable {
        var id: String { label + icon }
        var label: String
        var icon: String
    }
}

struct WorkspaceCardView: View {
    let data: WorkspaceCardData
    let onSelect: () -> Void
    var onDelete: (() -> Void)?
    var onRename: ((String) -> Void)?
    @Environment(\.smthzWorkspaceActions) private var workspaceActions
    @Environment(\.smthzWorkspaceDirectories) private var directories
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    @State private var deleteHovered = false
    @State private var editing = false
    @State private var draft = ""
    @State private var localTitle: String?
    @State private var detectedBranch: String?
    @State private var hoverDetails = false
    @FocusState private var renameFocused: Bool

    private var actions: SmthzWorkspaceActions {
        var result = workspaceActions[data.id] ?? SmthzWorkspaceActions()
        if let onDelete { result.delete = onDelete }
        if let onRename { result.rename = onRename }
        return result
    }
    private var directory: URL? { data.directory ?? directories[data.id] }
    private var branch: String? { data.branch ?? detectedBranch }
    private var title: String { localTitle ?? data.title }
    private var hasMeta: Bool {
        directory != nil || branch != nil || data.detail != nil || data.repositoryName != nil || data.hostName != nil || !data.badges.isEmpty
    }

    private var cardSurface: some View {
        HStack(alignment: .top, spacing: 4) {
            SmthzWorkspaceStatusSlot(data: AgentStatusModel.shared.decorate(data, root: directory?.path), markRead: actions.setUnread.map { callback in { callback(false) } })
            VStack(alignment: .leading, spacing: 2) {
                titleRow
                if hasMeta { metaRow }
                if let failure = data.deletionFailure { warning("Delete failed", detail: failure) }
                if data.isQueuedForDeletion { warning("Queued for deletion", detail: "Queued for deletion") }
                if let creation = data.creation { creationRow(creation) }
                if let failure = data.creationFailure { failureRow(failure) }
            }
        }
        .padding(.leading, 8).padding(.trailing, 6)
        .padding(.top, hasMeta ? 5 : 8).padding(.bottom, hasMeta ? 6 : 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { RoundedRectangle(cornerRadius: 10).fill(fill) }
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(stroke, lineWidth: 1) }
        .shadow(color: data.isActive ? SmthzTheme.worktreeSidebarForeground.opacity(0.04) : .clear, radius: 1, y: 1)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture { if !editing { onSelect() } }
        .overlay { if data.isDeleting { deletingPill } }
        .grayscale(data.isDeleting ? 1 : 0)
        .opacity(data.isDeleting ? 0.5 : (data.isDisconnected ? 0.6 : 1))
        .padding(.leading, 4)
        .disabled(data.isDeleting)
        .onHover { hovered = $0 }
    }

    private var cardAnimation: Animation? {
        reduceMotion ? nil : Animation.easeInOut(duration: SmthzMotion.card)
    }
    private var renameAction: (() -> Void)? {
        guard actions.rename != nil else { return nil }
        return { beginRename() }
    }
    private var interactiveCard: some View {
        cardSurface
        .task(id: hovered) {
            hoverDetails = false
            guard hovered, !editing else { return }
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            hoverDetails = true
        }
        .popover(isPresented: $hoverDetails, arrowEdge: .trailing) { identityDetails }
        .contextMenu {
            SmthzWorkspaceContextMenu(data: data, directory: directory, actions: actions,
                                     update: renameAction)
        }
        .task(id: directory) { await loadBranch() }
        .onChange(of: data.title) { _, _ in localTitle = nil }
        .animation(cardAnimation, value: data.isActive)
        .animation(cardAnimation, value: hovered)
    }

    var body: some View {
        interactiveCard
            .accessibilityElement(children: .contain)
            .accessibilityLabel(title)
            .accessibilityAddTraits(data.isActive ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(named: Text("Open workspace")) { onSelect() }
    }

    private func loadBranch() async {
        detectedBranch = nil
        guard data.branch == nil, let directory else { return }
        let status: GitStatus? = try? await GitService().status(at: directory)
        guard !Task.isCancelled else { return }
        if status?.branch == "(detached)" { detectedBranch = "Detached HEAD" }
        else { detectedBranch = status?.branch }
    }

    private var titleRow: some View {
        HStack(spacing: 6) {
            if data.hostName != nil || data.isDisconnected {
                SmthzIcon.view(data.isDisconnected ? .serverOff : .server, size: 12)
                    .foregroundStyle(data.isDisconnected ? SmthzTheme.destructive : SmthzTheme.mutedForeground)
                    .help(data.isDisconnected ? "\(data.hostName ?? "SSH") disconnected" : data.hostName ?? "")
            }
            if editing {
                TextField("Rename workspace", text: $draft)
                    .textFieldStyle(.plain).font(SmthzFont.ui(size: 13))
                    .focused($renameFocused).onSubmit(commitRename)
                    .onExitCommand { editing = false }
                    .onChange(of: renameFocused) { _, focused in if !focused, editing { commitRename() } }
                    .accessibilityLabel("Rename workspace")
            } else {
                Text(title)
                    .font(SmthzFont.ui(size: 13, weight: data.isUnread ? .semibold : .regular))
                    .lineLimit(1).truncationMode(.tail)
                    .onTapGesture(count: 2, perform: beginRename)
                    .onTapGesture(count: 1, perform: onSelect)
            }
            if data.isPrimary { chip("primary").help("Primary worktree (original clone directory)") }
            if data.isSparse { chip("sparse").help("Partial checkout. Files outside these paths are not on disk.") }
            Spacer(minLength: 0)
            if data.isPinned { Image(systemName: "star.fill").font(.system(size: 12)).foregroundStyle(Color(red: 0.98, green: 0.75, blue: 0.14)) }
            if hovered, !data.isPrimary {
                Button { actions.delete?() } label: {
                    SmthzIcon.view(.trash2, size: 14)
                        .foregroundStyle(deleteHovered ? SmthzTheme.destructive : SmthzTheme.mutedForeground)
                        .frame(width: 20, height: 20)
                        .background(deleteHovered ? SmthzTheme.destructive.opacity(0.1) : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain).disabled(actions.delete == nil).onHover { deleteHovered = $0 }
                .smthzTooltip("Delete workspace", edge: .bottom).accessibilityLabel("Delete workspace")
            }
        }
        .frame(minHeight: 20)
        .foregroundStyle(data.isSleeping ? SmthzTheme.worktreeSidebarForeground.opacity(0.52) : SmthzTheme.worktreeSidebarForeground)
    }

    private var metaRow: some View {
        HStack(spacing: 6) {
            if let name = data.repositoryName {
                HStack(spacing: 3) { SmthzIcon.view(.folder, size: 10); Text(name.lowercased()) }
                    .font(SmthzFont.ui(size: 10, weight: .semibold)).lineLimit(1)
                    .padding(.horizontal, 4).frame(height: 16)
                    .background(SmthzTheme.accent, in: RoundedRectangle(cornerRadius: 4))
            }
            if let host = data.hostName { chip(host) }
            if let branch {
                Text(branch).font(SmthzFont.ui(size: 11)).lineLimit(1).help(branch)
            } else if let detail = data.detail {
                Text(detail).font(SmthzFont.ui(size: 11)).lineLimit(1)
            } else if let directory {
                Text(directory.lastPathComponent).font(.system(size: 11, design: .monospaced)).lineLimit(1).help(directory.path)
            }
            if data.isDetached { chip("Detached HEAD") }
            if let conflict = data.conflict {
                HStack(spacing: 2) { SmthzIcon.view(.gitMerge, size: 10); Text(conflict) }
                    .foregroundStyle(SmthzTheme.agentWorking).help(conflict)
            }
            Spacer(minLength: 0)
            ForEach(data.badges) { badge in
                SmthzIcon.image(badge.icon).frame(width: 11, height: 11).help(badge.label).accessibilityLabel(badge.label)
            }
        }
        .font(SmthzFont.ui(size: 11))
        .foregroundStyle(SmthzTheme.mutedForeground.opacity(data.isSleeping ? 0.34 : 1))
    }
    private func chip(_ label: String) -> some View {
        Text(label).font(SmthzFont.ui(size: 10, weight: .semibold)).lineLimit(1)
            .padding(.horizontal, 4).frame(height: 16)
            .background(SmthzTheme.accent, in: RoundedRectangle(cornerRadius: 4))
    }
    private func creationRow(_ creation: WorkspaceCardData.Creation) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(creation.cancelling ? "Cancelling…" : creation.phase).lineLimit(1)
                Spacer(minLength: 0)
                Text("\(Int(creation.fraction * 100))%").monospacedDigit()
                if let cancel = actions.cancelCreate {
                    Button("Cancel", action: cancel).buttonStyle(SmthzButtonStyle(.ghost, size: .xs))
                        .disabled(creation.cancelling).accessibilityLabel("Cancel workspace creation")
                }
            }
            ProgressView(value: creation.fraction).progressViewStyle(.linear).controlSize(.mini)
                .tint(SmthzTheme.agentWorking).accessibilityLabel("Creating workspace")
        }
        .font(SmthzFont.ui(size: 11)).foregroundStyle(SmthzTheme.mutedForeground)
        .padding(.top, 2)
    }
    private func failureRow(_ failure: String) -> some View {
        HStack(spacing: 4) {
            SmthzIcon.image("triangle-alert").frame(width: 11, height: 11)
            Text("Create failed").lineLimit(1).help(failure)
            Spacer(minLength: 0)
            if let retry = actions.retryCreate {
                Button("Retry", action: retry).buttonStyle(SmthzButtonStyle(.ghost, size: .xs))
            }
            if let delete = actions.delete {
                Button("Delete", action: delete).buttonStyle(SmthzButtonStyle(.ghost, size: .xs))
            }
        }
        .font(SmthzFont.ui(size: 11)).foregroundStyle(SmthzTheme.destructive)
        .accessibilityElement(children: .contain).accessibilityLabel("Create failed: \(failure)")
    }
    private func warning(_ title: String, detail: String) -> some View {
        HStack(spacing: 4) { SmthzIcon.image("triangle-alert").frame(width: 11, height: 11); Text(title) }
            .font(SmthzFont.ui(size: 11)).foregroundStyle(SmthzTheme.destructive).help(detail)
    }
    private var identityDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(SmthzFont.ui(size: 13, weight: .semibold))
            if let name = data.repositoryName { Text(name) }
            if let branch { Label(branch, systemImage: "arrow.triangle.branch") }
            if let directory { Text(directory.path).textSelection(.enabled) }
            ForEach(data.badges) { Text($0.label) }
            if let notes = data.notes { Divider(); Text("Workspace notes").fontWeight(.medium); Text(notes) }
        }
        .font(SmthzFont.ui(size: 11)).padding(12).frame(maxWidth: 280, alignment: .leading)
    }
    private func beginRename() {
        guard actions.rename != nil, !data.isDeleting else { return }
        hoverDetails = false; draft = title; editing = true; renameFocused = true
    }
    private func commitRename() {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        editing = false
        guard !value.isEmpty, value != title, let rename = actions.rename else { return }
        rename(value); localTitle = value
    }
    private var fill: Color {
        if data.isActive { return SmthzTheme.worktreeSidebarForeground.opacity(0.09) }
        if data.isMultiSelected { return SmthzTheme.worktreeSidebarAccent.opacity(0.7) }
        return hovered ? SmthzTheme.sidebarAccent.opacity(0.4) : .clear
    }
    private var stroke: Color {
        if data.isActive { return SmthzTheme.worktreeSidebarForeground.opacity(0.18) }
        return data.isMultiSelected ? SmthzTheme.worktreeSidebarRing.opacity(0.35) : .clear
    }
    private var deletingPill: some View {
        HStack(spacing: 4) {
            ProgressView().controlSize(.mini)
            Text("Deleting…").font(SmthzFont.ui(size: 11, weight: .medium))
        }
        .padding(.horizontal, 8).padding(.vertical, 2)
        .background(SmthzTheme.popover, in: Capsule())
        .overlay { Capsule().strokeBorder(SmthzTheme.border, lineWidth: 1) }
    }
}

#if DEBUG
#Preview("Workspace states") {
    // VISUAL-ONLY: stub data until the M4 workspace model.
    VStack(spacing: 4) {
        ProjectHeaderRow(title: "smthz", isCollapsed: .constant(false))
        ForEach(Array(WorkspaceCardData.Status.allCases.enumerated()), id: \.offset) { index, status in
            WorkspaceCardView(data: WorkspaceCardData(id: "preview-\(index)", title: String(describing: status).capitalized,
                branch: "feature/workspaces", status: status, isActive: index == 1, repositoryName: "smthz"), onSelect: {})
        }
        WorkspaceCardView(data: WorkspaceCardData(id: "unread", title: "Unread", isUnread: true, isPinned: true), onSelect: {})
        WorkspaceCardView(data: WorkspaceCardData(id: "sleep", title: "Sleeping", isSleeping: true), onSelect: {})
        WorkspaceCardView(data: WorkspaceCardData(id: "deleting", title: "Deleting", isDeleting: true), onSelect: {})
    }.padding(8).frame(width: 280).background(SmthzTheme.worktreeSidebar)
}
#endif

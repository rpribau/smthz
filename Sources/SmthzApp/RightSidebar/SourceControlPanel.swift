import SmthzCore
import SwiftUI

@MainActor @Observable
final class SourceControlModel {
    enum State: Equatable { case idle, loading, notGit, loaded, failed(String) }
    var state: State = .idle
    var status: GitStatus?
    var filter = ""

    func load(directory: URL) async {
        state = .loading
        let git = GitService()
        do {
            guard try await git.repository(at: directory) != nil else { state = .notGit; status = nil; return }
            status = try await git.status(at: directory)
            state = .loaded
        } catch {
            state = .failed(String(describing: error))
        }
    }

    private var visible: [GitStatusEntry] {
        guard let status else { return [] }
        return filter.isEmpty ? status.entries : status.entries.filter { $0.path.localizedCaseInsensitiveContains(filter) }
    }
    var staged: [GitStatusEntry] {
        visible.filter { ($0.kind == .ordinary || $0.kind == .renamed) && $0.indexStatus != "." }
    }
    var changes: [GitStatusEntry] {
        visible.filter { ($0.kind == .ordinary || $0.kind == .renamed) && $0.worktreeStatus != "." }
    }
    var untracked: [GitStatusEntry] { visible.filter { $0.kind == .untracked } }
    var conflicts: [GitStatusEntry] { visible.filter { $0.kind == .unmerged } }
}

struct SourceControlPanel: View {
    /// Workspace root (the active session's cwd); nil means no workspace.
    let rootURL: URL?
    @State private var model = SourceControlModel()
    @State private var message = ""
    @State private var viewAsTree = false
    @State private var refreshTick = 0

    var body: some View {
        Group {
            if rootURL == nil {
                PanelEmptyState(icon: .gitBranch, title: "Select a workspace to view changes", detail: nil)
            } else if model.state == .notGit {
                PanelEmptyState(icon: .gitBranch, title: "Source Control is only available for Git repositories", detail: nil)
            } else if case .failed(let reason) = model.state {
                PanelEmptyState(icon: .alertTriangle, title: "Could not read Git status", detail: reason)
            } else {
                loadedBody
            }
        }
        .task(id: "\(rootURL?.path ?? "")#\(refreshTick)") {
            if let rootURL { await model.load(directory: rootURL) }
        }
    }

    private var loadedBody: some View {
        VStack(spacing: 0) {
            header
            PanelSearchField(icon: .search, prompt: "Filter files…", text: $model.filter, clearLabel: "Clear filter")
                .padding(.horizontal, 8).padding(.bottom, 6)
            commitBox
            if model.state == .loading && model.status == nil {
                Spacer()
            } else if model.status?.entries.isEmpty ?? true {
                Text("No changes on this branch")
                    .font(SmthzFont.ui(size: 12)).foregroundStyle(SmthzTheme.mutedForeground)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        section("Merge Conflicts", model.conflicts, actions: false)
                        section("Staged Changes", model.staged, minus: true)
                        section("Changes", model.changes, plus: true, undo: true)
                        section("Untracked Files", model.untracked, plus: true)
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
                .help("Current branch: \(model.status?.branch ?? "none")")
            Spacer(minLength: 0)
            PanelIconButton(icon: viewAsTree ? "list-tree" : .list,
                            label: viewAsTree ? "View as list" : "View as tree") { viewAsTree.toggle() }
            // VISUAL-ONLY: stub data until a notes store exists
            PanelIconButton(icon: .messageSquare, label: "Notes", enabled: false) {}
            PanelIconButton(icon: "refresh-cw", label: "Refresh branch compare") { refreshTick += 1 }
            PanelIconButton(icon: .ellipsis, label: "More source control actions", enabled: false) {}
        }
        .foregroundStyle(SmthzTheme.foreground)
        .padding(.horizontal, 8).padding(.vertical, 6)
    }

    /// Commit box is visual only: staging and committing are not wired yet.
    private var commitBox: some View {
        VStack(spacing: 6) {
            TextField("Message", text: $message, axis: .vertical)
                .textFieldStyle(.plain).font(SmthzFont.ui(size: 12)).lineLimit(2...4)
                .padding(8).disabled(true)
                .background(RoundedRectangle(cornerRadius: 6).strokeBorder(SmthzTheme.input))
                .accessibilityLabel("Commit message")
            Button {} label: {
                Text("Commit").frame(maxWidth: .infinity)
            }
            .buttonStyle(SmthzButtonStyle(.primary, size: .small)).disabled(true)
        }
        .padding(.horizontal, 8).padding(.bottom, 8)
    }

    @ViewBuilder
    private func section(_ title: String, _ entries: [GitStatusEntry], minus: Bool = false,
                         plus: Bool = false, undo: Bool = false, actions: Bool = true) -> some View {
        if !entries.isEmpty {
            SourceControlSection(title: title, entries: entries, minus: minus, plus: plus, undo: undo)
        }
    }
}

private struct SourceControlSection: View {
    let title: String
    let entries: [GitStatusEntry]
    let minus: Bool
    let plus: Bool
    let undo: Bool
    @State private var collapsed = false

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
                // Read-only for now: the buttons exist but stay disabled until staging is wired.
                if minus { PanelIconButton(icon: "minus", label: "Unstage all", enabled: false) {} }
                if undo { PanelIconButton(icon: "undo-2", label: "Discard all", enabled: false) {} }
                if plus { PanelIconButton(icon: .plus, label: "Stage all", enabled: false) {} }
            }
            .foregroundStyle(SmthzTheme.foreground)
            .padding(.leading, 4).frame(height: 28)
            if !collapsed {
                ForEach(entries, id: \.path) { entry in
                    SourceControlRow(entry: entry, untracked: title == "Untracked Files",
                                     letter: letter(for: entry))
                }
            }
        }
    }

    private func letter(for entry: GitStatusEntry) -> String {
        if entry.kind == .untracked { return "U" }
        if entry.kind == .unmerged { return "!" }
        let c = title == "Staged Changes" ? entry.indexStatus : entry.worktreeStatus
        return String(c)
    }
}

private struct SourceControlRow: View {
    let entry: GitStatusEntry
    let untracked: Bool
    let letter: String
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
            Text(letter).font(SmthzFont.ui(size: 11, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 14)
        }
        .foregroundStyle(SmthzTheme.foreground)
        .padding(.horizontal, 8).frame(height: 24)
        .background(hovering ? SmthzTheme.accent.opacity(0.5) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .onHover { hovering = $0 }
        .help(entry.path)
        .accessibilityElement(children: .combine)
    }
}

import AppKit
import SmthzCore
import SwiftUI
import UniformTypeIdentifiers

/// One visible row of the Explorer tree. `path` is relative to the Explorer root ("" = root).
struct ExplorerNode: Identifiable, Equatable {
    let path: String
    let depth: Int
    let isDirectory: Bool
    let isSymlink: Bool
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var parent: String { (path as NSString).deletingLastPathComponent }
}

/// Explorer state (M4-PLAN §10.3). File operations go through the host (`fs.*`) and are confined
/// to the root; folders the host does not accept (not a project, host down) are listed read-only.
@MainActor @Observable
final class ExplorerModel {
    enum Editing: Equatable {
        case create(parent: String, isDirectory: Bool)
        case rename(String)
    }
    enum GitMark: Equatable { case untracked, modified, added, deleted, conflict, renamed }

    var root: URL?
    /// Host-accepted root path; nil = read-only local listing.
    private(set) var hostRoot: String?
    private(set) var readOnlyReason: String?
    private(set) var isGit = false
    var expanded: Set<String> = []
    private var children: [String: [HostFileEntry]] = [:]
    var nodes: [ExplorerNode] = []
    var showDotfiles = false
    var showGitIgnored = true
    var filter = ""
    var errorMessage: String?
    var actionError: String?
    var selection: String?
    var editing: Editing?
    var editText = ""
    var dropTarget: String?
    private(set) var gitMarks: [String: GitMark] = [:]
    private(set) var ignored: Set<String> = []
    let undo = ExplorerUndoStack()
    private var cursor: UInt64?

    private static let filterLimit = 500

    func load(root: URL?, isGit: Bool) async {
        if self.root != root { expanded = []; selection = nil; editing = nil; children = [:]; cursor = nil }
        self.root = root
        self.isGit = isGit
        hostRoot = nil; readOnlyReason = nil
        guard let root else { nodes = []; undo.reset(root: nil); return }
        let path = root.path
        do {
            let listed = try await FilesHost.run { try $0.fsList(root: path) }
            guard self.root == root else { return }
            hostRoot = path
            children = ["": listed.entries]
        } catch {
            guard self.root == root else { return }
            readOnlyReason = Self.readOnlyText(error)
            children = [:]
        }
        undo.reset(root: hostRoot)
        await reload()
    }

    private static func readOnlyText(_ error: any Error) -> String {
        if case HostClientError.hostNotRunning = error { return "Read-only: host not running" }
        return "Read-only: add this folder as a project to create, rename or delete files"
    }

    /// Re-reads every expanded directory, then refreshes Git decorations.
    func reload() async {
        errorMessage = nil
        guard root != nil else { nodes = []; return }
        if !filter.isEmpty { nodes = filtered(); return }
        for dir in [""] + expanded.sorted() { await loadChildren(dir) }
        rebuild()
        await refreshGit()
    }

    private func loadChildren(_ dir: String) async {
        guard let root else { return }
        if let hostRoot {
            do {
                let listed = try await FilesHost.run { try $0.fsList(root: hostRoot, path: dir) }
                children[dir] = listed.entries
            } catch {
                if dir.isEmpty { errorMessage = FilesHost.describe(error) }
                children[dir] = nil; expanded.remove(dir)
            }
        } else {
            do { children[dir] = try Self.localEntries(root.appendingPathComponent(dir)) } catch {
                if dir.isEmpty { errorMessage = error.localizedDescription }
                children[dir] = nil
            }
        }
    }

    private static func localEntries(_ directory: URL) throws -> [HostFileEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)
        let entries = urls.compactMap { url -> FileEntry? in
            url.lastPathComponent == ".git" ? nil : try? FileOperations.entry(at: url)
        }
        return FileOperations.sorted(entries).map {
            HostFileEntry(name: $0.name, kind: $0.kind.rawValue, targetIsDirectory: $0.targetIsDirectory,
                          size: Double($0.size), mtime: $0.mtime)
        }
    }

    private func rebuild() {
        var out: [ExplorerNode] = []
        func append(_ dir: String, depth: Int) {
            for entry in children[dir] ?? [] {
                if !showDotfiles, entry.name.hasPrefix(".") { continue }
                let path = dir.isEmpty ? entry.name : dir + "/" + entry.name
                if !showGitIgnored, ignored.contains(path) { continue }
                // Symlinked directories are shown but not expanded (they may point outside the root).
                let isDir = entry.kind == "dir"
                out.append(ExplorerNode(path: path, depth: depth, isDirectory: isDir, isSymlink: entry.kind == "symlink"))
                if isDir, expanded.contains(path) { append(path, depth: depth + 1) }
            }
        }
        append("", depth: 0)
        nodes = out
    }

    func toggle(_ node: ExplorerNode) async {
        selection = node.id
        guard node.isDirectory else { return }
        if expanded.contains(node.id) { expanded.remove(node.id); rebuild(); return }
        expanded.insert(node.id)
        await loadChildren(node.id)
        rebuild()
        await refreshIgnored()
    }

    func collapseAll() { expanded = []; rebuild() }
    func toggleDotfiles() { showDotfiles.toggle(); rebuild() }
    func toggleIgnored() { showGitIgnored.toggle(); rebuild() }

    // MARK: Git decorations (host git.status + git.checkIgnored for visible rows)

    private func refreshGit() async {
        guard let hostRoot, isGit else { gitMarks = [:]; ignored = []; return }
        if let status = try? await FilesHost.run({ try $0.gitStatus(worktreePath: hostRoot) }) {
            var marks: [String: GitMark] = [:]
            for entry in status.entries {
                let mark: GitMark = switch entry.kind {
                case "untracked": .untracked
                case "unmerged": .conflict
                case "renamed", "copied": .renamed
                default: entry.index == "A" ? .added : (entry.worktree == "D" || entry.index == "D") ? .deleted : .modified
                }
                marks[entry.path] = mark
                var parent = (entry.path as NSString).deletingLastPathComponent
                while !parent.isEmpty {
                    if marks[parent] == nil || mark == .conflict { marks[parent] = mark == .conflict ? .conflict : .modified }
                    parent = (parent as NSString).deletingLastPathComponent
                }
            }
            gitMarks = marks
        }
        await refreshIgnored()
    }

    private func refreshIgnored() async {
        guard let hostRoot, isGit else { return }
        let paths = Array(nodes.map(\.path).prefix(2_000))
        guard !paths.isEmpty else { ignored = []; return }
        struct P: Encodable { let worktreePath: String; let paths: [String] }
        struct R: Decodable { let ignored: [String] }
        if let r: R = try? await FilesHost.run({ try $0.callWithDetail(method: "git.checkIgnored", params: P(worktreePath: hostRoot, paths: paths)) }) {
            ignored = Set(r.ignored.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 })
            if !showGitIgnored { rebuild() }
        }
    }

    func mark(for path: String) -> GitMark? { gitMarks[path] }

    // MARK: Live refresh (fs.changes)

    /// Polls the host change feed while the panel is visible; reloads only affected directories.
    func watch() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard let hostRoot, !Task.isCancelled else { continue }
            let since = cursor
            guard let changes = try? await FilesHost.run({ try $0.fsChanges(root: hostRoot, cursor: since) }),
                  hostRoot == self.hostRoot else { continue }
            cursor = changes.cursor
            guard since != nil else { continue }
            if changes.overflow { await reload(); continue }
            guard !changes.changed.isEmpty else { continue }
            var dirs = Set<String>()
            for path in changes.changed where !path.hasPrefix(".git/") && path != ".git" {
                let parent = (path as NSString).deletingLastPathComponent
                if parent.isEmpty || expanded.contains(parent) { dirs.insert(parent) }
                if expanded.contains(path) { dirs.insert(path) }
            }
            if !filter.isEmpty { nodes = filtered(); continue }
            for dir in dirs.sorted() { await loadChildren(dir) }
            if !dirs.isEmpty { rebuild() }
            await refreshGit()
        }
    }

    // MARK: Operations

    func directoryForNew(from node: ExplorerNode?) -> String {
        guard let node else { return "" }
        return node.isDirectory ? node.path : node.parent
    }

    func beginCreate(in parent: String, isDirectory: Bool) async {
        guard hostRoot != nil else { return }
        if !parent.isEmpty, !expanded.contains(parent) {
            expanded.insert(parent); await loadChildren(parent); rebuild()
        }
        editText = ""
        editing = .create(parent: parent, isDirectory: isDirectory)
    }

    func beginRename(_ node: ExplorerNode) {
        guard hostRoot != nil else { return }
        editText = node.name
        editing = .rename(node.path)
    }

    func commitEdit() async {
        guard let editing, let hostRoot else { return }
        let name = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.editing = nil
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return }
        switch editing {
        case .create(let parent, let dir):
            let path = parent.isEmpty ? name : parent + "/" + name
            await perform(.create(path: path, isDirectory: dir, trashed: nil)) { client in
                if dir { try client.fsCreateDirectory(root: hostRoot, path: path) } else { try client.fsCreateFile(root: hostRoot, path: path) }
            }
            selection = path
        case .rename(let from):
            let parent = (from as NSString).deletingLastPathComponent
            let to = parent.isEmpty ? name : parent + "/" + name
            guard to != from else { return }
            await perform(.rename(from: from, to: to)) { try $0.fsRename(root: hostRoot, from: from, to: to) }
            if expanded.remove(from) != nil { expanded.insert(to) }
            selection = to
        }
    }

    func trash(_ node: ExplorerNode) async {
        guard let hostRoot else { return }
        let path = node.path
        do {
            let trashed = try await FilesHost.run { try $0.fsTrash(root: hostRoot, path: path) }
            undo.record(.trash(path: path, trashed: trashed))
            expanded = expanded.filter { $0 != path && !$0.hasPrefix(path + "/") }
            if selection == path { selection = nil }
        } catch { actionError = "Delete failed: " + FilesHost.describe(error) }
        await reload()
    }

    func duplicate(_ node: ExplorerNode) async {
        guard let hostRoot else { return }
        let siblings = Set((children[node.parent] ?? []).map(\.name))
        let name = FileOperations.duplicateName(for: node.name, existing: siblings)
        let to = node.parent.isEmpty ? name : node.parent + "/" + name
        await perform(.copy(paths: [to], trashed: [])) { try $0.fsCopy(root: hostRoot, from: node.path, to: to) }
        selection = to
    }

    /// Finder drop: copy in. Drag inside the tree: move (rename) into `directory`.
    func drop(_ urls: [URL], into directory: String) async {
        guard let hostRoot else { return }
        let prefix = hostRoot.hasSuffix("/") ? hostRoot : hostRoot + "/"
        var outside: [String] = []
        for url in urls {
            let source = url.standardizedFileURL.path
            if source.hasPrefix(prefix) {
                let from = String(source.dropFirst(prefix.count))
                let name = (from as NSString).lastPathComponent
                let to = directory.isEmpty ? name : directory + "/" + name
                guard to != from, !directory.hasPrefix(from + "/"), directory != from else { continue }
                await perform(.rename(from: from, to: to)) { try $0.fsRename(root: hostRoot, from: from, to: to) }
            } else {
                outside.append(source)
            }
        }
        let external = outside
        guard !external.isEmpty else { return }
        do {
            let created = try await FilesHost.run { try $0.fsImportExternal(root: hostRoot, destDir: directory, sources: external) }
            undo.record(.copy(paths: created, trashed: []))
        } catch { actionError = "Import failed: " + FilesHost.describe(error) }
        if !directory.isEmpty { expanded.insert(directory) }
        await reload()
    }

    func addToGitignore(_ node: ExplorerNode) async {
        guard let hostRoot else { return }
        struct P: Encodable { let worktreePath: String; let pattern: String }
        struct Empty: Decodable {}
        let pattern = "/" + node.path + (node.isDirectory ? "/" : "")
        do {
            let _: Empty = try await FilesHost.run { try $0.callWithDetail(method: "git.appendGitignore", params: P(worktreePath: hostRoot, pattern: pattern)) }
        } catch { actionError = "Add to .gitignore failed: " + FilesHost.describe(error) }
        await reload()
    }

    func stage(_ node: ExplorerNode) async {
        guard let hostRoot else { return }
        do { try await FilesHost.run { try $0.gitStage(worktreePath: hostRoot, paths: [node.path]) } }
        catch { actionError = "Stage failed: " + FilesHost.describe(error) }
        await refreshGit()
    }

    func discard(_ node: ExplorerNode) async {
        guard let hostRoot else { return }
        let untracked = mark(for: node.path) == .untracked
        do { try await FilesHost.run { try $0.gitDiscard(worktreePath: hostRoot, paths: [node.path], includeUntracked: untracked) } }
        catch { actionError = "Discard failed: " + FilesHost.describe(error) }
        await reload()
    }

    func undoLast() async {
        do { _ = try await undo.undo() } catch { actionError = "Undo failed: " + FilesHost.describe(error) }
        await reload()
    }

    func redoLast() async {
        do { _ = try await undo.redo() } catch { actionError = "Redo failed: " + FilesHost.describe(error) }
        await reload()
    }

    private func perform(_ op: ExplorerFileOperation, _ body: @escaping @Sendable (HostClient) throws -> Void) async {
        do {
            try await FilesHost.run(body)
            undo.record(op)
        } catch { actionError = "\(op.label) failed: " + FilesHost.describe(error) }
        await reload()
    }

    func url(_ node: ExplorerNode) -> URL? { root?.appendingPathComponent(node.path) }

    private func filtered() -> [ExplorerNode] {
        guard let root else { return [] }
        var out: [ExplorerNode] = []
        var queue = [""]
        while !queue.isEmpty, out.count < Self.filterLimit {
            let dir = queue.removeFirst()
            guard let list = try? Self.localEntries(root.appendingPathComponent(dir)) else { continue }
            for entry in list {
                if !showDotfiles, entry.name.hasPrefix(".") { continue }
                let path = dir.isEmpty ? entry.name : dir + "/" + entry.name
                if entry.name.localizedCaseInsensitiveContains(filter) {
                    out.append(ExplorerNode(path: path, depth: 0, isDirectory: entry.kind == "dir", isSymlink: entry.kind == "symlink"))
                }
                if entry.kind == "dir", entry.name != "node_modules" { queue.append(path) }
            }
        }
        return out
    }
}

/// Requests from the Explorer to the Search panel ("Find in Folder").
@MainActor @Observable
final class FileSearchRequests {
    static let shared = FileSearchRequests()
    struct Request: Equatable { let root: String; let scope: String; let id = UUID() }
    var pending: Request?
}

struct ExplorerPanel: View {
    /// Workspace root (Git top level of the active cwd, or the project folder); nil means no workspace.
    let rootURL: URL?
    var isGitRepository = false
    @State private var model = ExplorerModel()
    @State private var searchMode = 0  // 0 = Names, 1 = Contents
    @State private var confirmDelete: ExplorerNode?
    @State private var confirmDiscard: ExplorerNode?
    @State private var monitor = ExplorerFocusMonitor()
    @AppStorage("shell.rightSidebarPanel") private var storedPanel = "explorer"

    var body: some View {
        VStack(spacing: 0) {
            if rootURL == nil {
                PanelEmptyState(icon: .files, title: "Select a workspace to browse files", detail: nil)
            } else {
                header
                if searchMode == 0 { nameFilter }
                if let reason = model.readOnlyReason, searchMode == 0 { banner(reason, dismiss: nil) }
                if let error = model.actionError { banner(error) { model.actionError = nil } }
                if searchMode == 1 {
                    SearchPanel(rootURL: rootURL, embedded: true)
                } else {
                    content
                }
            }
        }
        .background(GeometryReader { proxy in Color.clear.onAppear { monitor.frame = proxy.frame(in: .global) }
            .onChange(of: proxy.frame(in: .global)) { _, frame in monitor.frame = frame } })
        .task(id: TaskKey(root: rootURL, git: isGitRepository)) { await model.load(root: rootURL, isGit: isGitRepository) }
        .task(id: rootURL) { await model.watch() }
        .onAppear { monitor.install { handleShortcut($0) } }
        .onDisappear { monitor.remove() }
        .confirmationDialog("Move “\(confirmDelete?.name ?? "")” and its contents to the Trash?", isPresented: Binding(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) {
                if let node = confirmDelete { Task { await model.trash(node) } }
                confirmDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        } message: { Text("You can undo this with ⌘Z in the Explorer.") }
        .confirmationDialog("Discard changes to “\(confirmDiscard?.name ?? "")”?", isPresented: Binding(
            get: { confirmDiscard != nil }, set: { if !$0 { confirmDiscard = nil } }), titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) {
                if let node = confirmDiscard { Task { await model.discard(node) } }
                confirmDiscard = nil
            }
            Button("Cancel", role: .cancel) { confirmDiscard = nil }
        } message: { Text("This cannot be undone from the Explorer.") }
    }

    private struct TaskKey: Equatable { let root: URL?; let git: Bool }

    private var writable: Bool { model.hostRoot != nil }
    private var selectedNode: ExplorerNode? { model.nodes.first { $0.id == model.selection } }

    /// Explorer-scoped shortcuts (Orca `fileExplorer.*`), delivered by `ExplorerFocusMonitor` only
    /// after a click inside the Explorer and while no text field has focus.
    private func handleShortcut(_ action: KeybindingAction) -> Bool {
        guard searchMode == 0, model.editing == nil else { return false }
        switch action {
        case .fileExplorerUndo:
            guard model.undo.canUndo else { return false }
            Task { await model.undoLast() }
        case .fileExplorerRedo:
            guard model.undo.canRedo else { return false }
            Task { await model.redoLast() }
        case .fileExplorerDelete:
            guard let node = selectedNode, writable else { return false }
            requestDelete(node)
        case .fileExplorerCopyPath, .fileExplorerCopyRelativePath:
            guard let node = selectedNode else { return false }
            copyPath(node, relative: action == .fileExplorerCopyRelativePath)
        default: return false
        }
        return true
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                HStack(spacing: 4) {
                    SmthzIcon.view(.folderTree, size: 12)
                    Text(rootURL?.lastPathComponent ?? (isGitRepository ? "Repository root" : "Explorer root"))
                        .font(SmthzFont.ui(size: 12, weight: .medium)).lineLimit(1)
                }
                .foregroundStyle(SmthzTheme.foreground)
                .padding(.horizontal, 6).frame(height: 24)
                .help(rootURL?.path ?? "")
                Spacer(minLength: 0)
                PanelIconButton(icon: "file-plus", label: "New File", enabled: writable) {
                    Task { await model.beginCreate(in: model.directoryForNew(from: selectedNode), isDirectory: false) }
                }
                PanelIconButton(icon: .folderPlus, label: "New Folder", enabled: writable) {
                    Task { await model.beginCreate(in: model.directoryForNew(from: selectedNode), isDirectory: true) }
                }
                PanelIconButton(icon: "refresh-cw", label: "Refresh Explorer") { Task { await model.reload() } }
                PanelIconButton(icon: "list-collapse", label: "Collapse All") { model.collapseAll() }
                Menu {
                    Toggle("Show Dotfiles", isOn: Binding(get: { model.showDotfiles }, set: { _ in model.toggleDotfiles() }))
                    Toggle("Show Git Ignored Files", isOn: Binding(get: { model.showGitIgnored }, set: { _ in model.toggleIgnored() }))
                        .disabled(!isGitRepository)
                    Divider()
                    Button("Undo \(model.undo.undoItems.last?.label ?? "")") { Task { await model.undoLast() } }
                        .disabled(!model.undo.canUndo)
                    Button("Redo \(model.undo.redoItems.last?.label ?? "")") { Task { await model.redoLast() } }
                        .disabled(!model.undo.canRedo)
                } label: {
                    SmthzIcon.view(.ellipsis, size: 14).foregroundStyle(SmthzTheme.mutedForeground)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help("More Explorer Actions").accessibilityLabel("More Explorer Actions")
            }
            HStack(spacing: 0) {
                modeButton("Names", 0, help: "Filter files by name")
                modeButton("Contents", 1, help: "Search file contents")
            }
            .padding(2).background(SmthzTheme.muted, in: RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel("Explorer search mode")
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
    }

    private func modeButton(_ title: String, _ tag: Int, help: String) -> some View {
        Button { searchMode = tag } label: {
            Text(title).font(SmthzFont.ui(size: 12, weight: .medium))
                .foregroundStyle(searchMode == tag ? SmthzTheme.foreground : SmthzTheme.mutedForeground)
                .frame(maxWidth: .infinity).frame(height: 22)
                .background(searchMode == tag ? SmthzTheme.background : .clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help)
    }

    private var nameFilter: some View {
        PanelSearchField(icon: "list-filter", prompt: "Find files", text: Binding(
            get: { model.filter }, set: { model.filter = $0; Task { await model.reload() } }), clearLabel: "Clear file filter")
            .padding(.horizontal, 8).padding(.bottom, 6)
    }

    private func banner(_ text: String, dismiss: (() -> Void)?) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(text).font(SmthzFont.ui(size: 11)).foregroundStyle(SmthzTheme.mutedForeground)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let dismiss {
                Button(action: dismiss) { SmthzIcon.view(.x, size: 10) }.buttonStyle(.plain)
                    .foregroundStyle(SmthzTheme.mutedForeground).accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(SmthzTheme.muted.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 8).padding(.bottom, 6)
    }

    // MARK: Body

    @ViewBuilder private var content: some View {
        if let error = model.errorMessage {
            Text("Could not load files for this workspace: \(error)")
                .font(SmthzFont.ui(size: 12)).foregroundStyle(SmthzTheme.mutedForeground)
                .multilineTextAlignment(.center).padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.nodes.isEmpty && model.editing == nil {
            Text(model.filter.isEmpty ? "No files in this workspace" : "No files in this folder")
                .font(SmthzFont.ui(size: 12)).foregroundStyle(SmthzTheme.mutedForeground)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contextMenu { rootMenu }
                .onDrop(of: [.fileURL], isTargeted: nil) { handleDrop($0, into: "") }
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if case .create(let parent, let dir)? = model.editing, parent.isEmpty { editRow(depth: 0, isDirectory: dir) }
                    ForEach(model.nodes) { node in
                        if case .rename(let path)? = model.editing, path == node.path {
                            editRow(depth: node.depth, isDirectory: node.isDirectory)
                        } else {
                            row(node)
                        }
                        if case .create(let parent, let dir)? = model.editing, parent == node.path, node.isDirectory {
                            editRow(depth: node.depth + 1, isDirectory: dir)
                        }
                    }
                    Color.clear.frame(height: 40).contentShape(Rectangle())
                        .contextMenu { rootMenu }
                        .onDrop(of: [.fileURL], isTargeted: nil) { handleDrop($0, into: "") }
                }
                .padding(.horizontal, 6)
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { handleDrop($0, into: "") }
        }
    }

    private func row(_ node: ExplorerNode) -> some View {
        ExplorerRow(node: node, isExpanded: model.expanded.contains(node.id), isSelected: model.selection == node.id,
                    isDropTarget: model.dropTarget == node.id, mark: model.mark(for: node.path),
                    isIgnored: model.ignored.contains(node.path)) {
            if node.isDirectory { Task { await model.toggle(node) } } else { model.selection = node.id }
        } open: {
            if let url = model.url(node), !node.isDirectory { InterimFileOpener.open(url) }
        }
        .contextMenu { menu(node) }
        .onDrag { NSItemProvider(object: (model.url(node) ?? URL(fileURLWithPath: "/")) as NSURL) }
        .onDrop(of: [.fileURL], isTargeted: Binding(get: { model.dropTarget == node.id },
                                                    set: { model.dropTarget = $0 ? node.id : (model.dropTarget == node.id ? nil : model.dropTarget) })) {
            handleDrop($0, into: node.isDirectory ? node.path : node.parent)
        }
    }

    private func editRow(depth: Int, isDirectory: Bool) -> some View {
        ExplorerEditRow(depth: depth, isDirectory: isDirectory, text: $model.editText) {
            Task { await model.commitEdit() }
        } cancel: { model.editing = nil }
    }

    @ViewBuilder private var rootMenu: some View {
        Button("New File…") { Task { await model.beginCreate(in: "", isDirectory: false) } }.disabled(!writable)
        Button("New Folder…") { Task { await model.beginCreate(in: "", isDirectory: true) } }.disabled(!writable)
        Divider()
        Button("Find in Folder…") { findInFolder("") }.disabled(!writable)
        Button("Reveal in Finder") { if let root = rootURL { NSWorkspace.shared.activateFileViewerSelecting([root]) } }
    }

    @ViewBuilder private func menu(_ node: ExplorerNode) -> some View {
        if !node.isDirectory {
            // INTERIM (M4-D8): no editor yet.
            Button(InterimFileOpener.action(for: model.url(node) ?? URL(fileURLWithPath: "/")) == .openWithDefaultApp
                   ? "Open with Default App" : "Reveal Executable in Finder") {
                if let url = model.url(node) { InterimFileOpener.open(url) }
            }
        }
        Button("Reveal in Finder") { if let url = model.url(node) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
        // VISUAL-ONLY: needs a ShellController entry point that opens a tab at a cwd.
        Button("Open in Terminal") {}.disabled(true)
        Divider()
        Button("New File…") { Task { await model.beginCreate(in: model.directoryForNew(from: node), isDirectory: false) } }.disabled(!writable)
        Button("New Folder…") { Task { await model.beginCreate(in: model.directoryForNew(from: node), isDirectory: true) } }.disabled(!writable)
        Button("Rename…") { model.beginRename(node) }.disabled(!writable)
        Button("Duplicate") { Task { await model.duplicate(node) } }.disabled(!writable)
        Button("Delete") { requestDelete(node) }.disabled(!writable)
        Divider()
        Button("Copy") {
            if let url = model.url(node) { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([url as NSURL]) }
        }
        Button("Copy Path") { copyPath(node, relative: false) }
        Button("Copy Relative Path") { copyPath(node, relative: true) }
        if node.isDirectory {
            Divider()
            Button("Find in Folder…") { findInFolder(node.path) }.disabled(!writable)
        }
        if isGitRepository {
            Divider()
            Button("Add to .gitignore") { Task { await model.addToGitignore(node) } }.disabled(!writable)
            if model.mark(for: node.path) != nil {
                Button("Stage Changes") { Task { await model.stage(node) } }.disabled(!writable)
                Button("Discard Changes…") { confirmDiscard = node }.disabled(!writable)
            }
        }
    }

    private func requestDelete(_ node: ExplorerNode) {
        if node.isDirectory { confirmDelete = node } else { Task { await model.trash(node) } }
    }

    private func copyPath(_ node: ExplorerNode, relative: Bool) {
        guard let url = model.url(node) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(relative ? node.path : url.path, forType: .string)
    }

    private func findInFolder(_ path: String) {
        guard let root = model.hostRoot else { return }
        FileSearchRequests.shared.pending = .init(root: root, scope: path)
        storedPanel = RightSidebarPanel.search.rawValue
    }

    private func handleDrop(_ providers: [NSItemProvider], into directory: String) -> Bool {
        guard writable else { return false }
        let group = DispatchGroup()
        let collected = DropCollector()
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { collected.add(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let urls = collected.urls
            Task { @MainActor in model.dropTarget = nil; await model.drop(urls, into: directory) }
        }
        return true
    }
}

private final class DropCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [URL] = []
    func add(_ url: URL) { lock.withLock { list.append(url) } }
    var urls: [URL] { lock.withLock { list } }
}

/// Tracks whether the last click in the window landed inside the Explorer (scopes ⌘Z etc.).
@MainActor @Observable
final class ExplorerFocusMonitor {
    var active = false
    @ObservationIgnored var frame: CGRect = .zero
    @ObservationIgnored private var mouse: Any?
    @ObservationIgnored private var keys: Any?

    func install(_ handler: @escaping @MainActor (KeybindingAction) -> Bool) {
        guard mouse == nil else { return }
        mouse = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let height = event.window?.contentView?.bounds.height else { return }
                let point = CGPoint(x: event.locationInWindow.x, y: height - event.locationInWindow.y)
                let inside = self.frame.contains(point)
                if inside != self.active { self.active = inside }
            }
            return event
        }
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, self.active, !(event.window?.firstResponder is NSTextView),
                      let chord = SmthzKeybindings.chord(event) else { return false }
                let registry = SmthzKeybindings.shared.registry
                let actions: [KeybindingAction] = [.fileExplorerUndo, .fileExplorerRedo, .fileExplorerDelete,
                                                   .fileExplorerCopyPath, .fileExplorerCopyRelativePath]
                return actions.contains { registry.chords(for: $0).contains(chord) && handler($0) }
            }
            return handled ? nil : event
        }
    }

    func remove() {
        if let mouse { NSEvent.removeMonitor(mouse) }
        if let keys { NSEvent.removeMonitor(keys) }
        mouse = nil; keys = nil
        active = false
    }
}

private struct ExplorerRow: View {
    let node: ExplorerNode
    let isExpanded: Bool
    let isSelected: Bool
    let isDropTarget: Bool
    let mark: ExplorerModel.GitMark?
    let isIgnored: Bool
    let action: () -> Void
    let open: () -> Void
    @State private var hovering = false

    private var nameColor: Color {
        switch mark {
        case .untracked?, .added?: Color(red: 0.29, green: 0.69, blue: 0.38)
        case .modified?, .renamed?: Color(red: 0.86, green: 0.62, blue: 0.20)
        case .deleted?, .conflict?: Color(red: 0.86, green: 0.30, blue: 0.30)
        case nil: SmthzTheme.foreground
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                SmthzIcon.view(.chevronRight, size: 12)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .opacity(node.isDirectory ? 1 : 0)
                SmthzIcon.view(node.isDirectory ? (isExpanded ? .folderOpen : .folder) : "file-text", size: 12)
                Text(node.name).font(SmthzFont.ui(size: 12)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(nameColor)
                if node.isSymlink { SmthzIcon.view(.arrowRight, size: 10).foregroundStyle(SmthzTheme.mutedForeground) }
                Spacer(minLength: 0)
                if let mark, !node.isDirectory {
                    Text(Self.letter(mark)).font(SmthzFont.ui(size: 10, weight: .medium)).foregroundStyle(nameColor)
                }
            }
            .foregroundStyle(SmthzTheme.foreground)
            .opacity(isIgnored ? 0.5 : 1)
            .padding(.leading, CGFloat(node.depth) * 16 + 4).padding(.trailing, 4)
            .frame(height: 24)
            .background(isSelected || isDropTarget ? SmthzTheme.accent : hovering ? SmthzTheme.accent.opacity(0.5) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded { open() })
        .onHover { hovering = $0 }
        .accessibilityLabel(node.name)
    }

    static func letter(_ mark: ExplorerModel.GitMark) -> String {
        switch mark {
        case .untracked: "U"
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .conflict: "!"
        case .renamed: "R"
        }
    }
}

/// Inline name field for New File / New Folder / Rename (Enter commits, Escape cancels).
private struct ExplorerEditRow: View {
    let depth: Int
    let isDirectory: Bool
    @Binding var text: String
    let commit: () -> Void
    let cancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            SmthzIcon.view(.chevronRight, size: 12).opacity(0)
            SmthzIcon.view(isDirectory ? .folder : "file-text", size: 12)
            TextField(isDirectory ? "Folder name" : "File name", text: $text)
                .textFieldStyle(.plain).font(SmthzFont.ui(size: 12))
                .focused($focused)
                .onSubmit(commit)
                .onExitCommand(perform: cancel)
                .accessibilityLabel(isDirectory ? "New folder name" : "File name")
        }
        .padding(.leading, CGFloat(depth) * 16 + 4).padding(.trailing, 4)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(SmthzTheme.ring))
        .onAppear { focused = true }
        .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
    }
}

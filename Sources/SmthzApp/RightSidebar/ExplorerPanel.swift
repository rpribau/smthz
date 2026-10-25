import SwiftUI

/// One visible row of the Explorer tree.
struct ExplorerNode: Identifiable, Equatable {
    let url: URL
    let depth: Int
    let isDirectory: Bool
    let isSymlink: Bool
    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

@MainActor @Observable
final class ExplorerModel {
    var root: URL?
    var expanded: Set<String> = []
    var nodes: [ExplorerNode] = []
    var showDotfiles = false
    var showGitIgnored = false
    var filter = ""
    var errorMessage: String?
    var selection: String?

    private static let filterLimit = 500

    func load(root: URL?) {
        if self.root != root { expanded = []; selection = nil }
        self.root = root
        reload()
    }

    func reload() {
        errorMessage = nil
        guard let root else { nodes = []; return }
        if !filter.isEmpty { nodes = filtered(root: root); return }
        var out: [ExplorerNode] = []
        do { try append(children: root, depth: 0, into: &out) } catch {
            errorMessage = error.localizedDescription
        }
        nodes = out
    }

    func toggle(_ node: ExplorerNode) {
        guard node.isDirectory else { selection = node.id; return }
        if expanded.contains(node.id) { expanded.remove(node.id) } else { expanded.insert(node.id) }
        reload()
    }

    func collapseAll() { expanded = []; reload() }

    private func entries(of directory: URL) throws -> [ExplorerNode] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys,
            options: showDotfiles ? [] : [.skipsHiddenFiles])
        return urls.compactMap { url -> ExplorerNode? in
            if url.lastPathComponent == ".git" { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            return ExplorerNode(url: url, depth: 0, isDirectory: values?.isDirectory ?? false,
                                isSymlink: values?.isSymbolicLink ?? false)
        }
        .sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private func append(children directory: URL, depth: Int, into out: inout [ExplorerNode]) throws {
        for entry in try entries(of: directory) {
            let node = ExplorerNode(url: entry.url, depth: depth, isDirectory: entry.isDirectory,
                                    isSymlink: entry.isSymlink)
            out.append(node)
            if node.isDirectory, expanded.contains(node.id) {
                try? append(children: node.url, depth: depth + 1, into: &out)
            }
        }
    }

    private func filtered(root: URL) -> [ExplorerNode] {
        var out: [ExplorerNode] = []
        var queue = [root]
        while !queue.isEmpty, out.count < Self.filterLimit {
            let dir = queue.removeFirst()
            guard let list = try? entries(of: dir) else { continue }
            for entry in list {
                if entry.name.localizedCaseInsensitiveContains(filter) {
                    out.append(ExplorerNode(url: entry.url, depth: 0, isDirectory: entry.isDirectory,
                                            isSymlink: entry.isSymlink))
                }
                if entry.isDirectory, !entry.isSymlink { queue.append(entry.url) }
            }
        }
        return out
    }
}

struct ExplorerPanel: View {
    /// Workspace root (the active session's cwd); nil means no workspace.
    let rootURL: URL?
    var isGitRepository = false
    @State private var model = ExplorerModel()
    @State private var searchMode = 0  // 0 = Names, 1 = Contents
    @State private var contentsQuery = ""

    var body: some View {
        VStack(spacing: 0) {
            if rootURL == nil {
                PanelEmptyState(icon: .files, title: "Select a workspace to browse files", detail: nil)
            } else {
                header
                if searchMode == 0 { nameFilter } else { contentsSearch }
                content
            }
        }
        .task(id: rootURL) { model.load(root: rootURL) }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                HStack(spacing: 4) {
                    SmthzIcon.view(.folderTree, size: 12)
                    Text(isGitRepository ? "Repository root" : "Explorer root")
                        .font(SmthzFont.ui(size: 12, weight: .medium)).lineLimit(1)
                    SmthzIcon.view(.chevronDown, size: 12)
                }
                .foregroundStyle(SmthzTheme.foreground)
                .padding(.horizontal, 6).frame(height: 24)
                .help(rootURL?.path ?? "")
                Spacer(minLength: 0)
                PanelIconButton(icon: "list-collapse", label: "Collapse All") { model.collapseAll() }
                PanelIconButton(icon: "refresh-cw", label: "Refresh Explorer") { model.reload() }
                Menu {
                    Toggle("Show Dotfiles", isOn: Binding(get: { model.showDotfiles },
                                                          set: { model.showDotfiles = $0; model.reload() }))
                    // VISUAL-ONLY: stub data until a git-ignore query exists in the host
                    Toggle("Show Git Ignored Files", isOn: $model.showGitIgnored)
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
            get: { model.filter }, set: { model.filter = $0; model.reload() }), clearLabel: "Clear file filter")
            .padding(.horizontal, 8).padding(.bottom, 6)
    }

    private var contentsSearch: some View {
        PanelSearchField(icon: "search", prompt: "Search files", text: $contentsQuery, clearLabel: "Clear search")
            .padding(.horizontal, 8).padding(.bottom, 6)
    }

    // MARK: Body

    @ViewBuilder private var content: some View {
        if searchMode == 1 {
            // VISUAL-ONLY: stub data until a content-search (rg) host service exists
            Text(contentsQuery.isEmpty ? "Type to search in files" : "Press Enter to search")
                .font(SmthzFont.ui(size: 12)).foregroundStyle(SmthzTheme.mutedForeground)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.errorMessage {
            Text("Could not load files for this workspace: \(error)")
                .font(SmthzFont.ui(size: 12)).foregroundStyle(SmthzTheme.mutedForeground)
                .multilineTextAlignment(.center).padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.nodes.isEmpty {
            Text(model.filter.isEmpty ? "No files in this workspace" : "No files in this folder")
                .font(SmthzFont.ui(size: 12)).foregroundStyle(SmthzTheme.mutedForeground)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.nodes) { node in
                        ExplorerRow(node: node, isExpanded: model.expanded.contains(node.id),
                                    isSelected: model.selection == node.id) { model.toggle(node) }
                    }
                }
                .padding(.horizontal, 6)
            }
        }
    }
}

private struct ExplorerRow: View {
    let node: ExplorerNode
    let isExpanded: Bool
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                SmthzIcon.view(.chevronRight, size: 12)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .opacity(node.isDirectory ? 1 : 0)
                SmthzIcon.view(node.isDirectory ? (isExpanded ? .folderOpen : .folder) : "file-text", size: 12)
                Text(node.name).font(SmthzFont.ui(size: 12)).lineLimit(1).truncationMode(.middle)
                if node.isSymlink { SmthzIcon.view(.arrowRight, size: 10).foregroundStyle(SmthzTheme.mutedForeground) }
                Spacer(minLength: 0)
            }
            .foregroundStyle(SmthzTheme.foreground)
            .padding(.leading, CGFloat(node.depth) * 16 + 4).padding(.trailing, 4)
            .frame(height: 24)
            .background(isSelected ? SmthzTheme.accent : hovering ? SmthzTheme.accent.opacity(0.5) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(node.name)
    }
}

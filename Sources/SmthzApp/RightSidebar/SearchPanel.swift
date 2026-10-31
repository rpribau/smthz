import AppKit
import SmthzCore
import SwiftUI

/// Folder search state (M4-PLAN §10.1): one host `fs.search` job at a time; a new query cancels
/// the previous job (`job.cancel`, Orca `fs:cancelSearch`).
@MainActor @Observable
final class SearchModel {
    enum State: Equatable { case idle, searching, done, failed(String) }
    var query = ""
    var caseSensitive = false
    var wholeWord = false
    var useRegex = false
    var includePattern = ""
    var excludePattern = ""
    var showGlobs = false
    /// Root-relative folder from Explorer "Find in Folder"; empty = whole root.
    var scope = ""
    private(set) var state: State = .idle
    private(set) var files: [HostSearchFile] = []
    private(set) var totalMatches = 0
    private(set) var truncated = false
    private(set) var engine = ""
    var collapsed: Set<String> = []
    private(set) var root: String?
    private var jobID: String?
    private var generation = 0

    func setRoot(_ root: String?) {
        guard root != self.root else { return }
        self.root = root; scope = ""
        Task { await cancelRunning() }
        files = []; totalMatches = 0; state = .idle
    }

    /// Debounced: the caller's task is cancelled by the next keystroke.
    func search(debounce: Bool) async {
        generation += 1
        let mine = generation
        if debounce { try? await Task.sleep(for: .milliseconds(300)) }
        guard mine == generation, !Task.isCancelled else { return }
        await cancelRunning()
        guard let root, !query.isEmpty else { files = []; totalMatches = 0; truncated = false; state = .idle; return }
        var request = HostSearchRequest(root: root, query: query)
        request.caseSensitive = caseSensitive; request.wholeWord = wholeWord; request.useRegex = useRegex
        request.includePattern = includePattern; request.excludePattern = excludePattern; request.scope = scope
        state = .searching
        let job = request
        do {
            let id = try await FilesHost.run { try $0.fsStartSearch(job) }
            guard mine == generation else { _ = try? await FilesHost.run { try $0.fsCancelJob(id) }; return }
            jobID = id
            let result = try await FilesHost.run { try $0.fsSearchResult(jobID: id) }
            guard mine == generation else { return }
            jobID = nil
            files = result.files; totalMatches = result.totalMatches; truncated = result.truncated; engine = result.engine
            state = .done
        } catch {
            guard mine == generation else { return }
            jobID = nil
            if case HostClientError.detailedHostError(let code, _) = error, code == "cancelled" { return }
            state = .failed(FilesHost.describe(error))
        }
    }

    func cancelRunning() async {
        guard let id = jobID else { return }
        jobID = nil
        _ = try? await FilesHost.run { try $0.fsCancelJob(id) }
    }

    func clear() {
        generation += 1
        Task { await cancelRunning() }
        query = ""; files = []; totalMatches = 0; truncated = false; state = .idle
    }
}

/// Right-sidebar Search (⌘⇧F, Orca `sidebar.search.toggle`); also embedded as the Explorer's
/// Contents mode. Clicking a match opens it the interim way (M4-D8) until the editor exists.
struct SearchPanel: View {
    let rootURL: URL?
    var embedded = false
    @State private var model = SearchModel()
    @State private var accepted: Bool?
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if rootURL == nil {
                PanelEmptyState(icon: .search, title: "Select a workspace to search files", detail: nil)
            } else if accepted == false {
                PanelEmptyState(icon: .search, title: "Search is not available for this folder",
                                detail: "Add the folder as a project (or start the host) to search its files.")
            } else {
                if !embedded { header }
                fields
                results
            }
        }
        .task(id: rootURL) { await resolveRoot() }
        .onChange(of: FileSearchRequests.shared.pending) { _, request in apply(request) }
        .onAppear { queryFocused = !embedded; apply(FileSearchRequests.shared.pending) }
    }

    private func resolveRoot() async {
        guard let rootURL else { model.setRoot(nil); accepted = nil; return }
        let path = rootURL.path
        accepted = (try? await FilesHost.run { try $0.fsSearchEngine(root: path) }) != nil
        model.setRoot(accepted == true ? path : nil)
        apply(FileSearchRequests.shared.pending)
    }

    private func apply(_ request: FileSearchRequests.Request?) {
        guard let request, request.root == model.root, !embedded else { return }
        FileSearchRequests.shared.pending = nil
        model.scope = request.scope
        queryFocused = true
        if !model.query.isEmpty { Task { await model.search(debounce: false) } }
    }

    private var header: some View {
        HStack {
            Text("Search").font(SmthzFont.ui(size: 12, weight: .medium)).foregroundStyle(SmthzTheme.foreground)
            Spacer(minLength: 0)
            PanelIconButton(icon: "refresh-cw", label: "Refresh Results", enabled: !model.query.isEmpty) {
                Task { await model.search(debounce: false) }
            }
            PanelIconButton(icon: "list-collapse", label: "Collapse All", enabled: !model.files.isEmpty) {
                model.collapsed = Set(model.files.map(\.path))
            }
            PanelIconButton(icon: "list-x", label: "Clear Search Results", enabled: !model.query.isEmpty) { model.clear() }
        }
        .padding(.horizontal, 8).frame(height: 32)
    }

    private var fields: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Button { model.showGlobs.toggle() } label: {
                    SmthzIcon.view(.chevronRight, size: 12).rotationEffect(.degrees(model.showGlobs ? 90 : 0))
                        .foregroundStyle(SmthzTheme.mutedForeground).frame(width: 16, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Toggle Search Details").accessibilityLabel("Toggle Search Details")
                HStack(spacing: 4) {
                    TextField("Search", text: $model.query)
                        .textFieldStyle(.plain).font(SmthzFont.ui(size: 12))
                        .focused($queryFocused)
                        .onSubmit { Task { await model.search(debounce: false) } }
                        .accessibilityLabel("Search files")
                    toggle("case-sensitive", "Match Case", $model.caseSensitive)
                    wordToggle
                    toggle("regex", "Use Regular Expression", $model.useRegex)
                }
                .padding(.leading, 8).padding(.trailing, 2).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 6).strokeBorder(queryFocused ? SmthzTheme.ring : SmthzTheme.input))
            }
            if !model.scope.isEmpty {
                HStack(spacing: 4) {
                    SmthzIcon.view(.folder, size: 11)
                    Text("In \(model.scope)").font(SmthzFont.ui(size: 11)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button { model.scope = ""; rerun() } label: { SmthzIcon.view(.x, size: 10) }
                        .buttonStyle(.plain).help("Search the whole workspace").accessibilityLabel("Clear folder scope")
                }
                .foregroundStyle(SmthzTheme.mutedForeground).padding(.leading, 20)
            }
            if model.showGlobs {
                globField("files to include", $model.includePattern).padding(.leading, 20)
                globField("files to exclude", $model.excludePattern).padding(.leading, 20)
            }
        }
        .padding(.horizontal, 8).padding(.bottom, 6)
        .onChange(of: model.query) { rerun(debounce: true) }
        .onChange(of: model.caseSensitive) { rerun() }
        .onChange(of: model.wholeWord) { rerun() }
        .onChange(of: model.useRegex) { rerun() }
    }

    @State private var pending: Task<Void, Never>?
    private func rerun(debounce: Bool = false) {
        pending?.cancel()
        pending = Task { await model.search(debounce: debounce) }
    }

    private func toggle(_ icon: SmthzIcon.Name, _ label: String, _ value: Binding<Bool>) -> some View {
        Button { value.wrappedValue.toggle() } label: {
            SmthzIcon.view(icon, size: 13)
                .foregroundStyle(value.wrappedValue ? SmthzTheme.foreground : SmthzTheme.mutedForeground)
                .frame(width: 22, height: 22)
                .background(value.wrappedValue ? SmthzTheme.accent : .clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label)
        .accessibilityAddTraits(value.wrappedValue ? .isSelected : [])
    }

    private var wordToggle: some View {
        Button { model.wholeWord.toggle() } label: {
            Text("ab").font(SmthzFont.ui(size: 11, weight: .medium)).underline()
                .foregroundStyle(model.wholeWord ? SmthzTheme.foreground : SmthzTheme.mutedForeground)
                .frame(width: 22, height: 22)
                .background(model.wholeWord ? SmthzTheme.accent : .clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help("Match Whole Word").accessibilityLabel("Match Whole Word")
        .accessibilityAddTraits(model.wholeWord ? .isSelected : [])
    }

    private func globField(_ prompt: String, _ text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            .textFieldStyle(.plain).font(SmthzFont.ui(size: 12))
            .onSubmit { rerun() }
            .padding(.horizontal, 8).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6).strokeBorder(SmthzTheme.input))
            .accessibilityLabel(prompt)
    }

    // MARK: Results

    @ViewBuilder private var results: some View {
        switch model.state {
        case .idle:
            note(model.query.isEmpty ? "Type to search in files" : "Press Enter to search")
        case .searching where model.files.isEmpty:
            note("Searching…")
        case .failed(let message):
            note("Search failed: \(message)")
        default:
            if model.files.isEmpty {
                note("No results found")
            } else {
                summary
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.files, id: \.path) { file in fileRows(file) }
                    }
                    .padding(.horizontal, 6).padding(.bottom, 8)
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(SmthzFont.ui(size: 12)).foregroundStyle(SmthzTheme.mutedForeground)
            .multilineTextAlignment(.center).padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(model.totalMatches) result\(model.totalMatches == 1 ? "" : "s") in \(model.files.count) file\(model.files.count == 1 ? "" : "s")"
                 + (model.truncated ? " (results limited; refine the search)" : ""))
            // INTERIM (M4-D8): no editor yet.
            Text("Click opens documents with their default app; executables are revealed in Finder.")
        }
        .font(SmthzFont.ui(size: 11)).foregroundStyle(SmthzTheme.mutedForeground)
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 4)
        .help(model.engine.isEmpty ? "" : "Search engine: \(model.engine)")
    }

    @ViewBuilder private func fileRows(_ file: HostSearchFile) -> some View {
        let open = !model.collapsed.contains(file.path)
        Button {
            if open { model.collapsed.insert(file.path) } else { model.collapsed.remove(file.path) }
        } label: {
            HStack(spacing: 4) {
                SmthzIcon.view(.chevronRight, size: 12).rotationEffect(.degrees(open ? 90 : 0))
                SmthzIcon.view("file-text", size: 12)
                Text((file.path as NSString).lastPathComponent).font(SmthzFont.ui(size: 12, weight: .medium)).lineLimit(1)
                Text((file.path as NSString).deletingLastPathComponent).font(SmthzFont.ui(size: 11))
                    .foregroundStyle(SmthzTheme.mutedForeground).lineLimit(1).truncationMode(.head)
                Spacer(minLength: 0)
                Text("\(file.matches.count)").font(SmthzFont.ui(size: 10, weight: .medium))
                    .padding(.horizontal, 5).background(SmthzTheme.muted, in: Capsule())
            }
            .foregroundStyle(SmthzTheme.foreground).frame(height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Reveal in Finder") { if let url = url(file) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
            Button("Copy Path") { copy(url(file)?.path) }
            Button("Copy Relative Path") { copy(file.path) }
        }
        if open {
            ForEach(Array(file.matches.enumerated()), id: \.offset) { _, match in
                SearchMatchRow(match: match) { if let url = url(file) { InterimFileOpener.open(url) } }
            }
        }
    }

    private func url(_ file: HostSearchFile) -> URL? { model.root.map { URL(fileURLWithPath: $0).appendingPathComponent(file.path) } }
    private func copy(_ text: String?) {
        guard let text else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct SearchMatchRow: View {
    let match: HostSearchMatch
    let action: () -> Void
    @State private var hovering = false

    private var text: AttributedString {
        let line = match.lineContent
        let units = Array(line.utf16)
        let start = (match.displayColumn ?? match.column) - 1
        let length = match.displayMatchLength ?? match.matchLength
        guard start >= 0, start + length <= units.count else { return AttributedString(line) }
        let leading = String(decoding: units[..<start], as: UTF16.self)
        let hit = String(decoding: units[start..<(start + length)], as: UTF16.self)
        let trailing = String(decoding: units[(start + length)...], as: UTF16.self)
        // Keep some context before the match when the line is long.
        let context = leading.count > 30 ? "…" + String(leading.suffix(30)) : leading
        var result = AttributedString(String(context.drop { $0 == " " || $0 == "\t" }))
        var marked = AttributedString(hit)
        marked.backgroundColor = Color.yellow.opacity(0.35)
        result += marked
        result += AttributedString(trailing)
        return result
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(text).font(SmthzFont.ui(size: 12)).lineLimit(1).foregroundStyle(SmthzTheme.foreground)
                Spacer(minLength: 0)
                Text("\(match.line)").font(SmthzFont.ui(size: 10)).foregroundStyle(SmthzTheme.mutedForeground)
            }
            .padding(.leading, 36).padding(.trailing, 6).frame(height: 22)
            .background(hovering ? SmthzTheme.accent.opacity(0.5) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Line \(match.line), column \(match.column)")
        .accessibilityLabel("Line \(match.line): \(match.lineContent)")
    }
}

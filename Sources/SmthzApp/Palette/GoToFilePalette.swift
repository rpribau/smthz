import AppKit
import Foundation
import SmthzCore
import SwiftUI
import UniformTypeIdentifiers

/// INTERIM (M4-D8) until the editor (M4-EDITOR) exists: files opened from Go to File, Search or
/// the Explorer are revealed in Finder when they are executables, scripts, apps or bundles, and
/// opened with their default app only when they are documents.
enum InterimFileOpener {
    enum Action: Equatable { case openWithDefaultApp, revealInFinder }

    static func action(for url: URL) -> Action {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .contentTypeKey, .isExecutableKey])
        if values?.isDirectory == true || values?.isPackage == true { return .revealInFinder }
        if values?.isExecutable == true { return .revealInFinder }
        let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
        guard let type else { return .revealInFinder }
        let risky: [UTType] = [.executable, .script, .shellScript, .application, .applicationBundle, .bundle, .package,
                               .unixExecutable, .appleScript, .osaScript, .diskImage]
        if risky.contains(where: { type.conforms(to: $0) }) || ["command", "tool", "workflow", "terminal", "pkg", "mpkg"].contains(url.pathExtension.lowercased()) {
            return .revealInFinder
        }
        let documents: [UTType] = [.text, .image, .pdf, .audiovisualContent, .presentation, .spreadsheet, .rtf, .html,
                                   .json, .xml, .propertyList, .yaml, .font]
        return documents.contains(where: { type.conforms(to: $0) }) ? .openWithDefaultApp : .revealInFinder
    }

    @MainActor static func open(_ url: URL) {
        switch action(for: url) {
        case .openWithDefaultApp: NSWorkspace.shared.open(url)
        case .revealInFinder: NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

/// Go to File (⌘P, M4-PLAN §10.2): host `fs.listFiles` (tracked, then gitignored) for accepted
/// roots, the bounded local scan otherwise; ranked by recency then fuzzy score.
struct SmthzGoToFilePalette: View {
    let root: URL?
    let onOpen: (URL) -> Void
    let onDismiss: () -> Void
    @State private var query = ""
    @State private var files: [SmthzPaletteFile] = []
    @State private var listRoot: URL?
    @State private var selectedID: String?
    @State private var isLoading = true
    @State private var truncated = false
    @State private var failure: String?
    @State private var recent: [String] = []
    @FocusState private var searchFocused: Bool

    private var matches: [SmthzPaletteFile] { SmthzPaletteFile.rank(files, query: query, recent: recent) }
    private var visible: [SmthzPaletteFile] { Array(matches.prefix(200)) }
    private var selection: SmthzPaletteFile? { visible.first { $0.id == selectedID } ?? visible.first }

    var body: some View {
        SmthzPaletteSurface(title: "Go to file", onDismiss: onDismiss) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    SmthzIcon.image(.search).frame(width: 16, height: 16).opacity(0.6)
                    TextField("Go to file...", text: $query)
                        .accessibilityLabel("Search for a file to open")
                        .textFieldStyle(.plain).font(SmthzFont.ui(size: 14))
                        .focused($searchFocused).onSubmit(openSelection)
                }.padding(.horizontal, 14).frame(height: 48)
                    .background(SmthzTheme.muted.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SmthzTheme.border.opacity(0.55)))
                    .padding(12)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            if isLoading {
                                SmthzPaletteState(title: "Loading files...", loading: true)
                            } else if let failure {
                                SmthzPaletteState(title: "Unable to load files", subtitle: failure)
                            } else if root == nil {
                                SmthzPaletteState(title: "No workspace selected", subtitle: "Select a workspace to browse files.")
                            } else if visible.isEmpty {
                                SmthzPaletteState(title: "No matching files.")
                            } else {
                                ForEach(visible) { file in
                                    SmthzPaletteRow(title: file.name, subtitle: file.parent + (file.ignored ? "  · ignored" : ""),
                                                   icon: .init(rawValue: "file-text"), selected: selection?.id == file.id) {
                                        open(file)
                                    }.id(file.id)
                                        .onHover { if $0 { selectedID = file.id } }
                                }
                            }
                        }.padding(.horizontal, 10).padding(.bottom, 10)
                    }.frame(maxHeight: 480)
                        .onChange(of: selectedID) { _, value in
                            if let value { proxy.scrollTo(value, anchor: .center) }
                        }
                }
                if !isLoading && failure == nil && root != nil {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(matches.count) files found")
                        if truncated || matches.count > visible.count {
                            Text("More matches may be available. Refine your search to narrow the results.")
                        }
                        // INTERIM (M4-D8): no editor yet.
                        Text("Opens documents with their default app; executables and bundles are revealed in Finder.")
                    }.font(SmthzFont.ui(size: 11)).foregroundStyle(SmthzTheme.mutedForeground)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.bottom, 10)
                }
                SmthzPaletteFooter()
            }
        }
        .onAppear { searchFocused = true }
        .task(id: root) { await load() }
        .onChange(of: query) { selectedID = visible.first?.id }
        .onMoveCommand { direction in
            if direction == .down { move(1) }
            if direction == .up { move(-1) }
        }
    }

    private func move(_ offset: Int) {
        let rows = visible
        guard !rows.isEmpty else { return }
        let index = rows.firstIndex { $0.id == selection?.id } ?? 0
        selectedID = rows[(index + offset + rows.count) % rows.count].id
    }
    private func openSelection() {
        guard let file = selection, !isLoading else { return }
        open(file)
    }
    private func open(_ file: SmthzPaletteFile) {
        if let listRoot { SmthzPaletteFile.remember(file.path, root: listRoot) }
        onDismiss(); onOpen(file.url)
    }
    private func load() async {
        files = []; failure = nil; truncated = false; isLoading = true
        guard let root else { isLoading = false; return }
        let socket = HostController.socketPath
        let result = await Task.detached(priority: .userInitiated) { await SmthzPaletteFile.load(root: root, socket: socket) }.value
        guard !Task.isCancelled else { return }
        files = result.files; truncated = result.truncated; failure = result.error; listRoot = result.root
        recent = result.root.map(SmthzPaletteFile.recent) ?? []
        selectedID = visible.first?.id; isLoading = false
    }
}

private struct SmthzPaletteFile: Identifiable, Sendable {
    let url: URL
    let path: String
    var ignored = false
    var id: String { url.path }
    var name: String { (path as NSString).lastPathComponent }
    var parent: String { (path as NSString).deletingLastPathComponent }

    struct Scan: Sendable {
        var files: [SmthzPaletteFile] = []
        var truncated = false
        var error: String?
        var root: URL?
    }

    /// Host listing for the Git top level (or registered folder); local scan if the host refuses the root.
    static func load(root: URL, socket: String) async -> Scan {
        let repository = (try? await GitService().repository(at: root)) ?? nil
        let top = repository.flatMap { $0.isBare ? nil : $0.root }
        let base = top ?? root
        if let client = try? HostClient(socketPath: socket) {
            defer { client.disconnect() }
            if let listing = try? client.fsListFiles(root: base.path) {
                let make = { (path: String, ignored: Bool) in SmthzPaletteFile(url: base.appendingPathComponent(path), path: path, ignored: ignored) }
                return Scan(files: listing.tracked.map { make($0, false) } + listing.ignored.map { make($0, true) },
                            truncated: listing.truncated, root: base)
            }
        }
        var scan = Self.scan(root: root)
        scan.root = root
        return scan
    }

    // MARK: Ranking

    /// Recent files first (most recent first), then fuzzy score; gitignored files rank below tracked ones.
    static func rank(_ files: [SmthzPaletteFile], query: String, recent: [String]) -> [SmthzPaletteFile] {
        let recency = Dictionary(recent.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        if words.isEmpty {
            let recentFiles = files.filter { recency[$0.path] != nil }.sorted { recency[$0.path]! < recency[$1.path]! }
            return recentFiles + files.filter { recency[$0.path] == nil }
        }
        var scored: [(SmthzPaletteFile, Int)] = []
        for file in files {
            var total = 0
            var matched = true
            for word in words {
                guard let s = score(word, in: file) else { matched = false; break }
                total += s
            }
            guard matched else { continue }
            if let r = recency[file.path] { total += 400 - min(r, 50) * 4 }
            if file.ignored { total -= 200 }
            scored.append((file, total))
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.path.count < $1.0.path.count }.map(\.0)
    }

    /// Subsequence match over the path; bonuses for filename hits, prefixes and consecutive runs.
    static func score(_ word: String, in file: SmthzPaletteFile) -> Int? {
        let name = file.name.lowercased(), path = file.path.lowercased()
        if name == word { return 1_000 }
        if name.hasPrefix(word) { return 800 - name.count }
        if name.contains(word) { return 600 - name.count }
        if path.contains(word) { return 400 - path.count / 4 }
        var score = 0, run = 0
        var index = path.startIndex
        for ch in word {
            guard let found = path[index...].firstIndex(of: ch) else { return nil }
            run = found == index ? run + 1 : 0
            score += 1 + run * 3
            index = path.index(after: found)
        }
        return score
    }

    private static func recentKey(_ root: URL) -> String { "goToFile.recent." + root.path }
    static func recent(_ root: URL) -> [String] { UserDefaults.standard.stringArray(forKey: recentKey(root)) ?? [] }
    static func remember(_ path: String, root: URL) {
        var list = recent(root).filter { $0 != path }
        list.insert(path, at: 0)
        UserDefaults.standard.set(Array(list.prefix(50)), forKey: recentKey(root))
    }

    /// Fallback without a host or for refused roots: two-second / 10,000-entry ceiling; skips hidden
    /// files, packages, and symlink directories.
    static func scan(root: URL) -> Scan {
        let manager = FileManager.default
        let root = root.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return Scan(error: "The workspace folder is no longer available.")
        }
        guard manager.isReadableFile(atPath: root.path) else {
            return Scan(error: "The workspace folder could not be read.")
        }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let iterator = manager.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                                               options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return Scan(error: "The workspace folder could not be read.")
        }
        var result = Scan()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        var inspected = 0
        for case let url as URL in iterator {
            if inspected >= 10_000 || ContinuousClock.now >= deadline {
                result.truncated = true; break
            }
            inspected += 1
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            if values.isSymbolicLink == true { iterator.skipDescendants(); continue }
            if values.isDirectory == true {
                if ["node_modules", ".git", ".build", "build", "DerivedData"].contains(url.lastPathComponent) {
                    iterator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true else { continue }
            let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
            let path = String(url.path.dropFirst(prefix.count))
            result.files.append(Self(url: url, path: path))
        }
        result.files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return result
    }
}

#Preview("Go to file") {
    SmthzGoToFilePalette(root: nil, onOpen: { _ in }, onDismiss: {})
        .frame(width: 1100, height: 800)
}

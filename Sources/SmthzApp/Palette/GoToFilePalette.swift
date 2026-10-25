import Foundation
import SwiftUI

/// File opening is delegated to UI-29; this view never launches an external app.
struct SmthzGoToFilePalette: View {
    let root: URL?
    let onOpen: (URL) -> Void
    let onDismiss: () -> Void
    @State private var query = ""
    @State private var files: [SmthzPaletteFile] = []
    @State private var selectedID: String?
    @State private var isLoading = true
    @State private var truncated = false
    @State private var failure: String?
    @FocusState private var searchFocused: Bool

    private var matches: [SmthzPaletteFile] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return files.filter { file in words.allSatisfy { file.path.localizedCaseInsensitiveContains($0) } }
    }
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
                                    SmthzPaletteRow(title: file.url.lastPathComponent, subtitle: file.path,
                                                   icon: .init(rawValue: "file-text"), selected: selection?.id == file.id) {
                                        onDismiss(); onOpen(file.url)
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
        onDismiss(); onOpen(file.url)
    }
    private func load() async {
        files = []; failure = nil; truncated = false; isLoading = true
        guard let root else { isLoading = false; return }
        let result = await Task.detached(priority: .userInitiated) { SmthzPaletteFile.scan(root: root) }.value
        guard !Task.isCancelled else { return }
        files = result.files; truncated = result.truncated; failure = result.error
        selectedID = visible.first?.id; isLoading = false
    }
}

private struct SmthzPaletteFile: Identifiable, Sendable {
    let url: URL
    let path: String
    var id: String { url.path }

    struct Scan: Sendable {
        var files: [SmthzPaletteFile] = []
        var truncated = false
        var error: String?
    }

    /// Two-second / 10,000-entry ceiling; skips hidden files, packages, and symlink directories.
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

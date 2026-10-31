import SwiftUI
import SmthzCore

/// Nested repository import (Orca `projectGroups:importNested`): pick the repositories found under
/// a folder and add them as one project group or as separate projects.
struct SmthzNestedImportView: View {
    let parent: String
    let scan: WorkspaceCatalogModel.ScanResult
    let catalog: WorkspaceCatalogModel
    let onBack: () -> Void
    let onImported: (WorkspaceKey?) -> Void
    let onAddFolderOnly: () -> Void
    @State private var selected: Set<String> = []
    @State private var asGroup = true
    @State private var busy = false
    @State private var failures: [String: String] = [:]
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(scan.repos.count) repositories found in \((parent as NSString).lastPathComponent)"
                 + (scan.truncated ? " (limit reached)" : "") + (scan.timedOut ? " (scan timed out)" : ""))
                .font(SmthzFont.ui(size: 13, weight: .medium))
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(scan.repos, id: \.path) { repo in
                        Toggle(isOn: Binding(get: { selected.contains(repo.path) },
                                             set: { if $0 { selected.insert(repo.path) } else { selected.remove(repo.path) } })) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(repo.name).font(SmthzFont.ui(size: 13))
                                Text(relative(repo.path)).font(SmthzFont.mono(size: 11)).foregroundStyle(SmthzTheme.mutedForeground)
                                if let failure = failures[repo.path] {
                                    Text(failure).font(SmthzFont.ui(size: 11)).foregroundStyle(SmthzTheme.destructive)
                                }
                            }
                        }
                        .toggleStyle(.checkbox).padding(.vertical, 4).padding(.horizontal, 8)
                    }
                }
            }
            .frame(maxHeight: 220)
            .background(SmthzTheme.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SmthzTheme.input))
            Picker("", selection: $asGroup) {
                Text("Import as a project group").tag(true)
                Text("Add as separate projects").tag(false)
            }
            .pickerStyle(.radioGroup).labelsHidden().font(SmthzFont.ui(size: 13))
            if let error { Text(error).font(SmthzFont.ui(size: 12)).foregroundStyle(SmthzTheme.destructive) }
            HStack(spacing: 8) {
                Button("Back", action: onBack).buttonStyle(SmthzButtonStyle(.outline)).disabled(busy)
                Button("Add folder only", action: onAddFolderOnly).buttonStyle(SmthzButtonStyle(.outline)).disabled(busy)
                    .help("Add \((parent as NSString).lastPathComponent) as one folder project")
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Import \(selected.count)", action: importSelected).buttonStyle(SmthzButtonStyle())
                    .disabled(busy || selected.isEmpty).keyboardShortcut(.return, modifiers: [])
            }
        }
        .onAppear { selected = Set(scan.repos.map(\.path)) }
    }

    private func relative(_ path: String) -> String {
        path.hasPrefix(parent + "/") ? String(path.dropFirst(parent.count + 1)) : path
    }

    private func importSelected() {
        busy = true; error = nil
        let paths = scan.repos.map(\.path).filter(selected.contains)
        Task {
            do {
                let statuses = try await catalog.importNested(parentPath: parent, group: asGroup, paths: paths)
                busy = false
                failures = statuses.filter { $0.value == "failed" }.mapValues { _ in "Could not import" }
                guard failures.isEmpty else { error = "\(failures.count) of \(paths.count) repositories could not be imported."; return }
                let first = paths.first.flatMap { path in catalog.projects.first { $0.path == path }?.workspaces.first?.key }
                onImported(first)
            } catch {
                busy = false
                self.error = (error as? WorkspaceCatalogModel.HostFailure)?.localizedDescription ?? error.localizedDescription
            }
        }
    }
}

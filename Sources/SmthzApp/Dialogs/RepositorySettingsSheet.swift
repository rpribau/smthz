import SwiftUI
import SmthzCore

/// Repository settings (WP-M4-WORKTREE-APP), read with `repo.show` and saved with `repo.update`:
/// display name, badge colour, base ref, setup run policy, command source, local setup/archive
/// scripts, shared paths and external worktree visibility.
struct SmthzRepositorySettingsSheet: View {
    let repoID: String
    let lifecycle: WorktreeLifecycleModel
    let onDismiss: () -> Void
    var onSaved: () -> Void = {}

    @State private var loaded: [String: HostJSON] = [:]
    @State private var displayName = ""
    @State private var baseRef = ""
    @State private var setupPolicy = "run-by-default"
    @State private var commandSource = "default"
    @State private var setupScript = ""
    @State private var archiveScript = ""
    @State private var sharedPaths = ""
    @State private var visibility = "inherit"
    @State private var saving = false
    @State private var error: String?

    private static let badges = ["#ef4444", "#f97316", "#eab308", "#22c55e", "#14b8a6", "#3b82f6", "#a855f7", "#ec4899", "#737373"]
    @State private var badge = "#737373"

    var body: some View {
        SmthzDialog(title: "Repository Settings", description: loaded["path"]?.string, onDismiss: onDismiss) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    field("Display name") { SmthzComposerTextField(placeholder: "Name", text: $displayName) }
                    field("Badge colour") {
                        HStack(spacing: 6) {
                            ForEach(Self.badges, id: \.self) { hex in
                                Button { badge = hex } label: {
                                    Circle().fill(Self.color(hex)).frame(width: 16, height: 16)
                                        .overlay { if badge == hex { Circle().strokeBorder(SmthzTheme.foreground, lineWidth: 2) } }
                                }.buttonStyle(.plain).accessibilityLabel(hex)
                            }
                        }
                    }
                    field("Base ref for new workspaces") {
                        SmthzComposerTextField(placeholder: "Automatic (origin/HEAD, main, master)", text: $baseRef)
                    }
                    field("Setup script") {
                        Picker("Setup run policy", selection: $setupPolicy) {
                            Text("Run by default").tag("run-by-default")
                            Text("Ask every time").tag("ask")
                            Text("Skip by default").tag("skip-by-default")
                        }.pickerStyle(.segmented).labelsHidden()
                    }
                    field("Command source") {
                        Picker("Command source", selection: $commandSource) {
                            Text("Default").tag("default")
                            Text("Shared only").tag("shared-only")
                            Text("Local only").tag("local-only")
                            Text("Run both").tag("run-both")
                        }.pickerStyle(.segmented).labelsHidden()
                    }
                    field("Local setup script") { editor($setupScript) }
                    field("Local archive script") { editor($archiveScript) }
                    field("Shared paths (one per line, linked into new workspaces)") { editor($sharedPaths) }
                    field("Worktrees created outside smthz") {
                        Picker("External worktrees", selection: $visibility) {
                            Text("Default").tag("inherit")
                            Text("Show").tag("show")
                            Text("Hide").tag("hide")
                        }.pickerStyle(.segmented).labelsHidden()
                    }
                    if let error { Text(error).font(SmthzFont.ui(size: 12)).foregroundStyle(SmthzTheme.destructive) }
                }.padding(.trailing, 4)
            }.frame(maxHeight: 460)
        } footer: {
            Button("Cancel", action: onDismiss).buttonStyle(SmthzButtonStyle(.outline, size: .small))
            Button("Save", action: save).buttonStyle(SmthzButtonStyle(.primary, size: .small))
                .keyboardShortcut(.return, modifiers: .command).disabled(saving || loaded.isEmpty)
        }
        .task { await load() }
    }

    private func field<V: View>(_ title: String, @ViewBuilder content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(SmthzFont.ui(size: 12, weight: .medium)).foregroundStyle(SmthzTheme.mutedForeground)
            content()
        }
    }
    private func editor(_ text: Binding<String>) -> some View {
        TextEditor(text: text).font(SmthzFont.mono(size: 12)).frame(height: 64)
            .scrollContentBackground(.hidden).padding(6)
            .background(SmthzTheme.input.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SmthzTheme.input))
    }

    private func load() async {
        do {
            let repo = try await lifecycle.repo(repoID)
            loaded = repo
            displayName = repo["displayName"]?.string ?? ""
            badge = repo["badgeColor"]?.string ?? "#737373"
            baseRef = repo["worktreeBaseRef"]?.string ?? ""
            setupPolicy = repo["setupRunPolicy"]?.string ?? "run-by-default"
            commandSource = repo["commandSourcePolicy"]?.string ?? "default"
            setupScript = repo["localSetupScript"]?.string ?? ""
            archiveScript = repo["localArchiveScript"]?.string ?? ""
            if case .array(let items) = repo["sharedPaths"] ?? .null { sharedPaths = items.compactMap(\.string).joined(separator: "\n") }
            visibility = repo["externalWorktreeVisibility"]?.string ?? "inherit"
        } catch { self.error = error.localizedDescription }
    }

    private func save() {
        var fields: [String: HostJSON] = [:]
        func put(_ key: String, _ value: HostJSON, current: HostJSON?) { if value != (current ?? .null) { fields[key] = value } }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        put("displayName", .string(name), current: loaded["displayName"])
        put("badgeColor", .string(badge), current: loaded["badgeColor"])
        let ref = baseRef.trimmingCharacters(in: .whitespaces)
        put("worktreeBaseRef", ref.isEmpty ? .null : .string(ref), current: loaded["worktreeBaseRef"])
        put("setupRunPolicy", .string(setupPolicy), current: loaded["setupRunPolicy"])
        put("commandSourcePolicy", commandSource == "default" ? .null : .string(commandSource), current: loaded["commandSourcePolicy"])
        put("localSetupScript", .string(setupScript), current: loaded["localSetupScript"] ?? .string(""))
        put("localArchiveScript", .string(archiveScript), current: loaded["localArchiveScript"] ?? .string(""))
        let paths = sharedPaths.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        put("sharedPaths", .array(paths.map(HostJSON.string)), current: loaded["sharedPaths"] ?? .array([]))
        put("externalWorktreeVisibility", .string(visibility), current: loaded["externalWorktreeVisibility"] ?? .string("inherit"))
        guard !fields.isEmpty else { onDismiss(); return }
        saving = true; error = nil
        Task {
            do { try await lifecycle.updateRepo(repoID, fields); onSaved(); onDismiss() }
            catch let failure as WorktreeLifecycleModel.Failure where failure.code == "invalidRef" {
                error = "Base ref \"\(ref)\" does not exist in this repository."
            } catch { self.error = error.localizedDescription }
            saving = false
        }
    }

    private static func color(_ hex: String) -> Color {
        let value = Int(hex.dropFirst(), radix: 16) ?? 0x737373
        return Color(red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255, blue: Double(value & 0xff) / 255)
    }
}

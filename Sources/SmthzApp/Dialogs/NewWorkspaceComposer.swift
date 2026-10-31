import SwiftUI
import SmthzCore

/// Project choice offered by the composer (git projects of the catalog).
struct SmthzComposerProject: Identifiable, Equatable {
    struct Parent: Identifiable, Equatable { let id: String; let title: String }
    let id: String
    let title: String
    let path: String
    var parents: [Parent] = []
}

/// New Workspace composer (WP-M4-WORKTREE-APP). Project, Name (with `:shortcode:` suggestions),
/// Create From Name/Branch, start-from ref, branch name, parent, note, sparse directories/presets,
/// setup choice and Create more are real (`worktree.create`). VISUAL-ONLY: the Smart/GitHub/GitLab/
/// Linear/Jira sources (M9), Run on (M7) and Agent (M5). With no project registered, Create opens
/// a shell in the Default workspace as before.
struct SmthzNewWorkspaceComposer: View {
    enum SubmitResult { case started, handedOff, failed(String) }

    var projects: [SmthzComposerProject] = []
    var initialProjectID: String? = nil
    var lifecycle: WorktreeLifecycleModel? = nil
    let onDismiss: () -> Void
    let onAddProject: () -> Void
    let onCreateShell: () -> Void
    var onAgentSettings: (() -> Void)? = nil
    var onSubmit: ([String: HostJSON], String) async -> SubmitResult = { _, _ in .failed("Not available") }

    @State private var projectID: String?
    @State private var projectSearch = ""
    @State private var projectPickerOpen = false
    @State private var source = WorkspaceComposerLogic.Source.name
    @State private var runTargetOpen = false
    @State private var agentPickerOpen = false
    @State private var name = ""
    @State private var suggestedName: String?
    @State private var advanced = false
    @State private var createMore = false
    @State private var branch = ""
    @State private var note = ""
    @State private var parentID: String?
    @State private var setup = WorkspaceComposerLogic.SetupChoice.inherit
    @State private var sparseCheckout = false
    @State private var sparseText = ""
    @State private var presetName = ""
    @State private var presets: [String: [String]] = [:]
    @State private var ref: WorkspaceComposerLogic.Ref?
    @State private var refQuery = ""
    @State private var refs: [WorkspaceComposerLogic.Ref] = []
    @State private var refPickerOpen = false
    @State private var submitting = false
    @State private var error: String?

    private var project: SmthzComposerProject? { projects.first { $0.id == projectID } }
    private var shortcodes: [EmojiShortcodes.Entry] { WorkspaceComposerLogic.shortcodeSuggestions(for: name, limit: 6) }

    var body: some View {
        SmthzProjectDialogPanel(title: "Create workspace", onDismiss: onDismiss) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    projectSection
                    sourceSection
                    agentSection
                    if project != nil { advancedSection }
                    if let error {
                        Text(error).font(SmthzFont.ui(size: 12)).foregroundStyle(SmthzTheme.destructive)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxHeight: 470)
            .fixedSize(horizontal: false, vertical: true)
        } footer: {
            HStack(spacing: 12) {
                Toggle("Create more", isOn: $createMore)
                    .toggleStyle(.switch).controlSize(.mini)
                    .font(SmthzFont.ui(size: 12))
                    .foregroundStyle(SmthzTheme.mutedForeground)
                    .fixedSize()
                Spacer(minLength: 8)
                Button(action: create) {
                    HStack(spacing: 8) {
                        if submitting { ProgressView().controlSize(.mini) }
                        Text("Create workspace")
                        Text("⌘↩").opacity(0.65).accessibilityHidden(true)
                    }
                }
                .buttonStyle(SmthzButtonStyle(.primary, size: .small))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(submitting || (project != nil && !source.isAvailable) || (project != nil && source == .branch && ref == nil))
                .accessibilityHint(project == nil ? "Create a new shell in Default workspace" : "Create a Git worktree in \(project!.title)")
            }
        }
        .accessibilityHint("Choose the project and workspace name. Select an agent if you want to start one.")
        .onAppear {
            if projectID == nil { projectID = initialProjectID.flatMap { id in projects.first { $0.id == id }?.id } ?? projects.first?.id }
        }
        .task(id: projectID) { await loadProject() }
        .task(id: refQuery + "|" + (projectID ?? "") + "|" + source.rawValue) { await loadRefs() }
    }

    private var projectSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionLabel("Project")
                Spacer()
                Button(action: onAddProject) {
                    SmthzIcon.image("folder-plus").scaledToFit().frame(width: 12, height: 12)
                }
                .buttonStyle(SmthzButtonStyle(.ghost, size: .iconXS))
                .accessibilityLabel("Add project").help("Add project")
            }
            Button { projectPickerOpen.toggle() } label: {
                pickerLabel(project?.title ?? "Choose project", icon: "folder", active: project != nil)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $projectPickerOpen, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        projectPickerOpen = false
                        onAddProject()
                    } label: {
                        Label("Add a new project", systemImage: "folder.badge.plus").frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(SmthzButtonStyle(.ghost, size: .small))
                    Divider()
                    SmthzComposerTextField(placeholder: "Search projects...", text: $projectSearch)
                    let matches = projects.filter { projectSearch.isEmpty || $0.title.localizedCaseInsensitiveContains(projectSearch) }
                    if matches.isEmpty {
                        Text(projects.isEmpty ? "No projects yet." : "No projects match your search.")
                            .font(SmthzFont.ui(size: 12)).foregroundStyle(SmthzTheme.mutedForeground)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(matches) { item in
                                Button {
                                    projectID = item.id; projectPickerOpen = false
                                } label: {
                                    HStack {
                                        Text(item.title).font(SmthzFont.ui(size: 13))
                                        Spacer()
                                        if item.id == projectID { Image(systemName: "checkmark").font(.system(size: 11)) }
                                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(SmthzButtonStyle(.ghost, size: .small))
                            }
                        }
                    }.frame(maxHeight: 220)
                }
                .padding(12).frame(width: 320).background(SmthzTheme.popover)
            }
            if project == nil {
                Text("Creates a terminal in Default workspace.")
                    .font(SmthzFont.ui(size: 11)).foregroundStyle(SmthzTheme.mutedForeground)
            }
            sectionLabel("Run on").padding(.top, 6)
            Button { runTargetOpen.toggle() } label: {
                pickerLabel("Local", icon: "server")
            }
            .buttonStyle(.plain)
            .popover(isPresented: $runTargetOpen) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Local").font(SmthzFont.ui(size: 12, weight: .medium))
                    Divider()
                    Text("Add host").font(SmthzFont.ui(size: 11, weight: .semibold))
                        .foregroundStyle(SmthzTheme.mutedForeground)
                    Button("Add SSH host") {}.disabled(true)
                    Button("Add Remote smthz Server") {}.disabled(true)
                    Text("Not available yet").font(SmthzFont.ui(size: 11))
                        .foregroundStyle(SmthzTheme.mutedForeground)
                }.padding(12).frame(width: 240, alignment: .leading)
            }
        }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Create From", optional: true)
            HStack(spacing: 0) {
                ForEach(WorkspaceComposerLogic.Source.allCases, id: \.self) { item in
                    Button { source = item; error = nil } label: {
                        Text(item.rawValue)
                            .font(SmthzFont.ui(size: 11, weight: source == item ? .medium : .regular))
                            .foregroundStyle(source == item ? SmthzTheme.foreground : SmthzTheme.mutedForeground)
                            .padding(.horizontal, 7).frame(height: 28)
                            .background(source == item ? SmthzTheme.background : .clear,
                                        in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(source == item ? .isSelected : [])
                }
            }
            .padding(3).frame(maxWidth: .infinity, alignment: .leading)
            .background(SmthzTheme.muted, in: RoundedRectangle(cornerRadius: 10))
            if source == .branch, project != nil {
                refPicker(placeholder: "Choose a branch", branchesOnly: true)
            }
            SmthzComposerTextField(placeholder: source == .branch ? "Workspace name (defaults to the branch)"
                                   : (suggestedName.map { "Workspace name (\($0))" } ?? "Workspace name"), text: $name)
            if !shortcodes.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(shortcodes, id: \.shortcode) { entry in
                        Button { name = WorkspaceComposerLogic.applyShortcode(entry.shortcode, to: name) } label: {
                            HStack(spacing: 8) { Text(entry.emoji); Text(":\(entry.shortcode):").font(SmthzFont.mono(size: 12)); Spacer() }
                                .contentShape(Rectangle())
                        }.buttonStyle(SmthzButtonStyle(.ghost, size: .xs))
                    }
                }
                .padding(4).background(SmthzTheme.popover, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SmthzTheme.border))
                .accessibilityLabel("Emoji suggestions")
            }
            if !source.isAvailable {
                Text("Not available yet. Use Name or Branch.")
                    .font(SmthzFont.ui(size: 11)).foregroundStyle(SmthzTheme.mutedForeground)
            }
        }
    }

    private var agentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionLabel("Agent", optional: true)
                Spacer()
                Button { onAgentSettings?() } label: {
                    SmthzIcon.image("sliders-horizontal").scaledToFit().frame(width: 12, height: 12)
                }
                .buttonStyle(SmthzButtonStyle(.ghost, size: .iconXS))
                .disabled(onAgentSettings == nil)
                .accessibilityLabel("Open agent settings").help("Configure agents")
            }
            Button { agentPickerOpen.toggle() } label: {
                pickerLabel("None", icon: "terminal")
            }
            .buttonStyle(.plain)
            .popover(isPresented: $agentPickerOpen) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("None").font(SmthzFont.ui(size: 12, weight: .medium))
                    Divider()
                    Button("Configure agents") {
                        agentPickerOpen = false
                        onAgentSettings?()
                    }.disabled(onAgentSettings == nil)
                }.padding(12).frame(width: 220, alignment: .leading)
            }
        }
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { advanced.toggle() } label: {
                HStack(spacing: 6) {
                    SmthzIcon.image(advanced ? "chevron-down" : "chevron-right")
                        .scaledToFit().frame(width: 12, height: 12)
                    Text("Advanced").font(SmthzFont.ui(size: 12))
                }
                .foregroundStyle(SmthzTheme.mutedForeground)
            }
            .buttonStyle(SmthzButtonStyle(.ghost, size: .xs))
            .accessibilityValue(advanced ? "Expanded" : "Collapsed")
            if advanced {
                VStack(alignment: .leading, spacing: 12) {
                    advancedField("Branch name", placeholder: "Defaults to <prefix>/<name>", text: $branch)
                    advancedField("Note", placeholder: "Write a note", text: $note)
                    if source == .name {
                        sectionLabel("Start from")
                        refPicker(placeholder: "Default base ref", branchesOnly: false)
                    }
                    sectionLabel("Parent worktree")
                    Menu {
                        Button("No parent") { parentID = nil }
                        Divider()
                        ForEach(project?.parents ?? []) { parent in Button(parent.title) { parentID = parent.id } }
                    } label: {
                        pickerLabel(project?.parents.first { $0.id == parentID }?.title ?? "No parent", icon: "folder-tree", active: parentID != nil)
                    }.menuStyle(.button).buttonStyle(.plain)
                    Text("Nests this workspace under another in the sidebar. Does not change the base branch.")
                        .font(SmthzFont.ui(size: 11)).foregroundStyle(SmthzTheme.mutedForeground)
                    sectionLabel("Setup script")
                    Picker("Setup script", selection: $setup) {
                        Text("Repository default").tag(WorkspaceComposerLogic.SetupChoice.inherit)
                        Text("Run setup").tag(WorkspaceComposerLogic.SetupChoice.run)
                        Text("Skip setup").tag(WorkspaceComposerLogic.SetupChoice.skip)
                    }.pickerStyle(.segmented).labelsHidden()
                    Toggle("Sparse checkout", isOn: $sparseCheckout).toggleStyle(SmthzCheckboxStyle())
                    if sparseCheckout { sparseSection }
                }
            }
        }
    }

    private var sparseSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Directories (one per line)").font(SmthzFont.ui(size: 11)).foregroundStyle(SmthzTheme.mutedForeground)
                Spacer()
                Menu("Presets") {
                    if presets.isEmpty { Button("No presets") {}.disabled(true) }
                    ForEach(presets.keys.sorted(), id: \.self) { key in
                        Button(key) { sparseText = presets[key]!.joined(separator: "\n"); presetName = key }
                    }
                    if !presetName.isEmpty, presets[presetName] != nil {
                        Divider()
                        Button("Delete \"\(presetName)\"", role: .destructive) { presets[presetName] = nil; savePresets(); presetName = "" }
                    }
                }.menuStyle(.button).fixedSize()
            }
            TextEditor(text: $sparseText).font(SmthzFont.mono(size: 12)).frame(height: 72)
                .scrollContentBackground(.hidden).padding(6)
                .background(SmthzTheme.input.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SmthzTheme.input))
            HStack {
                SmthzComposerTextField(placeholder: "Preset name", text: $presetName)
                Button("Save preset") {
                    guard let dirs = try? WorkspaceComposerLogic.parseSparseDirectories(sparseText) else { error = "Enter valid directories first."; return }
                    presets[presetName.trimmingCharacters(in: .whitespaces)] = dirs; savePresets()
                }
                .buttonStyle(SmthzButtonStyle(.outline, size: .small))
                .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Presets are stored on this Mac.").font(SmthzFont.ui(size: 11)).foregroundStyle(SmthzTheme.mutedForeground)
        }
    }

    private func refPicker(placeholder: String, branchesOnly: Bool) -> some View {
        Button { refPickerOpen.toggle() } label: {
            pickerLabel(ref?.name ?? placeholder, icon: "git-branch", active: ref != nil)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $refPickerOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                SmthzComposerTextField(placeholder: "Search branches and tags...", text: $refQuery)
                if !branchesOnly, ref != nil {
                    Button("Use default base ref") { ref = nil; refPickerOpen = false }.buttonStyle(SmthzButtonStyle(.ghost, size: .small))
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(refs.filter { !branchesOnly || $0.kind != "tag" }, id: \.name) { item in
                            Button { ref = item; refPickerOpen = false } label: {
                                HStack {
                                    Text(item.name).font(SmthzFont.mono(size: 12)).lineLimit(1)
                                    Spacer()
                                    Text(item.kind).font(SmthzFont.ui(size: 10)).foregroundStyle(SmthzTheme.mutedForeground)
                                }.contentShape(Rectangle())
                            }.buttonStyle(SmthzButtonStyle(.ghost, size: .small))
                        }
                        if refs.isEmpty {
                            Text("No refs found.").font(SmthzFont.ui(size: 12)).foregroundStyle(SmthzTheme.mutedForeground).padding(8)
                        }
                    }
                }.frame(maxHeight: 240)
            }.padding(12).frame(width: 340).background(SmthzTheme.popover)
        }
    }

    private func sectionLabel(_ text: String, optional: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(text)
            if optional { Text("[Optional]").opacity(0.7) }
        }
        .font(SmthzFont.ui(size: 12, weight: .medium))
        .foregroundStyle(SmthzTheme.mutedForeground)
    }

    private func pickerLabel(_ text: String, icon: String, active: Bool = false) -> some View {
        HStack(spacing: 8) {
            SmthzIcon.image(icon).scaledToFit().frame(width: 14, height: 14)
            Text(text).font(SmthzFont.ui(size: 14)).lineLimit(1)
                .foregroundStyle(active ? SmthzTheme.foreground : SmthzTheme.mutedForeground)
            Spacer(minLength: 0)
            SmthzIcon.image("chevron-down").scaledToFit().frame(width: 12, height: 12)
        }
        .foregroundStyle(SmthzTheme.mutedForeground)
        .padding(.horizontal, 12).frame(height: 36)
        .background(SmthzTheme.input.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SmthzTheme.input))
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    private func advancedField(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel(title)
            SmthzComposerTextField(placeholder: placeholder, text: text)
        }
    }

    private var presetsKey: String { "worktree.sparsePresets." + (projectID ?? "") }
    private func loadProject() async {
        ref = nil; parentID = nil; suggestedName = nil
        presets = (UserDefaults.standard.data(forKey: presetsKey)).flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) } ?? [:]
        guard let projectID, let lifecycle else { return }
        suggestedName = await lifecycle.suggestName(repoID: projectID)
    }
    private func savePresets() {
        if let data = try? JSONEncoder().encode(presets) { UserDefaults.standard.set(data, forKey: presetsKey) }
    }
    private func loadRefs() async {
        guard let projectID, let lifecycle else { refs = []; return }
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        refs = await lifecycle.searchRefs(repoID: projectID, query: refQuery)
    }

    private func create() {
        guard let project else {
            onCreateShell()
            if createMore { name = "" } else { onDismiss() }
            return
        }
        var form = WorkspaceComposerLogic.CreateForm(repoID: project.id)
        form.source = source; form.name = name; form.suggestedName = suggestedName; form.ref = ref
        form.branchName = branch; form.parentID = parentID; form.comment = note; form.setup = setup
        if sparseCheckout {
            do { form.sparseDirectories = try WorkspaceComposerLogic.parseSparseDirectories(sparseText) }
            catch WorkspaceComposerLogic.SparseError.invalid(let item) { error = "Invalid sparse directory: \(item)"; return }
            catch { self.error = "Enter at least one sparse directory."; return }
            form.sparsePresetID = presets[presetName] == form.sparseDirectories ? presetName : nil
        }
        let params: [String: HostJSON]
        do { params = try WorkspaceComposerLogic.createParams(form) }
        catch {
            switch error {
            case .sourceUnavailable: self.error = "This source is not available yet."
            case .missingName: self.error = "Enter a workspace name."
            case .missingBranch: self.error = "Choose a branch."
            case .invalidBranchName: self.error = "Branch names cannot start with - or contain spaces."
            }
            return
        }
        let title = params["name"]?.string ?? "Workspace"
        submitting = true; error = nil
        Task {
            let result = await onSubmit(params, title)
            submitting = false
            switch result {
            case .started:
                if createMore {
                    name = ""; branch = ""; note = ""
                    if let lifecycle { suggestedName = await lifecycle.suggestName(repoID: project.id) }
                } else { onDismiss() }
            case .handedOff: break
            case .failed(let message): error = message
            }
        }
    }
}

/// UI-24's 16 pt composer heading differs from the general 18 pt SmthzDialog.
/// The panel uses the same §10 tokens; UI-29 owns the full-window dimming layer.
struct SmthzProjectDialogPanel<Content: View, Footer: View>: View {
    let title: String
    var subtitle: String? = nil
    let onDismiss: () -> Void
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(SmthzFont.ui(size: 16, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle).font(SmthzFont.ui(size: 14))
                        .foregroundStyle(SmthzTheme.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.padding(.trailing, 24)
            content()
            footer()
        }
        .padding(24).frame(maxWidth: 512, alignment: .leading)
        .font(SmthzFont.ui(size: 14)).foregroundStyle(SmthzTheme.foreground)
        .background {
            RoundedRectangle(cornerRadius: 10).fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .fill((colorScheme == .dark ? SmthzTheme.card : SmthzTheme.background)
                            .opacity(reduceTransparency ? 1 : 0.96))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(colorScheme == .dark ? .white.opacity(0.14) : .black.opacity(0.14))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(.white.opacity(colorScheme == .dark ? 0.05 : 0.3))
                .padding(1).allowsHitTesting(false)
        }
        .overlay(alignment: .topTrailing) {
            Button(action: onDismiss) {
                SmthzIcon.image("x").scaledToFit().frame(width: 14, height: 14).opacity(0.7)
            }
            .buttonStyle(SmthzButtonStyle(.ghost, size: .iconXS))
            .accessibilityLabel("Close dialog").keyboardShortcut(.cancelAction).padding(11)
        }
        .shadow(color: .black.opacity(0.28), radius: 30, y: 20)
        .onExitCommand(perform: onDismiss)
        .accessibilityElement(children: .contain).accessibilityLabel(title)
    }
}

struct SmthzComposerTextField: View {
    let placeholder: String
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain).font(SmthzFont.ui(size: 14))
            .padding(.horizontal, 12).frame(height: 36)
            .background(SmthzTheme.input.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SmthzTheme.input))
            .overlay {
                RoundedRectangle(cornerRadius: 9).stroke(SmthzTheme.ring.opacity(0.5), lineWidth: 3)
                    .padding(-1).opacity(focused ? 1 : 0)
            }
            .focused($focused).accessibilityLabel(placeholder)
    }
}

#if DEBUG
#Preview("Create workspace · light") {
    SmthzNewWorkspaceComposer(onDismiss: {}, onAddProject: {}, onCreateShell: {})
        .padding(40).frame(width: 650, height: 690).background(SmthzTheme.background)
        .preferredColorScheme(.light)
}
#Preview("Create workspace · dark") {
    SmthzNewWorkspaceComposer(onDismiss: {}, onAddProject: {}, onCreateShell: {})
        .padding(40).frame(width: 650, height: 690).background(SmthzTheme.background)
        .preferredColorScheme(.dark)
}
#endif

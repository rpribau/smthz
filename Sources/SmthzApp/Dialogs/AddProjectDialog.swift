import AppKit
import SwiftUI
import SmthzCore

/// Add Project (WP-M4-REGISTRY): Browse → `repo.scanNested` → `repo.add` or the nested import
/// view; Clone from URL (`repo.clone` job with progress); Create new project (`repo.create`).
/// Remote hosts (SSH/server/WSL) stay VISUAL-ONLY until M7.
struct SmthzAddProjectDialog: View {
    /// Callers without the shell's catalog (onboarding) get a private one; the host stays the single writer.
    var catalog = WorkspaceCatalogModel()
    let onDismiss: () -> Void
    /// Receives the new project's main workspace so the shell can switch to it.
    var onAdded: (WorkspaceKey?) -> Void = { _ in }
    private enum Mode: Equatable { case choose, clone, create, nested(parent: String, scan: WorkspaceCatalogModel.ScanResult) }
    @State private var mode: Mode = .choose
    @State private var browsing = false
    @State private var busy: String?
    @State private var failure: String?
    @State private var hostPickerOpen = false
    @State private var cloneURL = ""
    @State private var cloneName = ""
    @State private var parentPath = Self.defaultParent
    @State private var projectName = ""
    @State private var initGit = true
    @State private var progress: Double?
    @State private var cancelFlag = CancelFlag()
    @FocusState private var browseFocused: Bool
    private static let defaultParent = NSString(string: "~/smthz/projects").expandingTildeInPath

    var body: some View {
        SmthzProjectDialogPanel(title: title, subtitle: subtitle, onDismiss: onDismiss) {
            VStack(alignment: .leading, spacing: 12) {
                switch mode {
                case .choose: chooser
                case .clone: cloneForm
                case .create: createForm
                case .nested(let parent, let scan):
                    SmthzNestedImportView(parent: parent, scan: scan, catalog: catalog,
                        onBack: { mode = .choose }, onImported: { key in onAdded(key); onDismiss() },
                        onAddFolderOnly: { add(parent, kind: "folder") })
                }
                if let busy {
                    HStack(spacing: 8) {
                        if let progress { ProgressView(value: progress).frame(width: 120) } else { ProgressView().controlSize(.small) }
                        Text(busy).font(SmthzFont.ui(size: 12)).foregroundStyle(SmthzTheme.mutedForeground).lineLimit(2)
                    }
                }
                if let failure {
                    Text(failure).font(SmthzFont.ui(size: 12)).foregroundStyle(SmthzTheme.destructive)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 8)
        } footer: {
            footer
        }
        .onAppear { browseFocused = true }
    }

    private var title: String {
        switch mode {
        case .choose: "Add a project"
        case .clone: "Clone from URL"
        case .create: "Create new project"
        case .nested: "Import repositories"
        }
    }
    private var subtitle: String? {
        switch mode {
        case .choose: "Add a project to get started with smthz."
        case .clone: "Clone a remote Git repository into a local folder."
        case .create: "Start from an empty folder."
        case .nested: "This folder contains several repositories."
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            footerButtons
        }
    }
    @ViewBuilder private var footerButtons: some View {
        switch mode {
        case .clone:
            Button("Back") { mode = .choose; failure = nil }.buttonStyle(SmthzButtonStyle(.outline)).disabled(busy != nil)
            if busy != nil { Button("Cancel clone") { cancelFlag.cancel() }.buttonStyle(SmthzButtonStyle(.outline)) }
            Button("Clone", action: clone).buttonStyle(SmthzButtonStyle())
                .disabled(busy != nil || cloneURL.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.return, modifiers: [])
        case .create:
            Button("Back") { mode = .choose; failure = nil }.buttonStyle(SmthzButtonStyle(.outline)).disabled(busy != nil)
            Button("Create", action: create).buttonStyle(SmthzButtonStyle())
                .disabled(busy != nil || projectName.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.return, modifiers: [])
        default: EmptyView()
        }
    }

    private var chooser: some View {
            VStack(alignment: .leading, spacing: 12) {
                hostSelector
                Button(action: browse) {
                    actionLabel("Browse folder", description: "Local project, Git repo, or folder with many repos",
                                icon: "folder-open", primary: true)
                }
                .buttonStyle(SmthzAddProjectCardStyle())
                .focused($browseFocused)
                .disabled(browsing || busy != nil)
                .keyboardShortcut(.return, modifiers: [])
                VStack(alignment: .leading, spacing: 6) {
                    Text("Other ways to add").textCase(.uppercase)
                        .font(SmthzFont.ui(size: 12, weight: .medium)).tracking(0.6)
                        .foregroundStyle(SmthzTheme.mutedForeground)
                    VStack(spacing: 0) {
                        Button { failure = nil; mode = .create } label: {
                            actionLabel("Create new project", description: "Start from an empty folder", icon: "plus")
                        }.buttonStyle(.plain).disabled(busy != nil)
                        Divider().overlay(SmthzTheme.border.opacity(0.7))
                        Button { failure = nil; mode = .clone } label: {
                            actionLabel("Clone from URL", description: "Clone a remote Git repository", icon: "globe")
                        }.buttonStyle(.plain).disabled(busy != nil)
                        Divider().overlay(SmthzTheme.border.opacity(0.7))
                        unavailableAction("SSH", description: "Open a project from an SSH target", icon: nil)
                    }
                    .background(SmthzTheme.background)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SmthzTheme.input))
                }
            }
    }

    private var cloneForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            field("Repository URL") {
                TextField("https://github.com/owner/repo.git", text: $cloneURL).textFieldStyle(.roundedBorder)
                    .disabled(busy != nil)
            }
            field("Folder name (optional)") {
                TextField("Defaults to the repository name", text: $cloneName).textFieldStyle(.roundedBorder).disabled(busy != nil)
            }
            parentPicker
        }
    }

    private var createForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            field("Project name") {
                TextField("my-project", text: $projectName).textFieldStyle(.roundedBorder).disabled(busy != nil)
            }
            parentPicker
            Toggle("Initialize a Git repository", isOn: $initGit).toggleStyle(.checkbox)
                .font(SmthzFont.ui(size: 13)).disabled(busy != nil)
        }
    }

    private var parentPicker: some View {
        field("Location") {
            HStack(spacing: 8) {
                Text(parentPath).font(SmthzFont.mono(size: 12)).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8).frame(height: 28)
                    .background(SmthzTheme.input.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                Button("Choose…") { if let url = pickFolder(title: "Choose location", canCreate: true) { parentPath = url.path } }
                    .buttonStyle(SmthzButtonStyle(.outline, size: .small)).disabled(busy != nil)
            }
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(SmthzFont.ui(size: 12, weight: .medium)).foregroundStyle(SmthzTheme.mutedForeground)
            content()
        }
    }

    private var hostSelector: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Host").font(SmthzFont.ui(size: 12, weight: .medium))
                .foregroundStyle(SmthzTheme.mutedForeground)
            Button { hostPickerOpen.toggle() } label: {
                HStack(spacing: 8) {
                    SmthzIcon.image("server").scaledToFit().frame(width: 14, height: 14)
                    Text("Local").font(SmthzFont.ui(size: 14))
                    Spacer()
                    SmthzIcon.image("chevron-down").scaledToFit().frame(width: 12, height: 12)
                }
                .padding(.horizontal, 12).frame(height: 36)
                .background(SmthzTheme.input.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SmthzTheme.input))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $hostPickerOpen) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Local").font(SmthzFont.ui(size: 12, weight: .medium))
                    Divider()
                    Text("Add remote host").font(SmthzFont.ui(size: 11, weight: .semibold))
                        .foregroundStyle(SmthzTheme.mutedForeground)
                    Button("SSH host") {}.disabled(true)
                    Button("remote server") {}.disabled(true)
                    Button("WSL distro") {}.disabled(true)
                    Text("Not available yet").font(SmthzFont.ui(size: 11))
                        .foregroundStyle(SmthzTheme.mutedForeground)
                }.padding(12).frame(width: 240, alignment: .leading)
            }
        }
    }

    private func unavailableAction(_ title: String, description: String, icon: String?) -> some View {
        Button {} label: {
            actionLabel(title, description: description, icon: icon)
        }
        .buttonStyle(.plain).disabled(true).opacity(0.7)
        .help("Not available yet")
        .accessibilityHint("Not available yet")
    }

    private func actionLabel(_ title: String, description: String, icon: String?, primary: Bool = false) -> some View {
        HStack(spacing: 12) {
            Group {
                if let icon {
                    SmthzIcon.image(icon).scaledToFit()
                } else {
                    // Monitor is not in UI-24's allowed SVG scope; use its native equivalent.
                    Image(systemName: "display").resizable().scaledToFit()
                }
            }
            .frame(width: 16, height: 16).frame(width: 28, height: 28)
            .background(primary ? SmthzTheme.background.opacity(0.7) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(SmthzFont.ui(size: 14, weight: .medium))
                Text(description).font(SmthzFont.ui(size: 12))
                    .foregroundStyle(SmthzTheme.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if primary && browseFocused {
                Text("⏎").font(SmthzFont.ui(size: 12, weight: .medium))
                    .foregroundStyle(SmthzTheme.mutedForeground)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(SmthzTheme.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(SmthzTheme.border.opacity(0.8)))
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(SmthzTheme.foreground)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: primary ? 60 : 52, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func pickFolder(title: String, canCreate: Bool) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "Choose folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = canCreate
        panel.allowsMultipleSelection = false
        // Modal presentation keeps keyboard input in the folder picker.
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func browse() {
        guard !browsing, busy == nil else { return }
        browsing = true
        let url = pickFolder(title: "Browse folder", canCreate: false)
        browsing = false
        browseFocused = true
        guard let path = url?.path else { return }
        failure = nil
        busy = "Looking for repositories…"
        Task {
            do {
                let scan = try await catalog.scanNested(path: path)
                busy = nil
                if scan.selectedPathKind == "git_repo" || scan.repos.isEmpty { add(path, kind: "auto") }
                else { mode = .nested(parent: path, scan: scan) }
            } catch { busy = nil; failure = describe(error) }
        }
    }

    private func add(_ path: String, kind: String) {
        failure = nil
        busy = "Adding project…"
        Task {
            do { let key = try await catalog.addRepo(path: path, kind: kind); busy = nil; onAdded(key); onDismiss() }
            catch { busy = nil; failure = describe(error) }
        }
    }

    private func clone() {
        let url = cloneURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = parentPath
        let flag = CancelFlag()
        cancelFlag = flag
        failure = nil; progress = nil
        busy = "Cloning…"
        Task {
            do {
                try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
                let key = try await catalog.clone(url: url, destinationParent: parent, name: cloneName.trimmingCharacters(in: .whitespaces),
                    isCancelled: { flag.isCancelled }) { text, fraction in
                        if !text.isEmpty { busy = text }
                        if let fraction { progress = fraction }
                    }
                busy = nil; progress = nil
                onAdded(key); onDismiss()
            } catch { busy = nil; progress = nil; failure = describe(error) }
        }
    }

    private func create() {
        let parent = parentPath, name = projectName.trimmingCharacters(in: .whitespacesAndNewlines), git = initGit
        failure = nil
        busy = "Creating project…"
        Task {
            do {
                try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
                let key = try await catalog.create(parentPath: parent, name: name, initGit: git)
                busy = nil; onAdded(key); onDismiss()
            } catch { busy = nil; failure = describe(error) }
        }
    }

    private func describe(_ error: any Error) -> String {
        guard let failure = error as? WorkspaceCatalogModel.HostFailure else { return error.localizedDescription }
        switch failure.code {
        case "alreadyExists": return "That folder already exists." + (failure.detail.map { " \($0)" } ?? "")
        case "authenticationRequired": return "The remote asked for credentials. Configure a credential helper or SSH key, then try again."
        case "invalidPath": return "The folder could not be found."
        case "invalidName": return "Enter a valid folder name."
        case "cancelled": return "Cancelled."
        default: return failure.localizedDescription
        }
    }
}

/// Polled by the clone job wait loop on a background thread.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

private struct SmthzAddProjectCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Card(configuration: configuration)
    }

    private struct Card: View {
        let configuration: Configuration
        @Environment(\.isFocused) private var focused
        @Environment(\.isEnabled) private var enabled
        @State private var hovered = false

        var body: some View {
            configuration.label
                .background(focused || hovered || configuration.isPressed ? SmthzTheme.accent : SmthzTheme.background,
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(focused ? SmthzTheme.ring : SmthzTheme.border)
                }
                .opacity(enabled ? 1 : 0.5)
                .onHover { hovered = $0 }
        }
    }
}

#if DEBUG
#Preview("Add project · light") {
    SmthzAddProjectDialog(catalog: WorkspaceCatalogModel(), onDismiss: {})
        .padding(40).frame(width: 650, height: 620).background(SmthzTheme.background)
        .preferredColorScheme(.light)
}
#Preview("Add project · dark") {
    SmthzAddProjectDialog(catalog: WorkspaceCatalogModel(), onDismiss: {})
        .padding(40).frame(width: 650, height: 620).background(SmthzTheme.background)
        .preferredColorScheme(.dark)
}
#endif

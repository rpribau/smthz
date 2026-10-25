import SwiftUI

// VISUAL-ONLY: stub data until M4 projects/worktrees and M5 agent configuration.
// UI-29 presents this in the existing Default workspace. No project, branch,
// provider or agent is created here; the sole create action is a new shell.
struct SmthzNewWorkspaceComposer: View {
    let onDismiss: () -> Void
    let onAddProject: () -> Void
    let onCreateShell: () -> Void
    var onAgentSettings: (() -> Void)? = nil

    @State private var projectSearch = ""
    @State private var projectPickerOpen = false
    @State private var source = "Smart"
    @State private var runTargetOpen = false
    @State private var agentPickerOpen = false
    @State private var name = ""
    @State private var advanced = false
    @State private var createMore = false
    @State private var branch = ""
    @State private var note = ""
    @State private var waitForSetup = true
    @State private var sparseCheckout = false

    private let sources = ["Smart", "GitHub", "GitLab", "Linear", "Jira", "Branch", "Name"]

    var body: some View {
        SmthzProjectDialogPanel(title: "Create workspace", onDismiss: onDismiss) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    projectSection
                    sourceSection
                    agentSection
                    advancedSection
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
                        Text("Create workspace")
                        Text("⌘↩").opacity(0.65).accessibilityHidden(true)
                    }
                }
                .buttonStyle(SmthzButtonStyle(.primary, size: .small))
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityHint("Create a new shell in Default workspace")
            }
        }
        .accessibilityHint("Choose the project and workspace name. Select an agent if you want to start one.")
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
                pickerLabel("Choose project", icon: "folder")
            }
            .buttonStyle(.plain)
            .popover(isPresented: $projectPickerOpen, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Browse projects").font(SmthzFont.ui(size: 12, weight: .semibold))
                    SmthzComposerTextField(placeholder: "Search projects...", text: $projectSearch)
                    Text(projectSearch.isEmpty ? "No projects yet." : "No projects match your search.")
                        .font(SmthzFont.ui(size: 12)).foregroundStyle(SmthzTheme.mutedForeground)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                    Divider()
                    Button {
                        projectPickerOpen = false
                        onAddProject()
                    } label: {
                        Label("Add project", systemImage: "folder.badge.plus")
                    }.buttonStyle(SmthzButtonStyle(.ghost, size: .small))
                }
                .padding(12).frame(width: 320).background(SmthzTheme.popover)
            }
            Text("Creates a terminal in Default workspace.")
                .font(SmthzFont.ui(size: 11)).foregroundStyle(SmthzTheme.mutedForeground)
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
                ForEach(sources, id: \.self) { item in
                    Button { source = item } label: {
                        Text(item)
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
            SmthzComposerTextField(placeholder: source == "Name" ? "Workspace name" : "Search or enter a workspace name...", text: $name)
            if source != "Smart" && source != "Name" {
                Text("Not available yet")
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
                    advancedField("Name", placeholder: "Workspace name", text: $name)
                    advancedField("Branch name", placeholder: "feature/my-branch", text: $branch)
                    advancedField("Note", placeholder: "Write a note", text: $note)
                    sectionLabel("Base ref")
                    pickerLabel("Choose base ref", icon: "git-branch")
                    sectionLabel("Parent worktree")
                    pickerLabel("No parent", icon: "folder-tree")
                    Text("Nests this workspace under another in the sidebar. Does not change the base branch.")
                        .font(SmthzFont.ui(size: 11)).foregroundStyle(SmthzTheme.mutedForeground)
                    sectionLabel("Setup script")
                    pickerLabel("local settings", icon: "file-text")
                    Toggle("Wait for setup to complete before starting agent", isOn: $waitForSetup)
                        .toggleStyle(SmthzCheckboxStyle())
                    Toggle("Sparse checkout", isOn: $sparseCheckout).toggleStyle(SmthzCheckboxStyle())
                }
                .disabled(true).opacity(0.5)
                Text("Not available yet")
                    .font(SmthzFont.ui(size: 11)).foregroundStyle(SmthzTheme.mutedForeground)
            }
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

    private func pickerLabel(_ text: String, icon: String) -> some View {
        HStack(spacing: 8) {
            SmthzIcon.image(icon).scaledToFit().frame(width: 14, height: 14)
            Text(text).font(SmthzFont.ui(size: 14))
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

    private func create() {
        onCreateShell()
        if createMore { name = "" } else { onDismiss() }
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

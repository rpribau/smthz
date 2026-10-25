// VISUAL-ONLY: stub data until M5 agents; Agent Prompt is visible but disabled.
import SwiftUI

struct QuickCommandDialog: View {
    @State private var draft: SmthzQuickCommand
    let isEditing: Bool
    let save: (SmthzQuickCommand) -> Void
    let cancel: () -> Void
    @State private var advanced = false

    init(command: SmthzQuickCommand, isEditing: Bool,
         save: @escaping (SmthzQuickCommand) -> Void, cancel: @escaping () -> Void) {
        _draft = State(initialValue: command)
        self.isEditing = isEditing
        self.save = save
        self.cancel = cancel
    }

    var body: some View {
        SmthzDialog(title: isEditing ? "Edit Quick Command" : "Add Quick Command",
                    description: "Saved items appear in the tab bar menu for one-click run.",
                    onDismiss: cancel) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Action").font(SmthzFont.ui(size: 14, weight: .medium))
                    HStack(spacing: 4) {
                        Text("Terminal Command")
                            .padding(.horizontal, 12).frame(height: 30)
                            .background(SmthzTheme.background, in: RoundedRectangle(cornerRadius: 8))
                            .accessibilityAddTraits(.isSelected)
                        Button("Agent Prompt") {}.buttonStyle(.plain).disabled(true)
                            .padding(.horizontal, 12).help("Not available yet")
                    }
                    .font(SmthzFont.ui(size: 12, weight: .medium))
                    .padding(3).background(SmthzTheme.muted, in: RoundedRectangle(cornerRadius: 10))
                }
                field("Label", placeholder: "Start dev server", text: $draft.label)
                field("Command", placeholder: "npm run dev", text: $draft.command)
                Toggle(isOn: $draft.appendEnter) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Append Enter — run immediately")
                        Text("Submit immediately instead of only inserting text.")
                            .font(SmthzFont.ui(size: 12)).foregroundStyle(SmthzTheme.mutedForeground)
                    }
                }.toggleStyle(SmthzSwitchStyle())
                DisclosureGroup("Advanced", isExpanded: $advanced) {
                    HStack {
                        Text("Scope")
                        Spacer()
                        Picker("Scope", selection: $draft.scope) {
                            ForEach(SmthzQuickCommand.Scope.allCases, id: \.self) { scope in
                                Text(scope.rawValue).tag(scope)
                            }
                        }.labelsHidden().pickerStyle(.segmented).frame(width: 200)
                    }.padding(.top, 10)
                    if draft.scope == .project {
                        Text("Default workspace").font(SmthzFont.ui(size: 12))
                            .foregroundStyle(SmthzTheme.mutedForeground).padding(.top, 4)
                    }
                }.tint(SmthzTheme.mutedForeground)
            }
        } footer: {
            Button("Cancel", action: cancel).buttonStyle(SmthzButtonStyle(.outline))
            Button("Save") { save(draft) }.buttonStyle(SmthzButtonStyle())
                .disabled(!draft.isValid).keyboardShortcut(.defaultAction)
        }
    }

    private func field(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(SmthzFont.ui(size: 14, weight: .medium))
            TextField(placeholder, text: text, axis: title == "Command" ? .vertical : .horizontal)
                .textFieldStyle(.plain).lineLimit(1...5)
                .font(SmthzFont.ui(size: 14)).padding(.horizontal, 12).padding(.vertical, 9)
                .background(SmthzTheme.input.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SmthzTheme.input))
                .accessibilityLabel(title)
        }
    }
}

/// UI-29: apply to the full shell, outside the Command button popover. The default
/// store is shared with QuickCommandsMenu(run:); inject the same store into both
/// when using a custom instance. Dismiss the popover before showing either dialog.
private struct SmthzQuickCommandDialogs: ViewModifier {
    @Bindable var store: SmthzQuickCommandStore

    func body(content: Content) -> some View {
        ZStack {
            content
                .blur(radius: store.editor == nil ? 0 : 2)
                .disabled(store.editor != nil)
                .accessibilityHidden(store.editor != nil)
            if let command = store.editor {
                Color.black.opacity(0.55).ignoresSafeArea().accessibilityHidden(true)
                QuickCommandDialog(command: command,
                                   isEditing: store.commands.contains { $0.id == command.id },
                                   save: store.save, cancel: { store.editor = nil })
                    .id(command.id).padding(24).zIndex(1)
            }
        }
        .smthzDialog(isPresented: Binding(
            get: { store.pendingDeletion != nil },
            set: { if !$0 { store.pendingDeletion = nil } }),
            title: "Delete \"\(store.pendingDeletion?.label ?? "")\"?",
            description: "This quick command will be removed from your saved list.", compact: true) {
                EmptyView()
            } footer: {
                Button("Cancel") { store.pendingDeletion = nil }.buttonStyle(SmthzButtonStyle(.outline))
                Button("Delete", role: .destructive) {
                    if let command = store.pendingDeletion { store.delete(command) }
                }.buttonStyle(SmthzButtonStyle()).keyboardShortcut(.defaultAction)
            }
    }
}

extension View {
    func smthzQuickCommandDialogs(store: SmthzQuickCommandStore = .shared) -> some View {
        modifier(SmthzQuickCommandDialogs(store: store))
    }
}

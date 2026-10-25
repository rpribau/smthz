import AppKit
import SwiftUI

/// Popover body for the tab strip's Command button. UI-29 presents this from
/// `TabStripView.command` and applies `.smthzQuickCommandDialogs()` to the shell.
/// `run` receives terminal-ready text, including CR when Append Enter is enabled.
/// Supply `dismiss` to close the popover before running or opening a dialog.
struct QuickCommandsMenu: View {
    var store: SmthzQuickCommandStore = .shared
    var projectID = "Default workspace"
    var canRun = true
    var dismiss: () -> Void = {}
    let run: (String) -> Void
    @State private var search = ""
    @State private var selectedID: UUID?
    @FocusState private var searchFocused: Bool

    private var visible: [SmthzQuickCommand] { store.visibleCommands(projectID: projectID) }
    private var filtered: [SmthzQuickCommand] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = query.isEmpty ? visible : visible.filter {
            $0.label.localizedCaseInsensitiveContains(query) || $0.command.localizedCaseInsensitiveContains(query)
        }
        return SmthzQuickCommand.Scope.allCases.flatMap { scope in matches.filter { $0.scope == scope } }
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                SmthzIcon.image("search").frame(width: 14, height: 14)
                    .foregroundStyle(SmthzTheme.mutedForeground)
                TextField("Search quick commands...", text: $search)
                    .textFieldStyle(.plain).focused($searchFocused)
                    .onSubmit {
                        if let command = filtered.first(where: { $0.id == selectedID }) ?? filtered.first {
                            execute(command)
                        }
                    }
                    .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                    .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
            }.padding(8)
            Divider().overlay(SmthzTheme.border.opacity(0.6))
            if filtered.isEmpty {
                Text(visible.isEmpty ? "No commands" : "No commands match")
                    .foregroundStyle(SmthzTheme.mutedForeground)
                    .frame(maxWidth: .infinity).padding(.vertical, 20)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(SmthzQuickCommand.Scope.allCases, id: \.self) { scope in
                                let commands = filtered.filter { $0.scope == scope }
                                if !commands.isEmpty {
                                    Text(scope.rawValue).font(SmthzFont.ui(size: 11, weight: .semibold))
                                        .foregroundStyle(SmthzTheme.mutedForeground)
                                        .padding(.horizontal, 8).padding(.top, 5)
                                    ForEach(commands) { command in
                                        SmthzQuickCommandRow(command: command, canRun: canRun,
                                            selected: selectedID == command.id,
                                            select: { selectedID = command.id },
                                            run: { execute(command) },
                                            edit: { dismiss(); store.editor = command },
                                            remove: { dismiss(); store.pendingDeletion = command })
                                            .id(command.id)
                                    }
                                }
                            }
                        }
                    }.frame(maxHeight: 300)
                        .onChange(of: selectedID) { _, id in
                            if let id { proxy.scrollTo(id) }
                        }
                }
            }
            Divider().overlay(SmthzTheme.border.opacity(0.6))
            Button {
                dismiss()
                store.editor = SmthzQuickCommand(projectID: projectID)
            } label: {
                HStack(spacing: 8) {
                    SmthzIcon.image("plus").frame(width: 14, height: 14)
                    Text("Command")
                    Spacer()
                }.padding(.horizontal, 8).frame(height: 28)
            }.buttonStyle(SmthzQuickCommandMenuButtonStyle())
                .accessibilityLabel("Add Quick Command")
        }
        .padding(4).frame(width: 320)
        .font(SmthzFont.ui(size: 12)).foregroundStyle(SmthzTheme.foreground)
        .background(SmthzTheme.popover.opacity(0.96), in: RoundedRectangle(cornerRadius: 11))
        .onAppear { searchFocused = true; selectedID = filtered.first?.id }
        .onChange(of: filtered.map(\.id)) { _, ids in
            if !ids.contains(where: { $0 == selectedID }) { selectedID = ids.first }
        }
        .onExitCommand(perform: dismiss)
    }

    private func moveSelection(_ offset: Int) {
        let commands = filtered
        guard !commands.isEmpty else { return }
        let index = commands.firstIndex(where: { $0.id == selectedID }) ?? (offset > 0 ? -1 : 0)
        selectedID = commands[(index + offset + commands.count) % commands.count].id
    }

    private func execute(_ command: SmthzQuickCommand) {
        guard canRun else { return }
        dismiss()
        run(command.terminalInput)
    }
}

private struct SmthzQuickCommandRow: View {
    let command: SmthzQuickCommand
    let canRun: Bool
    let selected: Bool
    let select: () -> Void
    let run: () -> Void
    let edit: () -> Void
    let remove: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 2) {
            Button(action: run) {
                HStack(spacing: 8) {
                    SmthzIcon.image("play").frame(width: 14, height: 14)
                        .foregroundStyle(SmthzTheme.mutedForeground)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(command.label).lineLimit(1)
                        Text(command.command).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(SmthzTheme.mutedForeground).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.padding(.leading, 8).padding(.vertical, 5)
                    .frame(maxWidth: .infinity, minHeight: 28).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!canRun)
                .help(canRun ? "Run: \(command.label)" : "Select a running terminal to run a command")
                .accessibilityLabel("Run: \(command.label)")
            HStack(spacing: 0) {
                action("copy", label: "Copy \(command.label)") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command.command, forType: .string)
                }
                action("pencil", label: "Edit \(command.label)", perform: edit)
                action("trash-2", label: "Remove \(command.label)", perform: remove)
            }
            .opacity(hovered || selected ? 1 : 0)
            .padding(.trailing, 4)
        }
        .background(hovered || selected ? SmthzTheme.accent : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .onHover { hovered = $0; if $0 { select() } }
    }

    private func action(_ icon: String, label: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            SmthzIcon.image(icon).frame(width: 14, height: 14).frame(width: 24, height: 24)
        }.buttonStyle(SmthzQuickCommandMenuButtonStyle()).help(label).accessibilityLabel(label)
    }
}

private struct SmthzQuickCommandMenuButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? SmthzTheme.accent : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

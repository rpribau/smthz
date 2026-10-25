// VISUAL-ONLY: stub data until agents, WebKit panes, mobile emulators, and Markdown editor backends.
import SwiftUI
import SmthzCore

/// Temporary host adapter. Tab presentation and local ordering can later be fed
/// directly by ShellController without changing the reusable strip.
struct TabStripSlot: View {
    let model: WorkspaceModel
    let newShell: () -> Void
    var command: (() -> Void)? = nil
    @State private var titles: [String: String] = [:]
    @State private var pinned: Set<String> = []
    @State private var order: [String] = []
    @State private var closing: Set<String> = []

    private var sessionIDs: [String] { model.sessions.map(\.id) }
    private var visibleIDs: [String] {
        let live = Set(sessionIDs).subtracting(closing)
        return order.filter { live.contains($0) }
            + sessionIDs.filter { live.contains($0) && !order.contains($0) }
    }
    private var tabs: [ShellTabItem] {
        visibleIDs.map { id in
            let index = sessionIDs.firstIndex(of: id) ?? 0
            return ShellTabItem(id: id, title: titles[id] ?? "Shell \(index + 1)",
                                pinned: pinned.contains(id), active: model.selectedSessionID == id)
        }
    }

    var body: some View {
        TabStripView(tabs: tabs,
            select: { model.selectedSessionID = $0 }, close: close,
            rename: { titles[$0] = $1 }, togglePin: togglePin,
            reorder: reorder, command: command,
            createActions: [
                TabCreateAction(id: "shell", title: "New Terminal", icon: .squareTerminal,
                                enabled: model.hostIsRunning && !model.creatingShell,
                                shortcut: "⌘T", perform: newShell),
                // VISUAL-ONLY: stub data until agents, WebKit panes, and the Markdown editor backends.
                TabCreateAction(id: "agent", title: "Launch agent", icon: .bot, enabled: false,
                                shortcut: "⌥⌘T", unavailableReason: "Not available yet", perform: {}),
                TabCreateAction(id: "browser", title: "New Browser Tab", icon: .globe, enabled: false,
                                shortcut: "⌘⇧B", unavailableReason: "Not available yet", perform: {}),
                TabCreateAction(id: "emulator", title: "New Mobile Emulator", icon: .smartphone, enabled: false,
                                shortcut: "⌥⌘⇧E", unavailableReason: "Not available yet", perform: {}),
                TabCreateAction(id: "markdown", title: "New Markdown", icon: "file-plus", enabled: false,
                                shortcut: "⌘⇧M", unavailableReason: "Not available yet", perform: {}),
                TabCreateAction(id: "open-markdown", title: "Open Markdown...", icon: "file-text", enabled: false,
                                shortcut: "⌘⇧O", unavailableReason: "Not available yet", perform: {})
            ])
        .padding(.trailing, 32)
        .onChange(of: sessionIDs, initial: true) { _, ids in
            let live = Set(ids)
            order = order.filter { live.contains($0) } + ids.filter { !order.contains($0) }
            titles = titles.filter { live.contains($0.key) }
            pinned.formIntersection(live)
            closing.formIntersection(live)
            ensureSelection()
        }
        .onChange(of: model.selectedSessionID) { _, _ in ensureSelection() }
    }

    private func ensureSelection() {
        if model.selectedSessionID == nil || !visibleIDs.contains(model.selectedSessionID ?? "") {
            model.selectedSessionID = visibleIDs.first
        }
    }

    private func togglePin(_ id: String) {
        if !pinned.insert(id).inserted { pinned.remove(id) }
    }

    private func reorder(_ source: String, _ target: String, _ after: Bool) {
        var ids = visibleIDs.filter { $0 != source }
        guard let index = ids.firstIndex(of: target) else { return }
        ids.insert(source, at: index + (after ? 1 : 0))
        order = ids
    }

    private func close(_ id: String) {
        guard !pinned.contains(id), !closing.contains(id) else { return }
        let ids = visibleIDs
        let index = ids.firstIndex(of: id) ?? 0
        closing.insert(id)
        if model.selectedSessionID == id {
            let remaining = visibleIDs
            model.selectedSessionID = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)]
        }
        let socketPath = model.socketPath
        Task {
            do {
                try await TabSessionCloser.close(id: id, socketPath: socketPath)
                // Host retains exited session records; keep closed tabs hidden for this window.
            } catch {
                closing.remove(id)
                model.actionError = "Could not close shell: \(error)"
                ensureSelection()
            }
        }
    }
}

private actor TabSessionCloser {
    static func close(id: String, socketPath: String) async throws {
        try await Task.detached {
            let client = try HostClient(socketPath: socketPath)
            defer { client.disconnect() }
            _ = try client.close(id: id)
        }.value
    }
}

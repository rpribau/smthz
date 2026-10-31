import AppKit
import Combine
import Observation
import SmthzCore
import UserNotifications

struct AttentionItem: Codable, Identifiable {
    var id = UUID().uuidString
    let sessionID: String
    let workspaceName: String
    let title: String
    let body: String
    var date = Date()
    var unread = true
}

@MainActor @Observable final class AttentionModel: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AttentionModel()
    static let openSession = Notification.Name("smthz.attention.openSession")
    static let systemSounds = ["Default", "None", "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]
    private(set) var items: [AttentionItem] = []
    private(set) var lastError: String?
    var surfaceVisible = false
    private weak var appModel: AppModel?
    private var previous: [String: String] = [:]
    private var activation: AnyCancellable?
    private var storeURL: URL?

    func attach(to model: AppModel) {
        guard appModel == nil else { return }
        appModel = model
        UserDefaults.standard.register(defaults: ["notifications.enabled": true,
            "notifications.agentTaskComplete": true, "notifications.suppressWhenFocused": true,
            "notifications.sound": "Default"])
        storeURL = model.workspace.stateURL.deletingLastPathComponent().appendingPathComponent("attention.json")
        if let url = storeURL, FileManager.default.fileExists(atPath: url.path) {
            do { items = try JSONDecoder().decode([AttentionItem].self, from: Data(contentsOf: url)) }
            catch { lastError = "Could not load attention history: \(error)" }
        }
        UNUserNotificationCenter.current().delegate = self
        NSApp.dockTile.badgeLabel = AttentionRules.badgeLabel(unreadCount: items.filter(\.unread).count)
        activation = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.markVisibleRead() } }
        // The tab strip's polling task is cancelled while Settings hides it; keep reads alive app-wide.
        Task {
            while !Task.isCancelled {
                await AgentStatusModel.shared.startPolling()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        observe()
    }

    private func observe() {
        guard let appModel else { return }
        let rows = withObservationTracking {
            _ = appModel.workspace.state
            _ = appModel.workspace.activeKey
            _ = appModel.destination
            _ = BrowserTabStore.shared.activeID
            _ = surfaceVisible
            return AgentStatusModel.shared.rows
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        var added = false
        for row in rows.values {
            guard let event = AttentionRules.transition(from: previous[row.sessionID], to: row.state) else { continue }
            let shell = appModel.workspace
            let workspace = shell.state.workspaces.values.first { layout in
                layout.panes.values.contains { $0.binding?.sessionID == row.sessionID }
            }
            let name = workspace?.displayName ?? AgentStatusModel.shared.sessions[row.sessionID]?.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Workspace"
            let agent = AgentStatusModel.shared.agentName(row.sessionID)
            let item = AttentionItem(sessionID: row.sessionID, workspaceName: name,
                title: event == .done ? "\(agent) finished" : "\(agent) needs attention",
                body: row.message ?? row.prompt ?? (event == .done ? "Task complete." : "Waiting for your input."),
                unread: !isVisible(row.sessionID))
            items.insert(item, at: 0)
            added = true
            let settings = UserDefaults.standard
            if AttentionRules.shouldNotify(enabled: settings.bool(forKey: "notifications.enabled"),
                agentTaskComplete: settings.bool(forKey: "notifications.agentTaskComplete"),
                suppressWhenFocused: settings.bool(forKey: "notifications.suppressWhenFocused"),
                appIsFrontmost: NSApp.isActive, tabIsVisible: visibleSessionIDs.contains(row.sessionID)) {
                deliver(item)
            }
        }
        previous = rows.mapValues(\.state)
        markVisibleRead()
        if added { save() }
    }

    private var visibleSessionIDs: Set<String> {
        guard let model = appModel, surfaceVisible, model.destination == .workspaces,
              BrowserTabStore.shared.activeID == nil else { return [] }
        let layout = model.workspace.workspace
        return Set((layout.groupLayout?.leaves ?? []).flatMap { groupID -> [String] in
            guard let id = layout.groups[groupID]?.activeTab, let tab = layout.tabs[id] else { return [] }
            return (tab.expandedPane.map { [$0] } ?? tab.panes.leaves).compactMap { layout.panes[$0]?.binding?.sessionID }
        })
    }
    private func isVisible(_ session: String) -> Bool { NSApp.isActive && visibleSessionIDs.contains(session) }

    func markRead(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].unread = false
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
        save()
    }
    func markAllRead() {
        let ids = items.filter(\.unread).map(\.id)
        for index in items.indices { items[index].unread = false }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        save()
    }
    private func markVisibleRead() {
        for item in items where item.unread && isVisible(item.sessionID) { markRead(item.id) }
    }
    private func save() {
        NSApp.dockTile.badgeLabel = AttentionRules.badgeLabel(unreadCount: items.filter(\.unread).count)
        guard let storeURL else { return }
        do {
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(items).write(to: storeURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeURL.path)
        } catch { lastError = "Could not save attention history: \(error)" }
    }

    func open(_ item: AttentionItem) {
        guard let model = appModel else { return }
        if let layout = model.workspace.state.workspaces.values.first(where: { $0.panes.values.contains { $0.binding?.sessionID == item.sessionID } }) {
            model.workspace.activateWorkspace(layout.key, displayName: layout.displayName, rootPath: layout.rootPath)
        }
        model.destination = .workspaces
        NotificationCenter.default.post(name: Self.openSession, object: item.sessionID)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        markRead(item.id)
    }

    private func deliver(_ item: AttentionItem) {
        let content = UNMutableNotificationContent()
        content.title = item.title
        content.subtitle = item.workspaceName
        content.body = item.body
        content.userInfo = ["attentionID": item.id]
        let selected = UserDefaults.standard.string(forKey: "notifications.sound") ?? "Default"
        let sound = Self.systemSounds.contains(selected) ? selected : "Default"
        content.sound = sound == "Default" ? .default : nil
        Task {
            do {
                let authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
                guard authorization == .authorized || authorization == .provisional else { return }
                try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: item.id, content: content, trigger: nil))
                // System sounds live outside the bundle; play by NSSound name, never accept a path.
                if sound != "None", sound != "Default" { NSSound(named: NSSound.Name(sound))?.play() }
            } catch { lastError = "Notification delivery failed: \(error)" }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.identifier
        Task { @MainActor in
            if let item = self.items.first(where: { $0.id == id }) { self.open(item) }
        }
        completionHandler()
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func dockMenu() -> NSMenu {
        let menu = NSMenu()
        for item in items where item.unread {
            let entry = NSMenuItem(title: "\(item.workspaceName): \(item.title)", action: #selector(openFromDock(_:)), keyEquivalent: "")
            entry.target = self; entry.representedObject = item.id; menu.addItem(entry)
        }
        if items.contains(where: \.unread) {
            let read = NSMenuItem(title: "Mark All as Read", action: #selector(readFromDock), keyEquivalent: "")
            read.target = self; menu.addItem(read)
        }
        let sounds = NSMenu()
        for name in Self.systemSounds {
            let entry = NSMenuItem(title: name, action: #selector(selectSound(_:)), keyEquivalent: "")
            entry.target = self; entry.representedObject = name
            entry.state = (UserDefaults.standard.string(forKey: "notifications.sound") ?? "Default") == name ? .on : .off
            sounds.addItem(entry)
        }
        let sound = NSMenuItem(title: "Notification Sound", action: nil, keyEquivalent: "")
        sound.submenu = sounds; menu.addItem(sound)
        return menu
    }
    @objc private func openFromDock(_ sender: NSMenuItem) {
        if let item = items.first(where: { $0.id == sender.representedObject as? String }) { open(item) }
    }
    @objc private func readFromDock() { markAllRead() }
    @objc private func selectSound(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, Self.systemSounds.contains(name) else { return }
        UserDefaults.standard.set(name, forKey: "notifications.sound")
    }
}

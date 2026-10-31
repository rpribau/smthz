import SwiftUI
import SmthzCore

/// New Tab menu entries: the placeholder "agent" action becomes one row per detected agent.
enum AgentLauncher {
    @MainActor static func actions(replacing actions: [TabCreateAction], cwd: String?) -> [TabCreateAction] {
        actions.flatMap { $0.id == "agent" ? agentActions(cwd: cwd) : [$0] }
    }

    @MainActor private static func agentActions(cwd: String?) -> [TabCreateAction] {
        let model = AgentStatusModel.shared
        let directory = cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        let launches = model.detected.map { agent in
            TabCreateAction(id: "agent-\(agent.id.rawValue)", title: "New \(agent.id.rawValue) agent", icon: .bot) {
                Task { await model.launch(AgentLaunchRequest(agent: agent.id, cwd: directory)) }
            }
        }
        let status = model.detecting ? "Detecting agents…" : launches.isEmpty ? "No agents detected" : "Rescan agents"
        return launches + [TabCreateAction(id: "agent-rescan", title: status, icon: .bot, enabled: !model.detecting) {
            Task { await model.refreshDetected() }
        }]
    }
}

extension View {
    /// Starts status polling and selects a freshly launched agent's tab once the shell adopted it.
    func agentTabSelection(tabIDs: [String], select: @escaping (String) -> Void) -> some View {
        let model = AgentStatusModel.shared
        return self
            .task { await model.refreshDetected() }
            .task { await model.startPolling() }
            .onChange(of: tabIDs + [model.pendingSelection ?? ""]) {
                if let id = model.pendingSelection, tabIDs.contains(id) { model.pendingSelection = nil; select(id) }
            }
    }
}

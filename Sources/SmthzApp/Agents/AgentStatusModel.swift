import Foundation
import SmthzCore

/// App-wide view of agent sessions: detected agents (`agent.list`), live status rows
/// (`agent.status.list`) and session liveness (`session.list`), polled once a second.
@MainActor @Observable final class AgentStatusModel {
    static let shared = AgentStatusModel()

    private(set) var detected: [DetectedAgent] = []
    private(set) var detecting = false
    private(set) var rows: [String: HostAgentStatusRow] = [:]
    private(set) var sessions: [String: SessionInfo] = [:]
    var lastError: String?
    /// Session the tab strip should select once its tab has been adopted.
    var pendingSelection: String?
    // shortcut: launch requests live in app memory only, so a restart chip after an app relaunch
    // re-launches from the status row's agent + session cwd; persist them if that proves too lossy.
    private var launches: [String: AgentLaunchRequest] = [:]
    private var polling = false

    private static func withClient<T: Sendable>(_ body: @escaping @Sendable (HostClient) throws -> T) async throws -> T {
        let socket = HostController.socketPath
        return try await Task.detached {
            let client = try HostClient(socketPath: socket)
            defer { client.disconnect() }
            return try body(client)
        }.value
    }

    /// Agent sessions, newest first: every launch plus every session the host reports a status for.
    var agentSessionIDs: [String] {
        Set(launches.keys).union(rows.keys).sorted {
            (sessions[$0]?.createdAt ?? .infinity) > (sessions[$1]?.createdAt ?? .infinity)
        }
    }
    func status(_ sessionID: String) -> HostAgentStatusRow? { rows[sessionID] }
    /// An agent session whose process has exited (the host still lists it).
    func exited(_ sessionID: String) -> Bool {
        (launches[sessionID] != nil || rows[sessionID] != nil) && sessions[sessionID]?.running == false
    }
    func agentName(_ sessionID: String) -> String {
        launches[sessionID]?.agent.rawValue ?? rows[sessionID]?.agent?.rawValue
            ?? sessions[sessionID]?.executable.map { ($0 as NSString).lastPathComponent } ?? "agent"
    }

    /// Most urgent live status of the agents running under `root` (blocked > error > working > done).
    func aggregateState(under root: String) -> String? {
        let states = rows.values.compactMap { row -> String? in
            guard let session = sessions[row.sessionID], session.running, let cwd = session.cwd,
                  WorkspaceSelectors.contains(root: root, path: cwd) else { return nil }
            return row.state
        }
        return ["blocked", "error", "working", "done"].first { states.contains($0) }
    }

    func startPolling() async {
        guard !polling else { return }
        polling = true
        defer { polling = false }
        while !Task.isCancelled {
            do {
                let (statuses, list) = try await Self.withClient { client in
                    (try client.agentStatuses(), try client.list().sessions)
                }
                rows = Dictionary(statuses.map { ($0.sessionID, $0) }, uniquingKeysWith: { $1 })
                sessions = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
            } catch {
                // Host down: drop rows so no stale "working" badges remain.
                rows = [:]
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    func refreshDetected() async {
        guard !detecting else { return }
        detecting = true
        defer { detecting = false }
        do { detected = try await Self.withClient { try $0.listAgents() } }
        catch { lastError = "Could not detect agents: \(error)" }
    }

    @discardableResult func launch(_ request: AgentLaunchRequest) async -> String? {
        do {
            let session = try await Self.withClient { try $0.launchAgent(request) }
            launches[session.id] = request
            sessions[session.id] = session
            pendingSelection = session.id
            return session.id
        } catch {
            lastError = "Could not launch \(request.agent.rawValue): \(error)"
            return nil
        }
    }

    /// Restart chip: start the same agent again in the same directory (a new tab).
    func restart(_ sessionID: String) async {
        if let request = launches[sessionID] { await launch(request); return }
        guard let id = rows[sessionID]?.agent.flatMap({ AgentID(rawValue: $0.rawValue) }),
              let cwd = sessions[sessionID]?.cwd else {
            lastError = "Cannot restart: unknown agent for this session"
            return
        }
        await launch(AgentLaunchRequest(agent: id, cwd: cwd))
    }
}

extension AgentStatusModel {
    /// Workspace card status from the agents running in it; other card states keep precedence.
    func decorate(_ data: WorkspaceCardData, root: String?) -> WorkspaceCardData {
        guard let root, data.status == .idle || data.status == .live, let state = aggregateState(under: root) else { return data }
        var data = data
        // shortcut: the card slot has no "done" glyph, so done shows as the green live dot; add one with M5 attention.
        data.status = switch state { case "blocked": .question; case "error": .error; case "working": .working; default: .live }
        return data
    }
}

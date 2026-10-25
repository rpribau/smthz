import Foundation
import Observation
import SwiftUI
import SmthzCore

/// Last cell grid reported by a terminal view; new shells start at this size instead of 80x24.
@MainActor enum TerminalSizeHint {
    static var latest: (rows: Int, cols: Int)?
}

/// Each call owns a short-lived connection; synchronous RPC never runs on the UI actor.
private actor SessionConnection {
    let socketPath: String

    init(socketPath: String) { self.socketPath = socketPath }

    func createShell(size: (rows: Int, cols: Int)?) throws -> SessionInfo {
        let client = try HostClient(socketPath: socketPath)
        defer { client.disconnect() }
        return try client.createSession(executable: "/bin/zsh", arguments: ["-l"],
                                        cwd: FileManager.default.homeDirectoryForCurrentUser.path,
                                        rows: size?.rows ?? 24, cols: size?.cols ?? 80)
    }
    func close(id: String) throws {
        let client = try HostClient(socketPath: socketPath)
        defer { client.disconnect() }
        _ = try client.close(id: id)
    }
    func write(id: String, text: String) throws {
        let client = try HostClient(socketPath: socketPath)
        defer { client.disconnect() }
        _ = try client.write(id: id, data: Data(text.utf8))
    }
}

@MainActor @Observable
final class WorkspaceModel {
    private(set) var snapshot: HostSnapshot?
    var selectedSessionID: String? {
        didSet {
            if let id = selectedSessionID, id != oldValue {
                recentIDs.removeAll { $0 == id }; recentIDs.insert(id, at: 0)
            }
        }
    }
    var titles: [String: String] = [:]
    var userTitles: [String: String] = [:]
    var colours: [String: Color] = [:]
    var pinned: Set<String> = []
    var order: [String] = []
    var closed: Set<String> = []
    var directories: [String: String] = [:]
    var recentIDs: [String] = []
    var workspaceTitle = "Default workspace"
    var workspacePinned = false
    var workspaceUnread = false
    var terminalFontSize: Double = 14
    private(set) var creatingShell = false
    var actionError: String?
    private let connection: SessionConnection
    let socketPath: String

    init() {
        // Same default endpoint as the CLI and host. No host is started implicitly.
        let home = FileManager.default.homeDirectoryForCurrentUser
        // SMTHZ_SOCKET lets tests and side-by-side hosts point the app at another endpoint.
        socketPath = ProcessInfo.processInfo.environment["SMTHZ_SOCKET"]
            ?? ApplicationIdentity.applicationSupportDirectory(home: home).appending(path: "smthzd.sock").path
        connection = SessionConnection(socketPath: socketPath)
    }

    var sessions: [SessionInfo] { snapshot?.sessions ?? [] }
    var visibleIDs: [String] {
        let ids = sessions.map(\.id).filter { !closed.contains($0) }
        return order.filter { ids.contains($0) } + ids.filter { !order.contains($0) }
    }
    func title(_ id: String) -> String {
        userTitles[id] ?? titles[id] ?? "Shell \((sessions.firstIndex { $0.id == id } ?? 0) + 1)"
    }
    var tabs: [ShellTabItem] {
        visibleIDs.map { id in
            ShellTabItem(id: id, title: title(id), colour: colours[id], pinned: pinned.contains(id),
                         active: selectedSessionID == id, cwd: directory(id))
        }
    }
    func directory(_ id: String) -> String? { directories[id] ?? sessions.first { $0.id == id }?.cwd }
    var rootURL: URL? { selectedSessionID.flatMap { directory($0) }.map { URL(fileURLWithPath: $0) } }
    func togglePin(_ id: String) { if !pinned.insert(id).inserted { pinned.remove(id) } }
    func reorder(_ source: String, _ target: String, _ after: Bool) {
        var ids = visibleIDs.filter { $0 != source }
        guard let index = ids.firstIndex(of: target) else { return }
        ids.insert(source, at: index + (after ? 1 : 0)); order = ids
    }
    func close(_ id: String) async {
        do {
            try await connection.close(id: id)
            closed.insert(id)
            if selectedSessionID == id { selectedSessionID = visibleIDs.first }
        } catch { actionError = "Could not close terminal: \(error)" }
    }
    func write(_ text: String) async {
        guard let id = selectedSessionID else { return }
        do { try await connection.write(id: id, text: text) }
        catch { actionError = "Could not write to terminal: \(error)" }
    }
    func replace(_ id: String, with session: SessionInfo) {
        order = visibleIDs.map { $0 == id ? session.id : $0 }
        closed.insert(id)
        userTitles[session.id] = userTitles[id]; colours[session.id] = colours[id]
        if pinned.contains(id) { pinned.insert(session.id) }
        if let snapshot {
            self.snapshot = HostSnapshot(state: snapshot.state,
                sessions: snapshot.sessions.filter { $0.id != session.id } + [session])
        }
        selectedSessionID = session.id
    }
    var hostIsRunning: Bool {
        if case .running = snapshot?.state { return true }
        return false
    }

    var hostLabel: String {
        switch snapshot?.state {
        case .none: "Connecting to host"
        case .notRunning: "Host not running"
        case .running: "Local host connected"
        case .error: "Host connection error"
        }
    }

    var hostDetail: String {
        switch snapshot?.state {
        case .running(let identity, let version): "smthzd \(version) · PID \(identity.pid)"
        case .error(let message): message
        case .notRunning: "Start smthzd to connect. This window reconnects automatically."
        case .none: "Checking the local host."
        }
    }

    func observeHost() async {
        let monitor = HostMonitor(socketPath: socketPath)
        await monitor.start()
        for await value in monitor.snapshots {
            guard !Task.isCancelled else { break }
            snapshot = value
            if let id = selectedSessionID, !value.sessions.contains(where: { $0.id == id }) {
                selectedSessionID = nil
            }
        }
        await monitor.stop()
    }

    func newShell() async {
        guard hostIsRunning, !creatingShell else { return }
        creatingShell = true
        defer { creatingShell = false }
        do {
            let session = try await connection.createShell(size: TerminalSizeHint.latest)
            // Include the new session immediately; the next host snapshot reconciles it.
            if let snapshot {
                self.snapshot = HostSnapshot(state: snapshot.state,
                    sessions: snapshot.sessions.filter { $0.id != session.id } + [session])
            }
            selectedSessionID = session.id
        } catch {
            actionError = String(describing: error)
        }
    }
}

import AppKit
import Foundation
import Observation
import SmthzCore
import SwiftUI

/// One lifecycle owner for all windows. ShellController remains the session/layout owner.
@MainActor @Observable
final class HostController {
    static let shared = HostController()

    static var stateDirectory: URL {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-SmthzStateDirectory"), arguments.indices.contains(index + 1) {
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        return ApplicationIdentity.applicationSupportDirectory(home: FileManager.default.homeDirectoryForCurrentUser)
    }
    static var socketPath: String {
        ProcessInfo.processInfo.environment["SMTHZ_SOCKET"]
            ?? stateDirectory.appendingPathComponent("smthzd.sock").path
    }

    let externallyManaged = ProcessInfo.processInfo.environment["SMTHZ_SOCKET"] != nil
    private let endpoint: HostEndpoint
    private let launcher: HostLauncher
    private var identity: ProcessIdentity?
    private var sessions: [SessionInfo] = []
    private var suppressed = false
    // NSAlert must outlive its asynchronous sheet; releasing it can dismiss
    // the sheet and deliver a default response before the user chooses.
    private var confirmationAlert: NSAlert?
    private(set) var busy = false
    private(set) var label = "Connecting to host"
    private(set) var detail = "Checking the local host."
    private(set) var symbol = "circle.dotted"
    private(set) var connected = false

    var autoStartHost: Bool {
        get { UserDefaults.standard.object(forKey: "autoStartHost") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "autoStartHost")
            if newValue { suppressed = false; start() }
        }
    }
    var canStart: Bool { !externallyManaged && !busy && !connected }
    var canStop: Bool { !externallyManaged && !busy && identity != nil }

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        endpoint = Self.stateDirectory == ApplicationIdentity.applicationSupportDirectory(home: home)
            ? .standard(home: home) : HostEndpoint(stateDirectory: Self.stateDirectory)
        let executable = Bundle.main.url(forAuxiliaryExecutable: "smthzd")
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
                .deletingLastPathComponent().appendingPathComponent("smthzd")
        launcher = HostLauncher(endpoint: endpoint, executable: executable)
        Task { await observe() }
    }

    private func observe() async {
        let monitor = HostMonitor(socketPath: Self.socketPath)
        if autoStartHost && !externallyManaged { await ensureRunning() }
        await monitor.start()
        for await snapshot in monitor.snapshots {
            sessions = snapshot.sessions
            guard !busy else { continue }
            switch snapshot.state {
            case .running(let id, let version):
                identity = id
                connected = true
                if version != ApplicationIdentity.version {
                    label = "Host version incompatible"
                    symbol = "exclamationmark.triangle"
                    detail = "Host \(version) differs from app \(ApplicationIdentity.version). Restart host (\(sessions.filter(\.running).count) sessions will end)."
                } else {
                    label = "Local host connected"
                    symbol = "checkmark.circle"
                    detail = "smthzd \(version) · PID \(id.pid)" + (externallyManaged ? " · Externally managed (SMTHZ_SOCKET)" : "")
                }
            case .notRunning:
                connected = false
                // Retain the last verified identity for safe shutdown fallback, never a bare pid.
                if let id = identity, !id.isStillRunning() { identity = nil }
                if autoStartHost && !suppressed && !externallyManaged {
                    await ensureRunning()
                } else {
                    label = "Host not running"
                    detail = externallyManaged ? "External host selected by SMTHZ_SOCKET; automatic launch is disabled." : "Use Host → Start Host to connect."
                    symbol = "stop.circle"
                }
            case .error(let message):
                connected = false
                label = message.contains("protocolVersionMismatch") ? "Host protocol incompatible" : "Host unreachable"
                symbol = "exclamationmark.triangle"
                detail = message
            }
        }
        await monitor.stop()
    }

    func start() {
        guard !externallyManaged, !busy else { return }
        suppressed = false
        Task { await ensureRunning() }
    }

    private func ensureRunning() async {
        guard !externallyManaged, !busy else { return }
        busy = true
        defer { busy = false }
        let result = await launcher.ensureRunning()
        switch result {
        case .startedByUs(let id):
            identity = id; connected = true
            label = "Local host connected"; symbol = "checkmark.circle"
            detail = "smthzd \(ApplicationIdentity.version) · PID \(id.pid)"
        case .running(let id, let version, let compatible):
            identity = id; connected = true
            label = compatible ? "Local host connected" : "Host version incompatible"
            symbol = compatible ? "checkmark.circle" : "exclamationmark.triangle"
            detail = compatible ? "smthzd \(version) · PID \(id.pid)" : "Host \(version) differs from app \(ApplicationIdentity.version). Restart requires confirmation."
        case .unreachable(let reason):
            connected = false; label = reason.contains("protocolVersionMismatch") ? "Host protocol incompatible" : "Host unreachable"; detail = reason; symbol = "exclamationmark.triangle"
        case .throttled:
            connected = false; label = "Host keeps failing to start. View log / Retry"
            detail = "At most three launch attempts are allowed in 60 seconds. Use Host → Show Host Log or Start Host to retry."
            symbol = "exclamationmark.octagon"
        case .failed(_, let tail):
            connected = false; label = "Host failed to start"; detail = tail; symbol = "exclamationmark.triangle"
        }
    }

    func confirmStop(restart: Bool = false) {
        guard canStop, let expected = identity else { return }
        busy = true
        Task {
            do {
                let socket = Self.socketPath
                let running = try await Task.detached {
                    let client = try HostClient(socketPath: socket)
                    defer { client.disconnect() }
                    return try client.list().sessions.filter(\.running)
                }.value
                showConfirmation(expected: expected, running: running, restart: restart)
            } catch {
                showConfirmation(expected: expected, running: sessions.filter(\.running), restart: restart,
                    warning: "Could not refresh the session list (\(error)). The list below is the last observation; all host sessions will end.")
            }
        }
    }

    private func showConfirmation(expected: ProcessIdentity, running: [SessionInfo], restart: Bool, warning: String? = nil) {
        let alert = NSAlert()
        alert.messageText = restart ? "Restart Host?" : "Stop Host?"
        alert.informativeText = running.isEmpty ? "No running sessions."
            : "\(running.count) running sessions will end:\n" + running.map { "\($0.executable ?? "Terminal") · PID \($0.pid) · \($0.id)" }.joined(separator: "\n")
        if let warning { alert.informativeText = warning + "\n\nLast known sessions:\n" + alert.informativeText }
        alert.alertStyle = .warning
        alert.addButton(withTitle: restart ? "Restart Host" : "Stop Host")
        alert.addButton(withTitle: "Cancel")
        // Menu activation can temporarily clear key/mainWindow. Prefer the
        // visible workspace window rather than entering a nested app modal loop.
        if let window = NSApp.keyWindow ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
            confirmationAlert = alert
            alert.beginSheetModal(for: window) { [weak self] response in
                self?.confirmationAlert = nil
                self?.busy = false
                guard response == .alertFirstButtonReturn else { return }
                self?.stop(expected: expected, restart: restart)
            }
        } else {
            let response = alert.runModal()
            busy = false
            if response == .alertFirstButtonReturn { stop(expected: expected, restart: restart) }
        }
    }

    private func stop(expected: ProcessIdentity, restart: Bool) {
        guard !busy else { return }
        // Explicit Stop remains stopped even when the auto-start preference is on.
        suppressed = true
        busy = true
        Task {
            do {
                try await launcher.stop(expected: expected)
                identity = nil; connected = false; sessions = []
                label = "Host not running"; detail = "Stopped by the user."; symbol = "stop.circle"
                busy = false
                if restart { suppressed = false; await ensureRunning() }
            } catch {
                label = "Could not stop host"; detail = String(describing: error)
                symbol = "exclamationmark.triangle"; busy = false
            }
        }
    }

    func showLog() { NSWorkspace.shared.open(URL(fileURLWithPath: endpoint.logPath)) }
    func showStatus() {
        let alert = NSAlert()
        alert.messageText = label
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

struct SmthzHostCommands: Commands {
    private let host = HostController.shared
    var body: some Commands {
        CommandMenu("Host") {
            Button("Status: \(host.label)") { host.showStatus() }
            Divider()
            Button("Start Host") { host.start() }.disabled(!host.canStart)
            Button("Stop Host…") { host.confirmStop() }.disabled(!host.canStop)
            Button("Restart Host…") { host.confirmStop(restart: true) }.disabled(!host.canStop)
            Divider()
            Toggle("Start Host Automatically", isOn: Binding(get: { host.autoStartHost }, set: { host.autoStartHost = $0 }))
                .disabled(host.externallyManaged)
            Button("Show Host Log") { host.showLog() }.disabled(host.externallyManaged)
        }
    }
}

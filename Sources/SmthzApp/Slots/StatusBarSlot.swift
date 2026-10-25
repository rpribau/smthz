import SmthzCore
import SwiftUI

struct StatusBarSlot: View {
    let model: ShellController
    var goToSession: ((String) -> Void)? = nil
    @State private var visibility = StatusBarVisibility()

    var body: some View {
        StatusBarView(
            hostIsRunning: model.hostIsRunning,
            hostLabel: model.hostLabel,
            hostDetail: model.hostDetail,
            sessionCount: model.sessions.filter(\.running).count,
            sessions: model.sessions,
            hostPID: hostPID,
            visibility: visibility,
            onGoToSession: { session in
                if let goToSession { goToSession(session.id) } else { model.selectedSessionID = session.id }
            },
            onEndSession: endSession)
    }

    private var hostPID: Int32? {
        if case .running(let identity, _) = model.snapshot?.state { return identity.pid }
        return nil
    }

    /// `session.close` escalates SIGHUP/SIGTERM/SIGKILL over the whole process group; the next
    /// host snapshot drops the row. Each call owns a short-lived connection off the main actor.
    private func endSession(_ session: SessionInfo) {
        Task { await model.close(session.id) }
    }
}

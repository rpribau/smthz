import SwiftUI
import SmthzCore

/// Agent state for one session: spinner (working), "?" (blocked), check (done), dot (error),
/// and a restart chip once the agent process has exited. Empty for non-agent sessions.
struct AgentStatusBadge: View {
    let sessionID: String
    private var model: AgentStatusModel { .shared }

    var body: some View {
        if model.exited(sessionID) {
            AgentRestartChip(sessionID: sessionID)
        } else if let row = model.status(sessionID) {
            AgentStateIcon(state: row.state)
                .smthzTooltip(Self.label(row))
                .accessibilityLabel(Self.label(row))
        }
    }

    static func label(_ row: HostAgentStatusRow) -> String {
        switch row.state {
        case "blocked": "Agent needs attention" + (row.kind.map { " (\($0.rawValue))" } ?? "")
        case "working": "Agent working"
        case "done": "Agent done"
        case "error": "Agent error"
        default: "Agent idle"
        }
    }
}

struct AgentStateIcon: View {
    let state: String
    @State private var spinning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch state {
            case "working":
                Circle().trim(from: 0.15, to: 0.9)
                    .stroke(SmthzTheme.agentWorking, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .frame(width: 8, height: 8)
                    .rotationEffect(.degrees(spinning && !reduceMotion ? 360 : 0))
                    .animation(reduceMotion ? nil : .linear(duration: 0.8).repeatForever(autoreverses: false), value: spinning)
                    .onAppear { spinning = true }.onDisappear { spinning = false }
            case "blocked": SmthzIcon.image("circle-help").foregroundStyle(SmthzTheme.agentQuestion)
            case "done": Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(SmthzTheme.statusSuccess)
            case "error": Circle().fill(SmthzTheme.destructive).frame(width: 6, height: 6)
            default: Circle().fill(Color.gray.opacity(0.4)).frame(width: 6, height: 6)
            }
        }
        .frame(width: 12, height: 12)
    }
}

struct AgentRestartChip: View {
    let sessionID: String

    var body: some View {
        Button { Task { await AgentStatusModel.shared.restart(sessionID) } } label: {
            HStack(spacing: 3) {
                SmthzIcon.view("rotate-cw", size: 10)
                Text("Restart").font(SmthzFont.ui(size: 10, weight: .medium))
            }
            .padding(.horizontal, 5).frame(height: 16)
            .background(SmthzTheme.muted, in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Agent exited: launch it again in a new tab")
        .accessibilityLabel("Restart agent")
    }
}

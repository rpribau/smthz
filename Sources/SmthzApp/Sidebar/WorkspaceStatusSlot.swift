import SwiftUI

// Creation/failed/live states are real (WP-M4-WORKTREE-APP); agent statuses stay VISUAL-ONLY until M5.
struct SmthzWorkspaceStatusSlot: View {
    let data: WorkspaceCardData
    var markRead: (() -> Void)?
    @State private var hovered = false
    @State private var spinning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if data.isUnread {
                if let markRead {
                    Button(action: markRead) { unreadBell }.buttonStyle(.plain)
                } else { unreadBell }
            } else if data.isSleeping { icon("moon", color: SmthzTheme.mutedForeground) }
            else {
                switch data.status {
                case .working:
                    Circle().trim(from: 0.15, to: 0.9)
                        .stroke(SmthzTheme.agentWorking, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .frame(width: 8, height: 8).frame(width: 12, height: 12)
                        .rotationEffect(.degrees(spinning && !reduceMotion ? 360 : 0))
                        .animation(reduceMotion ? nil : Animation.linear(duration: 0.8).repeatForever(autoreverses: false), value: spinning)
                        .onAppear { spinning = true }.onDisappear { spinning = false }
                case .monitoring: icon("activity", color: SmthzTheme.agentWorking)
                case .question: icon("circle-help", color: SmthzTheme.agentQuestion)
                case .error: dot(SmthzTheme.destructive, size: 6)
                case .interrupted: dot(SmthzTheme.mutedForeground, size: 6)
                case .branch: icon("git-branch", color: SmthzTheme.mutedForeground)
                case .review: icon("git-merge", color: SmthzTheme.mutedForeground)
                case .live: dot(Color(red: 0.063, green: 0.725, blue: 0.506), size: 8)
                case .idle: dot(Color.gray.opacity(0.4), size: 8)
                }
            }
        }
        .frame(width: 20, height: 20)
        .onHover { hovered = $0 }
        .smthzTooltip(label, edge: .trailing)
        .accessibilityLabel(label)
    }

    private var unreadBell: some View {
        Image(systemName: hovered ? "bell" : "bell.fill")
            .font(.system(size: hovered ? 12 : 13))
            .foregroundStyle(Color(red: 0.98, green: 0.75, blue: 0.14))
    }
    private var label: String {
        if data.isDeleting { return "Deleting…" }
        if let creation = data.creation { return "Creating workspace: \(creation.phase)" }
        if data.creationFailure != nil { return "Workspace creation failed" }
        if data.isUnread { return "Unread activity" }
        if data.isSleeping { return "Sleeping" }
        switch data.status {
        case .idle: return "Inactive"
        case .live: return "Active"
        case .working: return "Working"
        case .monitoring: return "Monitoring"
        case .question: return "Needs attention"
        case .error: return "Failed"
        case .interrupted: return "Interrupted"
        case .branch: return "Branch"
        case .review: return "Pull request review"
        }
    }
    private func icon(_ name: String, color: Color) -> some View {
        SmthzIcon.image(name).frame(width: 12, height: 12).foregroundStyle(color)
    }
    private func dot(_ color: Color, size: CGFloat) -> some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

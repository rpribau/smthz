import SmthzCore
import SwiftUI
import Darwin

/// Resident memory of a process through `proc_pidinfo`; nil when the pid is gone or not ours to read.
enum ProcessMemory {
    static func residentBytes(pid: Int32) -> UInt64? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        return info.pti_resident_size
    }

    static func format(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        return mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }
}

/// Memory shown in the bar: this app + `smthzd` + every live session process.
struct ResourceUsage: Equatable {
    var appBytes: UInt64 = 0
    var hostBytes: UInt64?
    var sessionBytes: [String: UInt64] = [:]

    var total: UInt64 { appBytes + (hostBytes ?? 0) + sessionBytes.values.reduce(0, +) }

    static func sample(hostPID: Int32?, sessions: [SessionInfo]) -> ResourceUsage {
        var usage = ResourceUsage()
        usage.appBytes = ProcessMemory.residentBytes(pid: getpid()) ?? 0
        usage.hostBytes = hostPID.flatMap { ProcessMemory.residentBytes(pid: $0) }
        for session in sessions where session.running {
            if let bytes = ProcessMemory.residentBytes(pid: session.pid) { usage.sessionBytes[session.id] = bytes }
        }
        return usage
    }
}

/// UI-DETAIL §6 "Resource Manager" popover: summary, then the "This computer" PTY list with
/// Go to terminal and End (confirmed), then "Clean up workspaces…" (WP-M4-CLEANUP). CPU, orphan detection, daemon restart and workspace
/// trees need backends smthz does not have; they are not shown.
struct ResourceManagerPopover: View {
    let sessions: [SessionInfo]
    let usage: ResourceUsage
    let hostLabel: String
    var onGoToSession: ((SessionInfo) -> Void)?
    var onEndSession: ((SessionInfo) -> Void)?

    @State private var pendingEnd: SessionInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let session = pendingEnd {
                confirm(session)
            } else {
                header
                Divider().overlay(SmthzTheme.border)
                list
                Divider().overlay(SmthzTheme.border)
                cleanupEntry
            }
        }
        .font(SmthzFont.ui(size: 12))
        .foregroundStyle(SmthzTheme.foreground)
        .frame(width: 360)
        .background(SmthzTheme.popover)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Resource Manager").font(SmthzFont.ui(size: 13, weight: .semibold))
            HStack(spacing: 16) {
                summary("Memory", ProcessMemory.format(usage.total))
                summary("Sessions", String(sessions.filter(\.running).count))
            }
            Text(hostLabel).font(SmthzFont.ui(size: 11)).foregroundStyle(SmthzTheme.mutedForeground)
        }
        .padding(12)
    }

    /// WP-M4-CLEANUP: opens the Clean up workspaces window (`WorkspaceCleanupView`).
    private var cleanupEntry: some View {
        Button { WorkspaceCleanupWindow.show() } label: {
            HStack(spacing: 8) {
                SmthzIcon.view("eraser", size: 12)
                Text("Clean up workspaces…")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Find idle, clean workspaces and delete them")
    }

    private func summary(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(SmthzFont.ui(size: 11)).foregroundStyle(SmthzTheme.mutedForeground)
            Text(value).monospacedDigit()
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("This computer")
                .font(SmthzFont.ui(size: 11, weight: .medium))
                .foregroundStyle(SmthzTheme.mutedForeground)
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
            if sessions.isEmpty {
                Text("Nothing running right now")
                    .foregroundStyle(SmthzTheme.mutedForeground)
                    .padding(.horizontal, 12).padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(sessions, id: \.id) { session in
                            SessionRow(session: session, bytes: usage.sessionBytes[session.id],
                                       onGoTo: onGoToSession.map { go in { go(session) } },
                                       onEnd: { pendingEnd = session })
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
        .padding(.bottom, 4)
    }

    private func confirm(_ session: SessionInfo) -> some View {
        let name = SessionRow.title(session)
        return VStack(alignment: .leading, spacing: 12) {
            Text("End \(name)?").font(SmthzFont.ui(size: 14, weight: .semibold))
            Text("This stops the terminal process (pid \(String(session.pid))) and its child processes.")
                .foregroundStyle(SmthzTheme.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel") { pendingEnd = nil }.buttonStyle(SmthzButtonStyle(.outline, size: .xs))
                Button("End") {
                    pendingEnd = nil
                    onEndSession?(session)
                }
                .buttonStyle(SmthzButtonStyle(.primary, size: .xs))
                .disabled(onEndSession == nil)
            }
        }
        .padding(16)
    }
}

private struct SessionRow: View {
    let session: SessionInfo
    let bytes: UInt64?
    var onGoTo: (() -> Void)?
    let onEnd: () -> Void
    @State private var hovering = false

    static func title(_ session: SessionInfo) -> String {
        let exe = session.executable.map { ($0 as NSString).lastPathComponent } ?? "terminal"
        return exe
    }

    var body: some View {
        HStack(spacing: 8) {
            SmthzIcon.view(.terminal, size: 12)
                .foregroundStyle(session.running ? SmthzTheme.foreground : SmthzTheme.mutedForeground)
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.title(session)).lineLimit(1)
                Text(detail).font(SmthzFont.ui(size: 11)).foregroundStyle(SmthzTheme.mutedForeground)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if let onGoTo {
                Button(action: onGoTo) {
                    SmthzIcon.view(.arrowRight, size: 12).rotationEffect(.degrees(-45))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("Go to terminal")
                .accessibilityLabel("Go to terminal")
            }
            if session.running {
                Button("End", action: onEnd).buttonStyle(SmthzButtonStyle(.outline, size: .xs))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(hovering ? SmthzTheme.accent.opacity(0.7) : .clear)
        .onHover { hovering = $0 }
    }

    private var detail: String {
        var parts = ["pid \(String(session.pid))"]
        if let bytes { parts.append(ProcessMemory.format(bytes)) }
        if let cwd = session.cwd { parts.append((cwd as NSString).abbreviatingWithTildeInPath) }
        if !session.running { parts.append("exited") }
        return parts.joined(separator: " · ")
    }
}

import Combine
import SmthzCore
import SwiftUI

/// UI-SPEC §8 / UI-DETAIL §6 status bar: 24 pt, `px-3`, gap 16, 12 pt. The host segment stays at
/// the left (D-STATUS). Right cluster order: Resource Manager (memory · PTYs, popover), Ports,
/// SSH, floating chip. Ports and SSH are VISUAL-ONLY and off unless enabled in the right-click
/// visibility menu. Segments collapse to icon-only below `collapseWidth`.
struct StatusBarView: View {
    let hostIsRunning: Bool
    let hostLabel: String
    let hostDetail: String
    let sessionCount: Int
    var sessions: [SessionInfo] = []
    var hostPID: Int32?
    var hostSymbol: String?
    var visibility = StatusBarVisibility()
    var onGoToSession: ((SessionInfo) -> Void)?
    var onEndSession: ((SessionInfo) -> Void)?
    var showUpdate = false
    var floatingTerminalActive = false
    var onToggleFloatingTerminal: (() -> Void)?

    static let collapseWidth: CGFloat = 480

    @State private var hoveringHost = false
    @State private var hoveringFloating = false
    @State private var hoveringResources = false
    @State private var showResourcePopover = false
    @State private var usage = ResourceUsage()
    private let sampler = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.width < Self.collapseWidth
            HStack(spacing: 16) {
                hostSegment(compact: compact)
                Spacer(minLength: 0)
                HStack(spacing: 12) {
                    if showUpdate {
                        segment(icon: .circleDashed, text: "Update available", compact: compact)
                    }
                    if visibility.showResourceManager { resourceSegment }
                    if visibility.showPorts {
                        // VISUAL-ONLY: stub data until the ports scanner exists
                        segment(icon: .plug, text: "0 ports", compact: compact)
                    }
                    if visibility.showRemoteHosts {
                        // VISUAL-ONLY: stub data until paired/SSH hosts exist
                        segment(icon: .server, text: "0 hosts", compact: compact)
                    }
                    floatingChip
                }
            }
            .font(SmthzFont.ui(size: 12))
            .foregroundStyle(SmthzTheme.mutedForeground)
            .padding(.horizontal, 12)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(height: SmthzMetrics.statusBarHeight)
        .background(SmthzTheme.card)
        .overlay(alignment: .top) { SmthzTheme.border.frame(height: 1) }
        .contextMenu { StatusBarVisibilityMenu(visibility: visibility) }
        .onReceive(sampler) { _ in if visibility.showResourceManager { resample() } }
        .onAppear { resample() }
    }

    private func resample() {
        usage = ResourceUsage.sample(hostPID: hostPID, sessions: sessions)
    }

    private func hostSegment(compact: Bool) -> some View {
        HStack(spacing: 6) {
            if let hostSymbol {
                Image(systemName: hostSymbol).font(.system(size: 10))
            } else {
                Circle()
                    .fill(hostIsRunning ? SmthzTheme.statusSuccess : SmthzTheme.mutedForeground)
                    .frame(width: 6, height: 6)
            }
            if !compact { Text(hostLabel).lineLimit(1) }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: SmthzMetrics.radiusSM)
                .fill(hoveringHost ? SmthzTheme.accent.opacity(0.7) : .clear))
        .onHover { hoveringHost = $0 }
        .help(hostDetail)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hostLabel)
        .accessibilityValue(hostDetail)
    }

    private var resourceSegment: some View {
        Button {
            resample()
            showResourcePopover.toggle()
        } label: {
            HStack(spacing: 4) {
                if hostIsRunning {
                    SmthzIcon.view(.memoryStick, size: 12)
                    Text(ProcessMemory.format(usage.total)).font(SmthzFont.ui(size: 11)).monospacedDigit()
                    Text("·")
                    SmthzIcon.view(.terminal, size: 12)
                    Text(String(sessionCount)).font(SmthzFont.ui(size: 11)).monospacedDigit()
                } else {
                    SmthzIcon.view(.alertTriangle, size: 12).foregroundStyle(SmthzTheme.statusWarning)
                    Text("Host unreachable").font(SmthzFont.ui(size: 11))
                }
            }
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: SmthzMetrics.radiusSM)
                    .fill(hoveringResources || showResourcePopover ? SmthzTheme.accent.opacity(0.7) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hoveringResources = $0 }
        .help("Resource Manager")
        .popover(isPresented: $showResourcePopover, arrowEdge: .top) {
            ResourceManagerPopover(sessions: sessions, usage: usage, hostLabel: hostDetail,
                                   onGoToSession: onGoToSession.map { go in { s in showResourcePopover = false; go(s) } },
                                   onEndSession: onEndSession.map { end in { s in end(s); resample() } })
        }
        .accessibilityLabel("Resource Manager")
        .accessibilityValue("\(ProcessMemory.format(usage.total)), \(sessionCount) terminals")
    }

    private func segment(icon: SmthzIcon.Name, text: String, compact: Bool) -> some View {
        HStack(spacing: 4) {
            SmthzIcon.view(icon, size: 12)
            if !compact { Text(text).lineLimit(1) }
        }
        .help(text)
        .accessibilityLabel(text)
    }

    private var floatingChip: some View {
        Button { onToggleFloatingTerminal?() } label: {
            SmthzIcon.view(.panelsTopLeft, size: 14)
                .foregroundStyle(floatingTerminalActive ? SmthzTheme.foreground : SmthzTheme.secondaryForeground)
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: SmthzMetrics.radiusSM)
                        .fill(hoveringFloating ? SmthzTheme.accent : SmthzTheme.secondary))
                .overlay(
                    RoundedRectangle(cornerRadius: SmthzMetrics.radiusSM)
                        .strokeBorder(SmthzTheme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(onToggleFloatingTerminal == nil)
        .onHover { hoveringFloating = $0 }
        .help("Toggle floating terminal")
        .accessibilityLabel("Toggle floating terminal")
        .accessibilityAddTraits(floatingTerminalActive ? .isSelected : [])
    }
}

import SwiftUI

// VISUAL-ONLY: stub data until port scanner backend
struct PortsPanel: View {
    enum Group: String, CaseIterable, Identifiable {
        case active = "Active Workspace", other = "Other Workspaces", external = "External"
        var id: String { rawValue }
    }
    struct Port: Identifiable {
        let id: String
        let number: Int
        let process: String
        let address: String
        let group: Group
    }

    var ports: [Port] = []
    var hasWorkspace = false
    var isScanning = false
    var scanError: String?
    var hostName = "Local host"
    var onRefresh: (() -> Void)?
    var onPortAction: ((String, Port) -> Void)?
    @State private var collapsed: Set<Group> = []
    @State private var details: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Ports").font(SmthzFont.ui(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                PanelIconButton(icon: "refresh-cw", label: "Refresh Ports", enabled: onRefresh != nil && !isScanning) { onRefresh?() }
            }.padding(.horizontal, 8).frame(height: 36)
            if let scanError {
                PanelEmptyState(icon: .plug, title: "Port scan unavailable on \(hostName): \(scanError)", detail: nil)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Group.allCases) { group in section(group) }
                    }.padding(.horizontal, 6)
                }
                if !isScanning && ports.isEmpty {
                    Text("No local ports detected").font(SmthzFont.ui(size: 11))
                        .foregroundStyle(SmthzTheme.mutedForeground).padding(12)
                }
            }
        }
        .foregroundStyle(SmthzTheme.foreground).background(SmthzTheme.sidebar)
    }

    private func section(_ group: Group) -> some View {
        let rows = ports.filter { $0.group == group }
        return VStack(spacing: 0) {
            Button {
                if !collapsed.insert(group).inserted { collapsed.remove(group) }
            } label: {
                HStack(spacing: 4) {
                    SmthzIcon.view(.chevronRight, size: 12).rotationEffect(.degrees(collapsed.contains(group) ? 0 : 90))
                    Text(group.rawValue).font(SmthzFont.ui(size: 11, weight: .semibold))
                    if !rows.isEmpty {
                        Text("\(rows.count)").font(SmthzFont.ui(size: 11)).foregroundStyle(SmthzTheme.mutedForeground)
                    }
                    Spacer(minLength: 0)
                }.padding(.horizontal, 4).frame(height: 28).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityValue(collapsed.contains(group) ? "Collapsed" : "Expanded")
            if !collapsed.contains(group) {
                if isScanning {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Scanning...")
                    }.font(SmthzFont.ui(size: 12)).foregroundStyle(SmthzTheme.mutedForeground)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                } else if rows.isEmpty {
                    Text(group == .active && !hasWorkspace ? "No workspace selected" : "No ports detected")
                        .font(SmthzFont.ui(size: 12)).foregroundStyle(SmthzTheme.mutedForeground)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 20).padding(.vertical, 12)
                } else {
                    ForEach(rows) { port in portRow(port) }
                }
            }
        }
    }

    private func portRow(_ port: Port) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                SmthzIcon.view(.plug, size: 12).foregroundStyle(SmthzTheme.mutedForeground)
                Text(String(port.number)).font(SmthzFont.mono(size: 12))
                Text(port.process).font(SmthzFont.ui(size: 12)).foregroundStyle(SmthzTheme.mutedForeground).lineLimit(1)
                Spacer(minLength: 0)
                Button { onPortAction?("Open in Browser", port) } label: {
                    Image(systemName: "arrow.up.right.square").font(.system(size: 12))
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(onPortAction == nil)
                    .help("Open in Browser").accessibilityLabel("Open in Browser")
                Menu {
                    Button("Copy \(port.address)") { onPortAction?("Copy Address", port) }.disabled(onPortAction == nil)
                    Button("Copy Address") { onPortAction?("Copy Address", port) }.disabled(onPortAction == nil)
                    Button("Copy Details") { onPortAction?("Copy Details", port) }.disabled(onPortAction == nil)
                    Button(details.contains(port.id) ? "Hide Details" : "Show Details") {
                        if !details.insert(port.id).inserted { details.remove(port.id) }
                    }
                    Divider()
                    Button("Stop Process", role: .destructive) { onPortAction?("Stop Process", port) }.disabled(onPortAction == nil)
                } label: { SmthzIcon.view(.ellipsis, size: 14).frame(width: 24, height: 24) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help("Port \(port.number) menu").accessibilityLabel("Port \(port.number) menu")
            }
            if details.contains(port.id) {
                Text(port.address).font(SmthzFont.mono(size: 11)).foregroundStyle(SmthzTheme.mutedForeground)
                    .textSelection(.enabled)
            }
        }.padding(.horizontal, 8).padding(.vertical, 4)
    }
}

#if DEBUG
#Preview("Ports · Empty") { PortsPanel(hasWorkspace: true).frame(width: 320, height: 560) }
#Preview("Ports · No workspace") { PortsPanel().frame(width: 320, height: 560) }
#Preview("Ports · Scanning") { PortsPanel(hasWorkspace: true, isScanning: true).frame(width: 320, height: 560) }
#Preview("Ports · Rows") {
    PortsPanel(ports: [
        .init(id: "preview-1", number: 3000, process: "node", address: "http://localhost:3000", group: .active),
        .init(id: "preview-2", number: 8080, process: "python", address: "http://localhost:8080", group: .other),
        .init(id: "preview-3", number: 5432, process: "postgres", address: "localhost:5432", group: .external)
    ], hasWorkspace: true).frame(width: 320, height: 560)
}
#endif

import SwiftUI

// VISUAL-ONLY: stub data until the automations scheduler and run history backend.
struct SmthzAutomationsPage: View {
    var onClose: () -> Void = {}
    var onRefresh: (() -> Void)?
    var onNewAutomation: (() -> Void)?
    @State private var showingRuns = false
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button("Automations") { showingRuns = false }
                    .buttonStyle(.plain).font(SmthzFont.ui(size: 16, weight: .semibold))
                    .foregroundStyle(showingRuns ? SmthzTheme.mutedForeground : SmthzTheme.foreground)
                if showingRuns {
                    SmthzIcon.view(.chevronRight, size: 12).foregroundStyle(SmthzTheme.mutedForeground)
                    Text("Runs").font(SmthzFont.ui(size: 16, weight: .semibold))
                }
                Spacer()
                SmthzDestinationCloseButton(label: "Close automations", onClose: onClose)
            }.padding(.horizontal, 20).padding(.bottom, 12).padding(.top, 12)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { searchField; refreshButton; Spacer(minLength: 8); actions }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) { searchField; refreshButton }
                    actions
                }
            }.padding(.horizontal, 20).padding(.bottom, 16)
            GeometryReader { geometry in
                ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    HStack(spacing: 16) {
                        ForEach(showingRuns ? ["Automation", "Status", "Started", "Duration", "Host"]
                                : ["Name", "Schedule", "Project", "Host", "Next run", "Last run", "Status", "Agent"], id: \.self) { column in
                            Text(column).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .font(SmthzFont.ui(size: 12, weight: .medium)).foregroundStyle(SmthzTheme.mutedForeground)
                    .padding(.horizontal, 16).frame(height: 36).background(SmthzTheme.muted.opacity(0.4))
                    Rectangle().fill(SmthzTheme.border).frame(height: 1)
                    VStack(spacing: 6) {
                        Text(showingRuns ? "No runs yet" : "No automations yet")
                            .font(SmthzFont.ui(size: 14))
                        Text(showingRuns ? "Automation runs will appear here."
                             : "Create an automation to start scheduling agent work.")
                            .font(SmthzFont.ui(size: 12)).foregroundStyle(SmthzTheme.mutedForeground)
                        Text("Automations are not available yet.")
                            .font(SmthzFont.ui(size: 12)).foregroundStyle(SmthzTheme.mutedForeground).padding(.top, 6)
                    }.multilineTextAlignment(.center).padding(.horizontal, 24).padding(.vertical, 40)
                        .frame(maxWidth: .infinity)
                }.frame(width: max(740, geometry.size.width))
                }
            }
            .frame(height: 186)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SmthzTheme.border))
            .padding(.horizontal, 20)
            Spacer(minLength: 16)
        }
        .foregroundStyle(SmthzTheme.foreground).background(SmthzTheme.background)
        .onExitCommand(perform: onClose)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            SmthzIcon.view(.search, size: 14).foregroundStyle(SmthzTheme.mutedForeground)
            TextField(showingRuns ? "Search runs..." : "Search automations...", text: $query)
                .textFieldStyle(.plain).font(SmthzFont.ui(size: 12)).disabled(true)
        }.padding(.horizontal, 10).frame(maxWidth: 320).frame(height: 32)
            .background(SmthzTheme.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SmthzTheme.input))
            .help("Not available yet")
    }

    private var refreshButton: some View {
        Button { onRefresh?() } label: { SmthzIcon.view("refresh-cw", size: 16) }
            .buttonStyle(SmthzButtonStyle(.outline, size: .iconSmall)).disabled(onRefresh == nil)
            .help("Refresh automations").accessibilityLabel("Refresh automations")
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button { showingRuns = true } label: {
                HStack(spacing: 8) { SmthzIcon.view(.history, size: 16); Text("Runs") }
            }.buttonStyle(SmthzButtonStyle(.outline, size: .small))
            Button { onNewAutomation?() } label: {
                HStack(spacing: 8) { SmthzIcon.view(.plus, size: 16); Text("New Automation") }
            }.buttonStyle(SmthzButtonStyle(.primary, size: .small))
                .disabled(onNewAutomation == nil).help("Not available yet")
        }
    }
}

#if DEBUG
#Preview("Automations · Light") { SmthzAutomationsPage().frame(width: 1000, height: 580).preferredColorScheme(.light) }
#Preview("Automations · Dark") { SmthzAutomationsPage().frame(width: 1000, height: 580).preferredColorScheme(.dark) }
#endif

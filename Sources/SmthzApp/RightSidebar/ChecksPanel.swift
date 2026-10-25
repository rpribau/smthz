import SwiftUI

// VISUAL-ONLY: stub data until PR provider backend
struct ChecksPanel: View {
    enum State { case noWorkspace, unavailable, loading, review }
    enum Verdict {
        case passing, failing, pending
        var icon: SmthzIcon.Name {
            switch self { case .passing: .circleCheck; case .failing: "circle-x"; case .pending: .circleDashed }
        }
        var color: Color {
            switch self { case .passing: SmthzTheme.statusSuccess; case .failing: SmthzTheme.destructive; case .pending: SmthzTheme.statusWarning }
        }
        var label: String {
            switch self { case .passing: "Passing"; case .failing: "Failing"; case .pending: "Pending" }
        }
    }
    struct Check: Identifiable {
        let id: String
        let title: String
        let detail: String
        let verdict: Verdict
    }

    var state: State = .noWorkspace
    var reviewTitle = ""
    var checks: [Check] = []
    var onRefresh: (() -> Void)?
    var onAction: ((String) -> Void)?
    @State private var selectedCheck: String?
    @State private var commentMode = "Grouped"

    var body: some View {
        VStack(spacing: 0) {
            switch state {
            case .noWorkspace:
                PanelEmptyState(icon: .listChecks, title: "No workspace selected", detail: "Select a workspace to view checks")
            case .unavailable:
                PanelEmptyState(icon: .listChecks, title: "Checks unavailable", detail: "Checks require a Git branch and hosted review context")
            case .loading:
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading checks…").font(SmthzFont.ui(size: 12))
                }.foregroundStyle(SmthzTheme.mutedForeground).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .review:
                reviewBody
            }
        }
        .foregroundStyle(SmthzTheme.foreground).background(SmthzTheme.sidebar)
    }

    private var reviewBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                SmthzIcon.view(.gitMerge, size: 14)
                Text(reviewTitle).font(SmthzFont.ui(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
                Button { onAction?("Link another PR") } label: {
                    Image(systemName: "link").font(.system(size: 12)).frame(width: 24, height: 24)
                }.buttonStyle(.plain).disabled(onAction == nil)
                    .help("Link another PR").accessibilityLabel("Link another PR")
                PanelIconButton(icon: "refresh-cw", label: "Refresh", enabled: onRefresh != nil) { onRefresh?() }
                Menu {
                    Button("Open on GitHub") { onAction?("Open on GitHub") }
                } label: { SmthzIcon.view(.ellipsis, size: 14).frame(width: 24, height: 24) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .disabled(onAction == nil).help("More PR actions").accessibilityLabel("More PR actions")
            }.padding(8)
            if checks.contains(where: { $0.verdict == .failing }) {
                HStack(alignment: .top, spacing: 6) {
                    SmthzIcon.view("octagon-x", size: 14).foregroundStyle(SmthzTheme.destructive)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("failing check").font(SmthzFont.ui(size: 12, weight: .medium))
                        Text("Inspect details or start an AI fix pass.").font(SmthzFont.ui(size: 11)).foregroundStyle(SmthzTheme.mutedForeground)
                    }
                    Spacer(minLength: 0)
                    Button("Fix") { onAction?("Fix") }.buttonStyle(.plain).disabled(onAction == nil)
                }.padding(8).background(SmthzTheme.destructive.opacity(0.08))
            } else if checks.contains(where: { $0.verdict == .pending }) {
                Text("pending").font(SmthzFont.ui(size: 12)).foregroundStyle(SmthzTheme.statusWarning)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Checks").font(SmthzFont.ui(size: 12, weight: .semibold)).padding(8)
                    if checks.isEmpty {
                        Text("No checks configured").font(SmthzFont.ui(size: 12))
                            .foregroundStyle(SmthzTheme.mutedForeground).padding(8)
                    }
                    ForEach(checks) { check in checkRow(check) }
                    Divider().overlay(SmthzTheme.border).padding(.vertical, 8)
                    HStack {
                        Text("Comments").font(SmthzFont.ui(size: 12, weight: .semibold))
                        Spacer(minLength: 0)
                        Picker("Comments view", selection: $commentMode) {
                            Text("Grouped").tag("Grouped"); Text("Timeline").tag("Timeline")
                        }.labelsHidden().fixedSize().controlSize(.small)
                    }.padding(.horizontal, 8)
                    Button("Add comment") { onAction?("Add comment") }
                        .buttonStyle(.plain).disabled(onAction == nil).padding(8)
                }
            }
        }
    }

    private func checkRow(_ check: Check) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { selectedCheck = selectedCheck == check.id ? nil : check.id } label: {
                HStack(spacing: 6) {
                    SmthzIcon.view(check.verdict.icon, size: 14).foregroundStyle(check.verdict.color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(check.title).font(SmthzFont.ui(size: 12)).lineLimit(1)
                        Text(check.detail).font(SmthzFont.ui(size: 11)).foregroundStyle(SmthzTheme.mutedForeground)
                    }
                    Spacer(minLength: 0)
                    SmthzIcon.view(.chevronRight, size: 12).rotationEffect(.degrees(selectedCheck == check.id ? 90 : 0))
                }.padding(8).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("\(check.title), \(check.verdict.label)")
            if selectedCheck == check.id {
                HStack {
                    Text("Jobs"); Text("Annotations")
                    Spacer(minLength: 0)
                    Button("Retry") { onAction?("Retry \(check.id)") }.disabled(onAction == nil)
                }.font(SmthzFont.ui(size: 11)).padding(8).background(SmthzTheme.muted)
            }
        }
    }
}

#if DEBUG
#Preview("Checks · No workspace") { ChecksPanel().frame(width: 320, height: 560) }
#Preview("Checks · Unavailable") { ChecksPanel(state: .unavailable).frame(width: 320, height: 560) }
#Preview("Checks · Loading") { ChecksPanel(state: .loading).frame(width: 320, height: 560) }
#Preview("Checks · Review") {
    ChecksPanel(state: .review, reviewTitle: "Improve terminal layout #42", checks: [
        .init(id: "build", title: "Build", detail: "Completed in 32s", verdict: .passing),
        .init(id: "tests", title: "Tests", detail: "1 failing test", verdict: .failing),
        .init(id: "lint", title: "Lint", detail: "Queued", verdict: .pending)
    ]).frame(width: 320, height: 560)
}
#endif

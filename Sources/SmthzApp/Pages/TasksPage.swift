import SwiftUI

// VISUAL-ONLY: stub data until M4 projects and task provider backends.
/// UI-29 supplies page routing; selecting a provider only changes this local shell.
struct SmthzTasksPage: View {
    var onClose: () -> Void = {}
    @State private var provider: Provider = .github

    enum Provider: String, CaseIterable, Identifiable {
        case github = "GitHub", gitlab = "GitLab", linear = "Linear", jira = "Jira"
        var id: Self { self }
        var icon: String { rawValue.lowercased() }
        var title: String {
            switch self {
            case .github, .gitlab: "No project sources selected"
            case .linear: "Connect your Linear account"
            case .jira: "Connect your Jira site"
            }
        }
        var detail: String {
            switch self {
            case .github, .gitlab:
                "Select at least one project source so smthz knows which host/account to fetch tasks from."
            case .linear: "Browse and start work on your assigned Linear issues directly from here."
            case .jira: "Browse, edit, create, and start work from Jira issues directly from here."
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                SmthzDestinationCloseButton(label: "Close tasks", onClose: onClose)
                Rectangle().fill(SmthzTheme.border.opacity(0.5)).frame(width: 1, height: 20).padding(.horizontal, 4)
                ForEach(Provider.allCases) { source in
                    Button { provider = source } label: {
                        SmthzIcon.image(source.icon).scaledToFit().frame(width: 14, height: 14)
                            .frame(width: 32, height: 32)
                            .background(provider == source ? SmthzTheme.muted.opacity(0.7) : .clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(provider == source ? SmthzTheme.foreground.opacity(0.4) : SmthzTheme.border.opacity(0.4)))
                    }
                    .buttonStyle(.plain).help(source.rawValue).accessibilityLabel(source.rawValue)
                    .accessibilityAddTraits(provider == source ? .isSelected : [])
                }
                Text("Tasks").font(SmthzFont.ui(size: 12)).foregroundStyle(SmthzTheme.mutedForeground)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(SmthzTheme.muted.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                Spacer(minLength: 0)
            }.padding(16)
            ScrollView {
                VStack(spacing: 0) {
                    SmthzIcon.image(provider.icon).scaledToFit().frame(width: 32, height: 32)
                        .foregroundStyle(SmthzTheme.mutedForeground.opacity(0.6)).padding(.bottom, 16)
                    Text(provider.title).font(SmthzFont.ui(size: 16, weight: .medium))
                    Text(provider.detail).font(SmthzFont.ui(size: 14))
                        .foregroundStyle(SmthzTheme.mutedForeground).frame(maxWidth: 384).padding(.top, 8)
                    if provider == .linear || provider == .jira {
                        Button(provider == .linear ? "Add Linear access" : "Connect Jira") {}
                            .buttonStyle(SmthzButtonStyle()).disabled(true).help("Not available yet").padding(.top, 20)
                    }
                    Text("Task integrations are not available yet.").font(SmthzFont.ui(size: 12))
                        .foregroundStyle(SmthzTheme.mutedForeground).padding(.top, 16)
                }
                .multilineTextAlignment(.center).padding(.horizontal, 24).padding(.vertical, 56)
                .frame(maxWidth: .infinity)
                .background(SmthzTheme.muted.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SmthzTheme.border.opacity(0.5)))
                .padding(.horizontal, 16)
            }
        }
        .foregroundStyle(SmthzTheme.foreground).background(SmthzTheme.background)
        .onExitCommand(perform: onClose)
    }
}

/// Shared by the three UI-28 destination shells. Escape remains available while a field has focus.
struct SmthzDestinationCloseButton: View {
    let label: String
    var onClose: () -> Void
    var body: some View {
        Button(action: onClose) {
            SmthzIcon.view(.x, size: 16).frame(width: 28, height: 28)
        }
        .buttonStyle(SmthzButtonStyle(.ghost, size: .iconSmall))
        .keyboardShortcut(.cancelAction)
        .help("Close · Esc").accessibilityLabel(label)
    }
}

#if DEBUG
#Preview("Tasks · Light") { SmthzTasksPage().frame(width: 900, height: 580).preferredColorScheme(.light) }
#Preview("Tasks · Dark") { SmthzTasksPage().frame(width: 900, height: 580).preferredColorScheme(.dark) }
#endif

import SwiftUI

/// UI-29 wraps the full shell in this gate. Fresh defaults show setup; completion
/// is persisted only on Finish, never when navigating between steps.
struct SmthzOnboardingGate<Content: View>: View {
    @AppStorage(SmthzOnboardingView.completionKey) private var completed = false
    var onAddProject: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        if completed {
            content()
        } else {
            SmthzOnboardingView(onFinish: { completed = true }, onAddProject: onAddProject)
        }
    }
}

struct SmthzOnboardingView: View {
    static let completionKey = "onboarding.completed"
    enum Step: Int, CaseIterable, Identifiable {
        case language, agent, appearance, notifications, integrations, project
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .language: "Language"
            case .agent: "Default Agent"
            case .appearance: "Appearance"
            case .notifications: "Notifications"
            case .integrations: "Integrations"
            case .project: "Add your first project"
            }
        }
    }

    var onFinish: () -> Void
    var onAddProject: (() -> Void)? = nil
    @State private var step = Step.language
    @State private var confirmingSkip = false
    @State private var addingProject = false
    @AppStorage(TerminalSettingsModel.Key.appTheme) private var theme = "system"

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 28) {
                    Text("Welcome to smthz")
                        .font(SmthzFont.ui(size: 24, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    rail
                    VStack(alignment: .leading, spacing: 24) {
                        Text(step.title).font(SmthzFont.ui(size: 18, weight: .semibold))
                            .accessibilityAddTraits(.isHeader)
                        stepContent
                    }
                    .frame(maxWidth: 560, minHeight: 260, alignment: .topLeading)
                    footer.frame(maxWidth: 560)
                }
                .padding(32).frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height)
            }
        }
        .font(SmthzFont.ui(size: 14))
        .foregroundStyle(SmthzTheme.foreground)
        .background(SmthzTheme.background)
        .preferredColorScheme(theme == "dark" ? .dark : theme == "light" ? .light : nil)
        .disabled(addingProject)
        .accessibilityHidden(addingProject)
        .onExitCommand { confirmingSkip = true }
        .smthzDialog(isPresented: $confirmingSkip, title: "Skip onboarding?",
                     description: "It won't take long!", compact: true) {
            EmptyView()
        } footer: {
            Button("No, keep going") { confirmingSkip = false }
                .buttonStyle(SmthzButtonStyle())
            Button("Skip") { confirmingSkip = false; step = .project }
                .buttonStyle(SmthzButtonStyle(.outline))
        }
        .overlay {
            if addingProject {
                Color.black.opacity(0.55).ignoresSafeArea()
                SmthzAddProjectDialog(onDismiss: { addingProject = false }).padding(24)
            }
        }
    }

    private var rail: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                ForEach(Step.allCases) { item in
                    Button { step = item } label: {
                        VStack(spacing: 6) {
                            Text("\(item.rawValue + 1)")
                                .font(SmthzFont.ui(size: 12, weight: .medium))
                                .frame(width: 28, height: 28)
                                .background(item == step ? SmthzTheme.primary : SmthzTheme.secondary,
                                            in: Circle())
                                .foregroundStyle(item == step ? SmthzTheme.primaryForeground : SmthzTheme.mutedForeground)
                            Text(item.title).font(SmthzFont.ui(size: 11))
                        }
                        .frame(minWidth: 66)
                        .padding(4).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Go to onboarding step \(item.rawValue + 1): \(item.title)")
                    .accessibilityAddTraits(item == step ? .isSelected : [])
                }
            }
            HStack {
                Text("\(step.rawValue + 1) of \(Step.allCases.count)")
                Text(step.title).foregroundStyle(SmthzTheme.mutedForeground)
            }
        }
        .accessibilityValue("\(step.rawValue + 1) of \(Step.allCases.count)")
    }

    @ViewBuilder private var stepContent: some View {
        switch step {
        case .language: SmthzOnboardingLanguageStep()
        case .agent: SmthzOnboardingAgentStep()
        case .appearance: SmthzOnboardingAppearanceStep(theme: $theme)
        case .notifications: SmthzOnboardingNotificationsStep()
        case .integrations: SmthzOnboardingIntegrationsStep()
        case .project:
            VStack(alignment: .leading, spacing: 16) {
                Text("Add a project to get started.").foregroundStyle(SmthzTheme.mutedForeground)
                Button {
                    if let onAddProject { onAddProject() } else { addingProject = true }
                } label: {
                    Label {
                        Text("Add project")
                    } icon: {
                        SmthzIcon.image("folder-plus").resizable().scaledToFit().frame(width: 14, height: 14)
                    }
                }
                .buttonStyle(SmthzButtonStyle(.outline))
            }
        }
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { navigationButtons }
            VStack(spacing: 12) { navigationButtons }
        }
        .padding(.top, 20)
        .overlay(alignment: .top) { Rectangle().fill(SmthzTheme.border).frame(height: 1) }
    }

    @ViewBuilder private var navigationButtons: some View {
        Button {
            if let previous = Step(rawValue: step.rawValue - 1) { step = previous }
        } label: {
            HStack(spacing: 6) {
                SmthzIcon.image("chevron-left").resizable().scaledToFit().frame(width: 14, height: 14)
                Text("Back")
            }
        }
        .buttonStyle(SmthzButtonStyle(.ghost)).disabled(step == .language)
        Spacer(minLength: 8)
        Button("Skip to project setup") { confirmingSkip = true }
            .buttonStyle(SmthzButtonStyle(.ghost))
            .disabled(step == .project)
        Button(step == .project ? "Finish" : "Continue") {
            if let next = Step(rawValue: step.rawValue + 1) { step = next }
            else { onFinish() }
        }
        .buttonStyle(SmthzButtonStyle()).keyboardShortcut(.return, modifiers: [])
    }
}

#if DEBUG
#Preview("Onboarding · light") {
    SmthzOnboardingView(onFinish: {}).frame(width: 900, height: 650).preferredColorScheme(.light)
}
#Preview("Onboarding · dark") {
    SmthzOnboardingView(onFinish: {}).frame(width: 900, height: 650).preferredColorScheme(.dark)
}
#endif

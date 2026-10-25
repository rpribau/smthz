import SwiftUI

/// Apply with `.buttonStyle(SmthzButtonStyle(.secondary))`; use `.landing` for §9 actions.
/// All variants use neutral theme colours and a grey keyboard-focus ring.
struct SmthzButtonStyle: ButtonStyle {
    enum Variant { case primary, secondary, outline, ghost, landing }
    enum Size {
        case regular, xs, small, large, icon, iconSmall, iconXS, chip
        var height: CGFloat {
            switch self {
            case .regular, .icon: 36
            case .xs, .iconXS: 24
            case .small, .iconSmall: 32
            case .large: 40
            case .chip: 16
            }
        }
        var isIcon: Bool { self == .icon || self == .iconSmall || self == .iconXS }
        var fontSize: CGFloat { self == .chip ? 10 : (self == .xs || self == .iconXS ? 12 : 14) }
        var horizontalPadding: CGFloat { self == .xs ? 8 : (self == .chip ? 6 : 16) }
    }

    var variant: Variant
    var size: Size

    init(_ variant: Variant = .primary, size: Size = .regular) {
        self.variant = variant
        self.size = size
    }

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, variant: variant, size: size)
    }

    private struct StyledButton: View {
        let configuration: Configuration
        let variant: Variant
        let size: Size
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        @Environment(\.colorScheme) private var colorScheme
        @State private var hovered = false

        private var active: Bool { hovered || configuration.isPressed }
        private var fill: Color {
            switch variant {
            case .primary: SmthzTheme.primary.opacity(active ? 0.9 : 1)
            case .secondary: SmthzTheme.secondary.opacity(active ? 0.8 : 1)
            case .outline: active ? SmthzTheme.accent : SmthzTheme.background
            case .ghost: active ? SmthzTheme.accent.opacity(colorScheme == .dark ? 0.5 : 1) : .clear
            case .landing: active ? SmthzTheme.accent : SmthzTheme.secondary.opacity(0.7)
            }
        }

        var body: some View {
            configuration.label
                .font(SmthzFont.ui(size: size.fontSize, weight: .medium))
                .foregroundStyle(variant == .primary ? SmthzTheme.primaryForeground : SmthzTheme.foreground)
                .padding(.horizontal, size.isIcon ? 0 : size.horizontalPadding)
                .frame(width: size.isIcon ? size.height : nil, height: size.height)
                .background(fill, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(SmthzTheme.border.opacity(variant == .landing ? 0.8 : 1), lineWidth: 1)
                        .opacity(variant == .outline || variant == .landing ? 1 : 0)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 9.5)
                        .stroke(SmthzTheme.ring.opacity(0.5), lineWidth: 3)
                        .padding(-1.5)
                        .opacity(isFocused ? 1 : 0)
                }
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .opacity(isEnabled ? 1 : 0.5)
                .onHover { hovered = $0 }
        }
    }
}

/// Apply to a Toggle with `.toggleStyle(SmthzSwitchStyle())` for the 36×20 neutral switch.
struct SmthzSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.label
            Spacer(minLength: 8)
            Button { configuration.isOn.toggle() } label: {
                Capsule()
                    .fill(configuration.isOn ? SmthzTheme.foreground : SmthzTheme.mutedForeground.opacity(0.3))
                    .frame(width: 36, height: 20)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(SmthzTheme.background).frame(width: 14, height: 14).padding(3)
                    }
            }
            .buttonStyle(SmthzToggleButtonStyle())
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }
            }
        }
        .font(SmthzFont.ui(size: 14))
        .foregroundStyle(SmthzTheme.foreground)
    }
}

/// Apply to a Toggle with `.toggleStyle(SmthzCheckboxStyle())` for the 16 pt checkbox.
struct SmthzCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(configuration.isOn ? SmthzTheme.primary : SmthzTheme.background)
                    .frame(width: 16, height: 16)
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(configuration.isOn ? SmthzTheme.primary : SmthzTheme.input, lineWidth: 1)
                    }
                    .overlay {
                        if configuration.isOn {
                            SmthzIcon.image(.check).resizable().scaledToFit()
                                .frame(width: 10, height: 10)
                                .foregroundStyle(SmthzTheme.primaryForeground)
                        }
                    }
                configuration.label
                    .font(SmthzFont.ui(size: 14))
                    .foregroundStyle(SmthzTheme.foreground)
            }
            .frame(minHeight: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(SmthzToggleButtonStyle())
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

private struct SmthzToggleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ToggleBody(configuration: configuration)
    }

    private struct ToggleBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        var body: some View {
            configuration.label
                .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.5)
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(SmthzTheme.ring.opacity(0.5), lineWidth: 3)
                        .padding(-3)
                        .opacity(isFocused ? 1 : 0)
                }
        }
    }
}

#Preview("Neutral controls") {
    @Previewable @State var enabled = true
    VStack(alignment: .leading, spacing: 16) {
        HStack {
            Button("Primary") {}.buttonStyle(SmthzButtonStyle())
            Button("Secondary") {}.buttonStyle(SmthzButtonStyle(.secondary))
            Button("Outline") {}.buttonStyle(SmthzButtonStyle(.outline))
            Button("Ghost") {}.buttonStyle(SmthzButtonStyle(.ghost))
        }
        Toggle("Switch", isOn: $enabled).toggleStyle(SmthzSwitchStyle())
        Toggle("Checkbox", isOn: $enabled).toggleStyle(SmthzCheckboxStyle())
        Button("Disabled") {}.buttonStyle(SmthzButtonStyle()).disabled(true)
    }
    .padding(24).frame(width: 480).background(SmthzTheme.background)
}

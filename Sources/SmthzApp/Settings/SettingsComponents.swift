import SwiftUI

/// Shared building blocks for settings pages (UI-SPEC §11, UI-DETAIL §11).

/// Optional/Beta/Dev badge shown next to a page title.
enum SettingsBadge: String, Sendable {
    case optional = "Optional"
    case beta = "Beta"
    case dev = "Dev"
}

/// Page title (24/600) + optional badge (10 pt uppercase) + description.
struct SettingsSectionHeader: View {
    let title: String
    var badge: SettingsBadge?
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title)
                    .font(SmthzFont.ui(size: 24, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                if let badge {
                    Text(badge.rawValue.uppercased())
                        .font(SmthzFont.ui(size: 10, weight: .medium))
                        .tracking(10 * 0.05)
                        .foregroundStyle(SmthzTheme.mutedForeground)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay { Capsule().strokeBorder(SmthzTheme.border, lineWidth: 1) }
                        .accessibilityLabel("\(badge.rawValue) feature")
                }
            }
            Text(description)
                .font(SmthzFont.ui(size: 14))
                .lineSpacing(4)
                .foregroundStyle(SmthzTheme.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 20)
        .overlay(alignment: .bottom) { SmthzTheme.border.opacity(0.6).frame(height: 1) }
    }
}

/// Small uppercase-free sub-section title inside a page ("Typography", "Cursor"…).
struct SettingsGroupTitle: View {
    let title: String
    var body: some View {
        Text(title)
            .font(SmthzFont.ui(size: 16, weight: .semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Label + description on the leading side, control on the trailing side; stacks when narrow.
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let control: () -> Control

    init(_ title: String, detail: String? = nil, @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 24) {
                label
                Spacer(minLength: 16)
                control().fixedSize()
            }
            VStack(alignment: .leading, spacing: 12) {
                label
                control()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(SmthzFont.ui(size: 14, weight: .medium))
            if let detail {
                Text(detail).font(SmthzFont.ui(size: 13)).foregroundStyle(SmthzTheme.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Read-only value text for rows whose setting cannot be changed yet.
struct SettingsValueText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(SmthzFont.ui(size: 13)).foregroundStyle(SmthzTheme.mutedForeground)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Segmented control (System / Dark / Light, Bar / Block / Underline…).
struct SettingsSegmented<Value: Hashable>: View {
    let options: [(label: String, value: Value)]
    @Binding var selection: Value
    var accessibilityLabel: String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let selected = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.label)
                        .font(SmthzFont.ui(size: 13, weight: selected ? .medium : .regular))
                        .foregroundStyle(selected ? SmthzTheme.foreground : SmthzTheme.mutedForeground)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(selected ? SmthzTheme.background : .clear,
                                    in: RoundedRectangle(cornerRadius: SmthzMetrics.radiusMD))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(SmthzTheme.muted, in: RoundedRectangle(cornerRadius: SmthzMetrics.radiusLG))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// `Minus` / value / `Plus` stepper.
struct SettingsStepper: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 1
    var unit: String = ""
    var accessibilityLabel: String

    var body: some View {
        HStack(spacing: 8) {
            Button { value = max(range.lowerBound, value - step) } label: {
                Text("−").font(SmthzFont.ui(size: 14)).frame(width: 24, height: 24)
            }
            .buttonStyle(SmthzButtonStyle(.outline, size: .iconXS))
            .disabled(value <= range.lowerBound)
            .accessibilityLabel("Decrease \(accessibilityLabel)")
            Text(unit.isEmpty ? "\(Int(value))" : "\(Int(value)) \(unit)")
                .font(SmthzFont.mono(size: 13)).monospacedDigit().frame(minWidth: 42)
                .accessibilityLabel("\(accessibilityLabel), \(Int(value)) \(unit)")
            Button { value = min(range.upperBound, value + step) } label: {
                SmthzIcon.view(.plus, size: 12).frame(width: 24, height: 24)
            }
            .buttonStyle(SmthzButtonStyle(.outline, size: .iconXS))
            .disabled(value >= range.upperBound)
            .accessibilityLabel("Increase \(accessibilityLabel)")
        }
    }
}

/// Switch styled like the rest of the settings controls.
struct SettingsToggle: View {
    let title: String
    @Binding var isOn: Bool
    var body: some View {
        Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).tint(SmthzTheme.foreground)
            .accessibilityLabel(title)
    }
}

/// Placeholder body for pages whose controls are not built yet.
struct SettingsUnavailableBody: View {
    var body: some View {
        Text("Settings for this section are not available yet.")
            .font(SmthzFont.ui(size: 14))
            .foregroundStyle(SmthzTheme.mutedForeground)
            .fixedSize(horizontal: false, vertical: true)
    }
}

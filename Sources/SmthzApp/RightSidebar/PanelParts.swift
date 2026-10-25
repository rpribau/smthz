import SwiftUI

/// Shared bits of the right-sidebar panel bodies.
struct PanelEmptyState: View {
    let icon: SmthzIcon.Name
    let title: String
    let detail: String?

    var body: some View {
        VStack(spacing: 6) {
            SmthzIcon.view(icon, size: 24)
                .foregroundStyle(SmthzTheme.mutedForeground.opacity(0.6)).padding(.bottom, 4)
            Text(title).font(SmthzFont.ui(size: 12, weight: .medium)).foregroundStyle(SmthzTheme.foreground)
            if let detail {
                Text(detail).font(SmthzFont.ui(size: 12)).foregroundStyle(SmthzTheme.mutedForeground)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct PanelIconButton: View {
    let icon: SmthzIcon.Name
    let label: String
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            SmthzIcon.view(icon, size: 14)
                .foregroundStyle(hovering && enabled ? SmthzTheme.foreground : SmthzTheme.mutedForeground)
                .frame(width: 24, height: 24)
                .background(hovering && enabled ? SmthzTheme.accent : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.5)
        .onHover { hovering = $0 }
        .help(label).accessibilityLabel(label)
    }
}

struct PanelSearchField: View {
    let icon: SmthzIcon.Name
    let prompt: String
    @Binding var text: String
    let clearLabel: String

    var body: some View {
        HStack(spacing: 6) {
            SmthzIcon.view(icon, size: 12).foregroundStyle(SmthzTheme.mutedForeground)
            TextField(prompt, text: $text).textFieldStyle(.plain).font(SmthzFont.ui(size: 12))
            if !text.isEmpty {
                Button { text = "" } label: { SmthzIcon.view(.x, size: 12) }
                    .buttonStyle(.plain).foregroundStyle(SmthzTheme.mutedForeground)
                    .help(clearLabel).accessibilityLabel(clearLabel)
            }
        }
        .padding(.horizontal, 8).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(SmthzTheme.input))
    }
}

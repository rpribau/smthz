import SwiftUI

/// Floating terminal search; all matching and selection is performed by SwiftTerm.
struct SmthzTerminalFindBar: View {
    @Binding var query: String
    @Binding var caseSensitive: Bool
    @Binding var regex: Bool
    let result: String
    let previous: () -> Void
    let next: () -> Void
    let close: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            TextField("Search...", text: $query)
                .textFieldStyle(.plain)
                .frame(minWidth: 110, idealWidth: 170)
                .focused($focused)
                .onSubmit(next)
                .onExitCommand(perform: close)
                .accessibilityLabel("Search terminal")
            toggle("case-sensitive", label: "Case sensitive", value: $caseSensitive)
            toggle("regex", label: "Regex", value: $regex)
            Text(result)
                .font(SmthzFont.ui(size: 11))
                .foregroundStyle(SmthzTheme.mutedForeground)
                .monospacedDigit()
                .frame(minWidth: 58)
                .accessibilityLabel(result)
            button("chevron-up", label: "Previous match", action: previous)
            button("chevron-down", label: "Next match", action: next)
            button("x", label: "Close", action: close)
        }
        .font(SmthzFont.ui(size: 12))
        .foregroundStyle(SmthzTheme.foreground)
        .padding(6)
        .background(SmthzTheme.popover, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SmthzTheme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
        .frame(maxWidth: 430)
        .onAppear { focused = true }
    }

    private func toggle(_ icon: String, label: String, value: Binding<Bool>) -> some View {
        Button { value.wrappedValue.toggle() } label: {
            SmthzIcon.image(icon).frame(width: 14, height: 14)
                .frame(width: 24, height: 24)
                .background(value.wrappedValue ? SmthzTheme.accent : .clear, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(value.wrappedValue ? "On" : "Off")
        .smthzTooltip(label)
    }

    private func button(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            SmthzIcon.image(icon).frame(width: 14, height: 14).frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .smthzTooltip(label)
    }
}

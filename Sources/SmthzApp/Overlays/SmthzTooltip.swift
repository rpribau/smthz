import SwiftUI

/// Add `.smthzTooltip("Toggle sidebar", edge: .bottom)` to a control.
/// A cancellable 400 ms hover delay presents an inverted pill with a 10 pt arrow.
struct SmthzTooltip: ViewModifier {
    let text: String
    var edge: Edge = .bottom
    @State private var hovered = false
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .onHover { hovered = $0 }
            .task(id: hovered) {
                visible = false
                guard hovered else { return }
                do {
                    try await Task.sleep(for: .milliseconds(400))
                    try Task.checkCancellation()
                    visible = true
                } catch { /* Leaving the control cancels its pending tooltip. */ }
            }
            .onDisappear { hovered = false; visible = false }
            .overlay(alignment: alignment) {
                if visible {
                    tooltip
                        .fixedSize()
                        .alignmentGuide(alignment.horizontal) { dimensions in
                            switch edge {
                            case .leading: dimensions[.trailing] + 6
                            case .trailing: -6
                            default: dimensions[HorizontalAlignment.center]
                            }
                        }
                        .alignmentGuide(alignment.vertical) { dimensions in
                            switch edge {
                            case .top: dimensions[.bottom] + 6
                            case .bottom: -6
                            default: dimensions[VerticalAlignment.center]
                            }
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityHint(text)
            .zIndex(visible ? 100 : 0)
    }

    private var alignment: Alignment {
        switch edge {
        case .top: .top
        case .bottom: .bottom
        case .leading: .leading
        case .trailing: .trailing
        }
    }

    private var tooltip: some View {
        Text(text)
            .font(SmthzFont.ui(size: 12))
            .foregroundStyle(SmthzTheme.background)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(SmthzTheme.foreground, in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: arrowAlignment) {
                Rectangle().fill(SmthzTheme.foreground)
                    .frame(width: 10, height: 10).rotationEffect(.degrees(45))
                    .offset(x: arrowOffset.width, y: arrowOffset.height)
            }
    }

    private var arrowAlignment: Alignment {
        switch edge {
        case .top: .bottom
        case .bottom: .top
        case .leading: .trailing
        case .trailing: .leading
        }
    }

    private var arrowOffset: CGSize {
        switch edge {
        case .top: .init(width: 0, height: 3)
        case .bottom: .init(width: 0, height: -3)
        case .leading: .init(width: 3, height: 0)
        case .trailing: .init(width: -3, height: 0)
        }
    }
}

extension View {
    /// Shows the custom smthz tooltip after 400 ms; apply near the outermost control modifier.
    func smthzTooltip(_ text: String, edge: Edge = .bottom) -> some View {
        modifier(SmthzTooltip(text: text, edge: edge))
    }
}

#Preview("Hover for 400 ms") {
    Button("Hover here") {}.buttonStyle(SmthzButtonStyle(.secondary))
        .smthzTooltip("Create workspace (⌘N)")
        .padding(80).background(SmthzTheme.background)
}

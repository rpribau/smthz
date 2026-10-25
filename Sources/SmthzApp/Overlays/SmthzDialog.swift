import SwiftUI

/// A centred §10 panel. Usually present with `.smthzDialog(isPresented:title:description:)`.
/// Content and footer are caller-owned; footer buttons retain their actual action labels.
struct SmthzDialog<Content: View, Footer: View>: View {
    let title: String
    var description: String? = nil
    var compact = false
    let onDismiss: () -> Void
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @FocusState private var closeFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(SmthzFont.ui(size: compact ? 14 : 18, weight: .semibold))
                    .foregroundStyle(SmthzTheme.foreground)
                    .accessibilityAddTraits(.isHeader)
                if let description {
                    Text(description)
                        .font(SmthzFont.ui(size: 14))
                        .foregroundStyle(SmthzTheme.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.trailing, 24)
            content()
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                footer()
            }
        }
        .padding(24)
        .frame(maxWidth: compact ? 384 : 512, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .fill((colorScheme == .dark ? SmthzTheme.card : SmthzTheme.background)
                            .opacity(reduceTransparency ? 1 : 0.96))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(colorScheme == .dark ? .white.opacity(0.14) : .black.opacity(0.14), lineWidth: 1)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(.white.opacity(colorScheme == .dark ? 0.05 : 0.3), lineWidth: 1)
                .padding(1)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topTrailing) {
            Button(action: onDismiss) {
                SmthzIcon.image(.x).resizable().scaledToFit()
                    .frame(width: 14, height: 14).opacity(0.7)
            }
            .buttonStyle(SmthzButtonStyle(.ghost, size: .iconXS))
            .accessibilityLabel("Close dialog")
            .focused($closeFocused)
            .padding(11)
        }
        .shadow(color: .black.opacity(0.28), radius: 30, y: 20)
        .font(SmthzFont.ui(size: 14))
        .foregroundStyle(SmthzTheme.foreground)
        .onExitCommand(perform: onDismiss)
        .onAppear { closeFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

private struct SmthzDialogPresentation<DialogContent: View, Footer: View>: ViewModifier {
    @Binding var isPresented: Bool
    let title: String
    let description: String?
    let compact: Bool
    @ViewBuilder let dialogContent: () -> DialogContent
    @ViewBuilder let footer: () -> Footer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        ZStack {
            content
                .blur(radius: isPresented && !reduceTransparency ? 2 : 0)
                .disabled(isPresented)
                .accessibilityHidden(isPresented)
            if isPresented {
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { isPresented = false }
                    .accessibilityHidden(true)
                    .transition(.opacity)
                SmthzDialog(title: title, description: description, compact: compact,
                           onDismiss: { isPresented = false }, content: dialogContent, footer: footer)
                    .padding(24)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.95)))
                    .zIndex(1)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isPresented)
    }
}

extension View {
    /// Apply to the full window content so dimming and keyboard isolation cover the complete shell.
    /// Example: `.smthzDialog(isPresented: $show, title: "Create workspace") { fields } footer: { buttons }`.
    func smthzDialog<DialogContent: View, Footer: View>(
        isPresented: Binding<Bool>, title: String, description: String? = nil, compact: Bool = false,
        @ViewBuilder content: @escaping () -> DialogContent,
        @ViewBuilder footer: @escaping () -> Footer
    ) -> some View {
        modifier(SmthzDialogPresentation(isPresented: isPresented, title: title, description: description,
                                       compact: compact, dialogContent: content, footer: footer))
    }
}

#Preview("Centred dialog") {
    @Previewable @State var shown = true
    @Previewable @State var name = ""
    SmthzTheme.background
        .smthzDialog(isPresented: $shown, title: "Create workspace", description: "Choose a name for your workspace.") {
            TextField("Workspace name", text: $name).textFieldStyle(.roundedBorder).tint(SmthzTheme.foreground)
        } footer: {
            Button("Cancel") { shown = false }.buttonStyle(SmthzButtonStyle(.outline))
            Button("Create workspace") { shown = false }.buttonStyle(SmthzButtonStyle())
        }
        .frame(width: 700, height: 440)
}

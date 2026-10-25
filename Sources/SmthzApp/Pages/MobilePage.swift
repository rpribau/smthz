import SwiftUI

// VISUAL-ONLY: stub data until the smthz mobile app and own relay/auth service.
/// No installation URL or QR is fabricated. Platform/channel selection is local UI state.
struct SmthzMobilePage: View {
    var onClose: () -> Void = {}
    @AppStorage("sidebar.showMobileButton") private var showMobileButton = true
    @State private var platform = "iOS"
    @State private var channel = "Preview"

    private var installLabel: String {
        platform == "Android" ? "Download APK" : channel == "Preview" ? "Open TestFlight" : "Open App Store"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(showMobileButton ? "Hide from sidebar" : "Show in sidebar") { showMobileButton.toggle() }
                    .buttonStyle(SmthzButtonStyle(showMobileButton ? .primary : .secondary, size: .small))
                    .help(showMobileButton ? "Configure in Settings > Mobile." : "Adds the shortcut back to the sidebar.")
                Spacer()
                SmthzDestinationCloseButton(label: "Close smthz Mobile", onClose: onClose)
            }.padding(16)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("smthz Mobile").font(SmthzFont.ui(size: 24, weight: .semibold))
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .center, spacing: 40) { installCopy; qrSlot }
                        VStack(alignment: .leading, spacing: 24) { installCopy; qrSlot.frame(maxWidth: .infinity) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(32)
                    .background(SmthzTheme.card, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(SmthzTheme.border))
                    HStack {
                        Spacer()
                        Button("Continue") {}.buttonStyle(SmthzButtonStyle()).disabled(true).help("Not available yet")
                    }
                }.frame(maxWidth: 880).padding(24).frame(maxWidth: .infinity)
            }
        }
        .foregroundStyle(SmthzTheme.foreground).background(SmthzTheme.background)
        .onExitCommand(perform: onClose)
    }

    private var installCopy: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text("1").font(SmthzFont.ui(size: 12, weight: .semibold)).frame(width: 24, height: 24)
                    .background(SmthzTheme.muted, in: Circle()).accessibilityHidden(true)
                Text("Step 1 of 2").font(SmthzFont.ui(size: 12, weight: .medium))
                    .foregroundStyle(SmthzTheme.mutedForeground)
            }
            Text("Get the app.").font(SmthzFont.ui(size: 36, weight: .semibold))
            Text("Scan the QR with your phone or open the install link to grab smthz Mobile.")
                .font(SmthzFont.ui(size: 14)).foregroundStyle(SmthzTheme.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
            selectionControl("Platform", options: ["iOS", "Android"], selection: $platform)
            if platform == "iOS" {
                selectionControl("Release channel", options: ["Preview", "Stable"], selection: $channel)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { installButton; copyButton }
                VStack(alignment: .leading, spacing: 8) { installButton; copyButton }
            }
            Text("smthz Mobile is not available yet.")
                .font(SmthzFont.ui(size: 12)).foregroundStyle(SmthzTheme.mutedForeground)
        }.frame(minWidth: 240, maxWidth: 440, alignment: .leading)
    }

    private func selectionControl(_ label: String, options: [String], selection: Binding<String>) -> some View {
        HStack(spacing: 3) {
            ForEach(options, id: \.self) { option in
                Button { selection.wrappedValue = option } label: {
                    Text(option).font(SmthzFont.ui(size: 13, weight: .medium))
                        .padding(.horizontal, 16).frame(height: 28)
                        .background(selection.wrappedValue == option ? SmthzTheme.background : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain).accessibilityAddTraits(selection.wrappedValue == option ? .isSelected : [])
            }
        }.padding(3).background(SmthzTheme.muted, in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .contain).accessibilityLabel(label)
    }

    private var installButton: some View {
        Button(installLabel) {}.buttonStyle(SmthzButtonStyle(.outline, size: .small))
            .disabled(true).help("Not available yet")
    }

    private var copyButton: some View {
        Button {} label: {
            HStack(spacing: 6) { SmthzIcon.view(.copy, size: 14); Text("Copy install link") }
        }.buttonStyle(SmthzButtonStyle(.ghost, size: .small)).disabled(true).help("Not available yet")
    }

    private var qrSlot: some View {
        VStack(spacing: 12) {
            SmthzIcon.view(.smartphone, size: 40).foregroundStyle(SmthzTheme.mutedForeground)
            Text("Install QR").font(SmthzFont.ui(size: 12, weight: .medium))
            Text("Not available yet").font(SmthzFont.ui(size: 12)).foregroundStyle(SmthzTheme.mutedForeground)
        }
        .frame(width: 196, height: 196)
        .background(SmthzTheme.muted.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(SmthzTheme.border, style: StrokeStyle(lineWidth: 1, dash: [4])))
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
#Preview("Mobile · Light") { SmthzMobilePage().frame(width: 1000, height: 680).preferredColorScheme(.light) }
#Preview("Mobile · Dark") { SmthzMobilePage().frame(width: 1000, height: 680).preferredColorScheme(.dark) }
#endif

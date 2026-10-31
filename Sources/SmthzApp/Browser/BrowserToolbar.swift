import AppKit
import SmthzCore
import SwiftUI

/// Back/forward/reload, address bar with search fallback, zoom badge and page menu.
struct BrowserToolbar: View {
    @Bindable var tab: BrowserTab
    let store: BrowserTabStore
    @FocusState private var addressFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            iconButton(.arrowLeft, help: "Back (⌘[)", disabled: !tab.canGoBack, action: tab.goBack)
            iconButton(.arrowRight, help: "Forward (⌘])", disabled: !tab.canGoForward, action: tab.goForward)
            if tab.isLoading {
                iconButton(.x, help: "Stop loading", action: tab.stop)
            } else {
                iconButton("rotate-cw", help: "Reload (⌘R, ⇧⌘R hard reload)", action: tab.reload)
            }
            address
            if tab.zoomPercent != 100 {
                Button("\(tab.zoomPercent)%") { tab.setZoom(.reset) }
                    .buttonStyle(SmthzButtonStyle(.outline, size: .xs)).help("Reset zoom (⌘0)")
            }
            menu
        }
        .padding(.horizontal, 8)
        .frame(height: 36)
        .background(SmthzTheme.background)
        .overlay(alignment: .bottom) {
            ZStack(alignment: .leading) {
                Rectangle().fill(SmthzTheme.border).frame(height: 1)
                if tab.isLoading {
                    GeometryReader { proxy in
                        Rectangle().fill(SmthzTheme.ring).frame(width: proxy.size.width * max(0.05, tab.progress), height: 2)
                    }.frame(height: 2)
                }
            }
        }
        .onChange(of: tab.addressFocusRequest, initial: true) { _, request in
            if request > 0 { addressFocused = true }
        }
    }

    private var address: some View {
        HStack(spacing: 6) {
            if tab.isSecure {
                SmthzIcon.view(.lock, size: 11).foregroundStyle(SmthzTheme.mutedForeground).help("Secure connection")
            } else {
                SmthzIcon.view(.globe, size: 11).foregroundStyle(SmthzTheme.mutedForeground)
            }
            TextField("Search \(store.searchEngine.label) or enter an address", text: $tab.addressText)
                .textFieldStyle(.plain)
                .font(SmthzFont.ui(size: 12))
                .focused($addressFocused)
                .onSubmit {
                    if tab.navigate(tab.addressText) { addressFocused = false; tab.focusPage() }
                }
                .onKeyPress(.escape) {
                    tab.addressText = BrowserURLInput.displayText(tab.url)
                    addressFocused = false
                    tab.focusPage()
                    return .handled
                }
                .accessibilityLabel("Address and search bar")
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(SmthzTheme.input.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(addressFocused ? SmthzTheme.ring : SmthzTheme.border))
    }

    private var menu: some View {
        Menu {
            Button("Hard Reload") { tab.hardReload() }
            Button("Find in Page…") { tab.find.show() }
            Divider()
            Button("Zoom In") { tab.setZoom(.zoomIn) }
            Button("Zoom Out") { tab.setZoom(.zoomOut) }
            Button("Actual Size") { tab.setZoom(.reset) }
            Divider()
            Button("Copy Address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tab.url ?? "", forType: .string)
            }.disabled(tab.url == nil || tab.url == BrowserURLInput.blankURL)
            Button("Open in Default Browser") {
                if let target = tab.url.flatMap(BrowserURLInput.normalizeExternal), let url = URL(string: target) {
                    NSWorkspace.shared.open(url)
                }
            }.disabled(tab.url.flatMap(BrowserURLInput.normalizeExternal) == nil)
            Button("Reopen Closed Browser Tab") { store.reopenClosed() }.disabled(store.closedURLs.isEmpty)
            Divider()
            Toggle("Allow Web Inspector", isOn: $tab.inspectable)
            Picker("Search Engine", selection: Binding(get: { store.searchEngine }, set: { store.searchEngine = $0 })) {
                ForEach(BrowserSearchEngine.allCases, id: \.self) { Text($0.label).tag($0) }
            }
        } label: {
            SmthzIcon.view(.ellipsis, size: 14)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(SmthzButtonStyle(.ghost, size: .iconSmall))
        .fixedSize()
        .help("Page actions")
    }

    private func iconButton(_ name: SmthzIcon.Name, help: String, disabled: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) { SmthzIcon.view(name, size: 14) }
            .buttonStyle(SmthzButtonStyle(.ghost, size: .iconSmall))
            .disabled(disabled)
            .help(help)
            .accessibilityLabel(help)
    }
}

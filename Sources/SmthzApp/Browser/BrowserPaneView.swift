import AppKit
import SmthzCore
import SwiftUI
import WebKit

/// The active browser tab: toolbar, optional find bar, page, error banner,
/// downloads shelf and page dialogs.
struct BrowserPaneView: View {
    let store: BrowserTabStore
    let tab: BrowserTab
    @State private var keyMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            BrowserToolbar(tab: tab, store: store)
            if tab.find.visible { BrowserFindBar(model: tab.find) }
            ZStack(alignment: .top) {
                BrowserWebViewHost(webView: tab.webView).id(tab.id)
                if let error = tab.loadError { errorBanner(error) }
            }
            if !store.downloads.items.isEmpty { BrowserDownloadsShelf(center: store.downloads) }
        }
        .background(SmthzTheme.background)
        .modifier(BrowserDialogsModifier(tab: tab))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Browser")
        .onAppear(perform: installKeys)
        .onDisappear(perform: removeKeys)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            SmthzIcon.view(.alertTriangle, size: 13).foregroundStyle(SmthzTheme.statusWarning)
            Text(message).font(SmthzFont.ui(size: 12)).lineLimit(2)
            Spacer()
            Button("Reload") { tab.reload() }.buttonStyle(SmthzButtonStyle(.outline, size: .xs))
            Button { tab.loadError = nil } label: { SmthzIcon.view(.x, size: 11) }
                .buttonStyle(SmthzButtonStyle(.ghost, size: .iconXS)).help("Dismiss")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(SmthzTheme.card))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SmthzTheme.border))
        .padding(12)
    }

    // MARK: Keys
    // Browser chords (Orca defaults) are taken here, ahead of menu key equivalents that
    // reuse them (⇧⌘R force reload, ⌘=/⌘-/⌘0 UI zoom), only while this pane is shown and
    // the key window holds it. The registry still lists browser.* as unavailable.

    private func installKeys() {
        removeKeys()
        let store = store
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { BrowserKeyRouter.handle(event, store: store) } ? nil : event
        }
    }

    private func removeKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

@MainActor enum BrowserKeyRouter {
    static func handle(_ event: NSEvent, store: BrowserTabStore) -> Bool {
        guard let tab = store.activeTab, let window = tab.webView.window, window.isKeyWindow,
              event.window === window, tab.dialog == nil else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == .command {
            switch key {
            case "f": tab.find.show()
            case "l": tab.focusAddressBar()
            case "r": tab.reload()
            case "[": tab.goBack()
            case "]": tab.goForward()
            case "=", "+": tab.setZoom(.zoomIn)
            case "-": tab.setZoom(.zoomOut)
            case "0": tab.setZoom(.reset)
            default: return false
            }
            return true
        }
        if flags == [.command, .shift] {
            switch key {
            case "r": tab.hardReload()
            case "+", "=": tab.setZoom(.zoomIn)
            default: return false
            }
            return true
        }
        return false
    }
}

/// Hosts the tab's persistent WKWebView inside a plain container so SwiftUI can
/// swap tabs without recreating pages.
struct BrowserWebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if webView.superview !== container { attach(to: container) }
    }

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        container.subviews.forEach { $0.removeFromSuperview() }
    }

    private func attach(to container: NSView) {
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }
}

import SwiftUI
import WebKit

/// Find in page through `WKWebView.find` (⌘F, Return / ⇧Return, Esc).
@MainActor @Observable final class BrowserFindModel {
    @ObservationIgnored weak var webView: WKWebView?
    var visible = false
    var query = ""
    var caseSensitive = false
    private(set) var matchFound: Bool?
    /// Bumped to focus the field when ⌘F is pressed while the bar is already open.
    private(set) var focusRequest = 0

    func show() { visible = true; focusRequest += 1 }

    func hide() {
        visible = false
        matchFound = nil
        Task { _ = try? await webView?.evaluateJavaScript("window.getSelection()?.removeAllRanges()") }
        webView?.window?.makeFirstResponder(webView)
    }

    func search(backwards: Bool = false) {
        guard let webView, !query.isEmpty else { matchFound = nil; return }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = caseSensitive
        configuration.wraps = true
        let text = query
        Task {
            let result = try? await webView.find(text, configuration: configuration)
            if text == query { matchFound = result?.matchFound ?? false }
        }
    }
}

struct BrowserFindBar: View {
    @Bindable var model: BrowserFindModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            SmthzIcon.view(.search, size: 12).foregroundStyle(SmthzTheme.mutedForeground)
            TextField("Find in page", text: $model.query)
                .textFieldStyle(.plain).font(SmthzFont.ui(size: 12)).focused($focused)
                .onSubmit { model.search(backwards: NSEvent.modifierFlags.contains(.shift)) }
                .onChange(of: model.query) { _, _ in model.search() }
                .onKeyPress(.escape) { model.hide(); return .handled }
                .accessibilityLabel("Find in page")
            if model.matchFound == false {
                Text("No matches").font(SmthzFont.meta).foregroundStyle(SmthzTheme.destructive)
            }
            Toggle("Aa", isOn: $model.caseSensitive).toggleStyle(.button).controlSize(.small)
                .help("Match case").onChange(of: model.caseSensitive) { _, _ in model.search() }
            Button { model.search(backwards: true) } label: { SmthzIcon.view(.chevronUp, size: 12) }
                .buttonStyle(SmthzButtonStyle(.ghost, size: .iconXS)).help("Previous match").disabled(model.query.isEmpty)
            Button { model.search() } label: { SmthzIcon.view(.chevronDown, size: 12) }
                .buttonStyle(SmthzButtonStyle(.ghost, size: .iconXS)).help("Next match").disabled(model.query.isEmpty)
            Button { model.hide() } label: { SmthzIcon.view(.x, size: 12) }
                .buttonStyle(SmthzButtonStyle(.ghost, size: .iconXS)).help("Close find bar")
        }
        .padding(.horizontal, 8).frame(height: 30)
        .background(SmthzTheme.background)
        .overlay(alignment: .bottom) { Rectangle().fill(SmthzTheme.border).frame(height: 1) }
        .task(id: model.focusRequest) {
            // The web view holds first responder; take focus once the field is in the window.
            try? await Task.sleep(for: .milliseconds(50))
            model.webView?.window?.makeFirstResponder(nil)
            focused = true
        }
    }
}

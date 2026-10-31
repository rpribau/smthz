import AppKit
import Observation
import SmthzCore
import WebKit

/// App-local browser tabs (WP-B1). ShellModel only knows terminal tabs, so these
/// live beside it: not persisted, not splittable, shown after the terminal tabs.
@MainActor @Observable final class BrowserTabStore {
    static let shared = BrowserTabStore()
    static let idPrefix = "browser:"

    private(set) var tabs: [BrowserTab] = []
    /// Non-nil while a browser tab is the visible workspace surface.
    private(set) var activeID: String?
    private(set) var closedURLs: [String] = []
    let downloads = BrowserDownloadCenter()
    var searchEngine = BrowserURLInput.defaultSearchEngine

    var activeTab: BrowserTab? { tabs.first { $0.id == activeID } }

    func isBrowserID(_ id: String) -> Bool { id.hasPrefix(Self.idPrefix) }

    /// Terminal items with their active flag cleared while a browser tab is shown, then browser items.
    func merge(_ terminals: [ShellTabItem]) -> [ShellTabItem] {
        let shown = activeID != nil
        return terminals.map { item in
            var item = item
            if shown { item.active = false }
            return item
        } + tabs.map { tab in
            ShellTabItem(id: tab.id, title: tab.displayTitle, active: tab.id == activeID, kind: "Browser",
                         cwd: BrowserURLInput.displayText(tab.url))
        }
    }

    @discardableResult
    func newTab(url: String = BrowserURLInput.blankURL, configuration: WKWebViewConfiguration? = nil, activate: Bool = true) -> BrowserTab {
        let tab = BrowserTab(id: Self.idPrefix + UUID().uuidString.lowercased(), store: self, configuration: configuration)
        tabs.append(tab)
        if activate { activeID = tab.id }
        if configuration == nil {
            if url == BrowserURLInput.blankURL { tab.focusAddressBar() } else { tab.navigate(url) }
        }
        return tab
    }

    /// Returns false for non-browser ids so callers can fall through to terminals.
    @discardableResult func select(_ id: String) -> Bool {
        guard isBrowserID(id), tabs.contains(where: { $0.id == id }) else { return false }
        activeID = id
        return true
    }

    /// A terminal tab took focus.
    func deactivate() { activeID = nil }

    @discardableResult func close(_ id: String) -> Bool {
        guard isBrowserID(id), let index = tabs.firstIndex(where: { $0.id == id }) else { return isBrowserID(id) }
        let tab = tabs.remove(at: index)
        if let url = tab.url, url != BrowserURLInput.blankURL { closedURLs.append(url) }
        if closedURLs.count > 20 { closedURLs.removeFirst(closedURLs.count - 20) }
        tab.tearDown()
        if activeID == id { activeID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id }
        return true
    }

    func reopenClosed() {
        guard let url = closedURLs.popLast() else { return }
        newTab(url: url)
    }
}

/// One page. Owns its WKWebView so the page survives tab switches.
@MainActor @Observable final class BrowserTab: NSObject, Identifiable {
    let id: String
    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private weak var store: BrowserTabStore?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    private(set) var title = ""
    private(set) var url: String?
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isLoading = false
    private(set) var progress = 0.0
    private(set) var isSecure = false
    private(set) var zoom = 1.0
    var loadError: String?
    var addressText = ""
    /// Bumped to move keyboard focus to the address bar.
    private(set) var addressFocusRequest = 0
    var inspectable: Bool {
        get { inspectableState }
        set { webView.isInspectable = newValue; inspectableState = newValue }
    }
    private var inspectableState = false
    let find = BrowserFindModel()
    var dialog: BrowserDialogRequest?

    var displayTitle: String {
        if !title.isEmpty { return title }
        guard let url, url != BrowserURLInput.blankURL else { return "New Tab" }
        return URL(string: url)?.host ?? url
    }
    var zoomPercent: Int { BrowserPageZoom.percent(zoom) }

    init(id: String, store: BrowserTabStore, configuration: WKWebViewConfiguration?) {
        self.id = id
        self.store = store
        let config = configuration ?? {
            let config = WKWebViewConfiguration()
            // Profiles (WP-B2) replace the default data store later.
            config.websiteDataStore = .default()
            config.preferences.isElementFullscreenEnabled = true
            return config
        }()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
        find.webView = webView
        observe()
    }

    private func observe() {
        func watch<Value>(_ path: KeyPath<WKWebView, Value>) -> NSKeyValueObservation {
            webView.observe(path, options: [.initial, .new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.sync() }
            }
        }
        observations = [watch(\.title), watch(\.url), watch(\.canGoBack), watch(\.canGoForward),
                        watch(\.isLoading), watch(\.estimatedProgress), watch(\.hasOnlySecureContent)]
    }

    private func sync() {
        title = webView.title ?? ""
        let current = webView.url?.absoluteString
        if current != url {
            url = current
            addressText = BrowserURLInput.displayText(current)
        }
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        isLoading = webView.isLoading
        progress = webView.estimatedProgress
        isSecure = webView.url?.scheme == "https" && webView.hasOnlySecureContent
    }

    // MARK: Commands

    /// Address bar entry. Returns false when the input is rejected (e.g. `javascript:`).
    @discardableResult func navigate(_ input: String) -> Bool {
        guard let target = BrowserURLInput.normalize(input, search: store?.searchEngine ?? .google),
              let url = URL(string: target) else {
            loadError = "Cannot open \u{201C}\(input)\u{201D}: only http, https and file addresses are allowed."
            return false
        }
        loadError = nil
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
        addressText = BrowserURLInput.displayText(target)
        return true
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { loadError = nil; webView.reload() }
    func hardReload() { loadError = nil; webView.reloadFromOrigin() }
    func stop() { webView.stopLoading() }
    func setZoom(_ direction: BrowserPageZoom.Direction) {
        zoom = BrowserPageZoom.next(zoom, direction)
        webView.pageZoom = zoom
    }
    func focusAddressBar() { addressFocusRequest += 1 }
    func focusPage() { webView.window?.makeFirstResponder(webView) }

    func tearDown() {
        dialog?.cancel()
        dialog = nil
        observations.removeAll()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
    }

    private func externalOpenRefused(_ url: URL) {
        loadError = "Blocked navigation to \u{201C}\(url.scheme ?? "unknown"):\u{201D} links."
    }
}

extension BrowserTab: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        if action.shouldPerformDownload { return (.download, preferences) }
        guard let url = action.request.url else { return (.cancel, preferences) }
        switch url.scheme?.lowercased() {
        case "http", "https", "file", "about", "data", "blob":
            return (.allow, preferences)
        default:
            if action.targetFrame?.isMainFrame != false { externalOpenRefused(url) }
            return (.cancel, preferences)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if let http = response.response as? HTTPURLResponse,
           http.value(forHTTPHeaderField: "Content-Disposition")?.lowercased().hasPrefix("attachment") == true {
            return .download
        }
        return response.canShowMIMEType ? .allow : .download
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        store?.downloads.track(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        store?.downloads.track(download)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { loadError = nil }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        report(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { report(error) }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loadError = "This page stopped responding. Reload to try again."
    }

    func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let method = challenge.protectionSpace.authenticationMethod
        guard [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest,
               NSURLAuthenticationMethodNTLM].contains(method) else { return (.performDefaultHandling, nil) }
        if challenge.previousFailureCount > 2 { return (.rejectProtectionSpace, nil) }
        let space = challenge.protectionSpace
        let origin = "\(space.protocol ?? "https")://\(space.host)\(space.port == 80 || space.port == 443 ? "" : ":\(space.port)")"
        guard let (user, password) = await BrowserDialogRequest.present(on: self, { .auth(origin: origin, realm: space.realm, resume: $0) })
        else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(user: user, password: password, persistence: .forSession))
    }

    private func report(_ error: any Error) {
        let ns = error as NSError
        // Cancelled loads and policy changes (downloads) are not failures.
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && ns.code == 102 { return }
        loadError = ns.localizedDescription
    }
}

extension BrowserTab: WKUIDelegate {
    /// `window.open` and target=_blank links open as new browser tabs.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        store?.newTab(configuration: configuration).webView
    }

    func webViewDidClose(_ webView: WKWebView) { _ = store?.close(id) }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        _ = await BrowserDialogRequest.present(on: self) { .alert(origin: frame.securityOrigin.host, message: message, resume: $0) }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await BrowserDialogRequest.present(on: self) { .confirm(origin: frame.securityOrigin.host, message: message, resume: $0) } ?? false
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        await BrowserDialogRequest.present(on: self) {
            .prompt(origin: frame.securityOrigin.host, message: prompt, defaultText: defaultText ?? "", resume: $0)
        }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        if let window = webView.window {
            return await panel.beginSheetModal(for: window) == .OK ? panel.urls : nil
        }
        return panel.runModal() == .OK ? panel.urls : nil
    }
}

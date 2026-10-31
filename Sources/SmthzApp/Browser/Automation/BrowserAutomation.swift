import AppKit
import SmthzCore
import WebKit

/// App-side executor for `smthz browser ...` (WP-B4, BROWSER-AGENTS-EXPERIMENT A.4-A.6). Every request
/// arrives through BrowserAutomationProvider and runs here on the main actor against BrowserTabStore.
@MainActor final class BrowserAutomation: NSObject, WKScriptMessageHandler {
    static let shared = BrowserAutomation()
    static let consoleLimit = 1000
    static let networkLimit = 500
    private static let world = WKContentWorld.world(name: "smthz")

    /// Per-tab state the page cannot hold: capture buffers and settings re-applied on every load.
    final class PageState {
        struct Config: Codable {
            struct Geo: Codable { var latitude: Double; var longitude: Double; var accuracy: Double? }
            var headers: [String: String] = [:]
            var intercept = false
            var patterns: [String] = []
            var offline = false
            var reducedMotion: String?
            var geo: Geo?
        }
        var config = Config()
        var console: [BrowserConsoleEntry] = []
        var consoleDropped = 0
        var network: [BrowserNetworkEntry] = []
        var networkDropped = 0
        var intercepted: [BrowserInterceptedRequest] = []
        var capturing = false
        var credential: URLCredential?
        var viewport: CGSize?
        var viewportConstraints: [NSLayoutConstraint] = []
        var profileID = BrowserProfileStore.builtInID
        var mouse = CGPoint(x: 0, y: 0)
    }

    private var pages: [String: PageState] = [:]
    /// The tab `tab switch` picked for automation without focusing it in the UI.
    private var currentID: String?
    private var store: BrowserTabStore { .shared }
    private lazy var profiles = BrowserProfileStore(stateDirectory: HostController.stateDirectory)
    /// Tabs that are not shown in a pane live here so JS, snapshots and keys keep working (A.6).
    private lazy var offscreen: NSWindow = {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 1280, height: 800),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.orderFrontRegardless()
        return window
    }()

    private func state(_ tab: BrowserTab) -> PageState {
        if let state = pages[tab.id] { return state }
        let state = PageState()
        pages[tab.id] = state
        return state
    }

    // MARK: Hooks from BrowserTabModel

    /// Called for every new tab configuration (including popups) before its WKWebView exists.
    static func prepare(_ configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        controller.removeScriptMessageHandler(forName: "smthzAutomation", contentWorld: .page)
        controller.add(shared, contentWorld: .page, name: "smthzAutomation")
        if !controller.userScripts.contains(where: { $0.source.contains("__smthzConfigure") }) {
            controller.addUserScript(pageScript(PageState.Config()))
        }
    }

    private static func pageScript(_ config: PageState.Config) -> WKUserScript {
        let json = (try? JSONEncoder().encode(config)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return WKUserScript(source: BrowserRuntimeScript.page.replacingOccurrences(of: "__SMTHZ_CONFIG__", with: json),
                            injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)
    }

    func credential(for tab: BrowserTab) -> URLCredential? { pages[tab.id]?.credential }

    func recordDocument(_ tab: BrowserTab, _ response: URLResponse) {
        let http = response as? HTTPURLResponse
        append(BrowserNetworkEntry(url: response.url?.absoluteString ?? "", method: "GET", status: http?.statusCode,
                                   mimeType: response.mimeType, size: response.expectedContentLength >= 0 ? Int(response.expectedContentLength) : nil,
                                   source: .document), to: state(tab))
    }

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard let body = message.body as? [String: Any], let webView = message.webView,
                  let tab = store.tabs.first(where: { $0.webView === webView }) else { return }
            let state = state(tab)
            switch body["t"] as? String {
            case "console":
                state.console.append(BrowserConsoleEntry(level: body["level"] as? String ?? "log", text: body["text"] as? String ?? "",
                                                         timestamp: Date().timeIntervalSince1970 * 1000))
                if state.console.count > Self.consoleLimit { state.console.removeFirst(); state.consoleDropped += 1 }
            case "net":
                append(BrowserNetworkEntry(url: body["url"] as? String ?? "", method: body["method"] as? String,
                                           status: body["status"] as? Int, mimeType: body["mime"] as? String,
                                           size: body["size"] as? Int,
                                           source: BrowserNetworkSource(rawValue: body["source"] as? String ?? "") ?? .script), to: state)
            case "intercept":
                state.intercepted.append(BrowserInterceptedRequest(id: body["id"] as? String ?? "", method: body["method"] as? String ?? "GET",
                                                                   url: body["url"] as? String ?? "", resourceType: body["type"] as? String ?? "fetch"))
            default: break
            }
        }
    }

    private func append(_ entry: BrowserNetworkEntry, to state: PageState) {
        state.network.append(entry)
        if state.network.count > Self.networkLimit { state.network.removeFirst(); state.networkDropped += 1 }
    }

    // MARK: Dispatch

    func run(_ request: BrowserRequest) async throws -> BrowserResult {
        let a = request.arguments
        let command = request.command
        func action(_ element: String? = nil, trusted: Bool? = nil, detail: String? = nil) -> BrowserResult {
            .action(BrowserActionResult(command: command, element: element, trusted: trusted, detail: detail))
        }
        switch command {
        case .exec: return .unsupported(command)

        // Identity and profiles (host-wide).
        case .identityGet: return .identity(identity())
        case .identitySet:
            if a.reset == true { UserDefaults.standard.removeObject(forKey: "browserIdentityMode") }
            else { UserDefaults.standard.set(a.mode?.rawValue, forKey: "browserIdentityMode") }
            store.tabs.forEach(applyIdentity)
            return .identity(identity())
        case .profileList:
            let defaultID = profiles.defaultProfile.id
            return .profileList(BrowserProfileListResult(profiles: profiles.profiles.map { info($0, defaultID: defaultID) }))
        case .profileCreate:
            let kind: BrowserProfileKind = a.scope == .imported ? .imported : .isolated
            return .profile(BrowserProfileResult(profile: info(try profileCall { try profiles.create(label: a.label ?? "", scope: kind) })))
        case .profileDelete:
            let id = a.profileId ?? ""
            switch try profileCall({ try profiles.delete(id: id) }) {
            case .deferred: return .profile(BrowserProfileResult(deleted: true, deferred: true))
            case .removed(let identifier):
                await removeDataStore(identifier)
                return .profile(BrowserProfileResult(deleted: true, deferred: false))
            }

        // Tabs.
        case .tabList:
            return .tabList(BrowserTabListResult(tabs: store.tabs.indices.map { tabInfo(store.tabs[$0], index: $0) }))
        case .tabCurrent, .tabShow:
            let tab = try resolve(request.target)
            return .tab(tabInfo(tab, index: store.tabs.firstIndex { $0 === tab } ?? 0))
        case .tabSwitch:
            let tab: BrowserTab
            if let index = a.index {
                guard store.tabs.indices.contains(index) else { throw HostRPCError("pageNotFound", detail: "No browser tab at index \(index)") }
                tab = store.tabs[index]
            } else { tab = try resolve(request.target) }
            currentID = tab.id
            if a.focus == true { store.select(tab.id) }
            return .tab(tabInfo(tab, index: store.tabs.firstIndex { $0 === tab } ?? 0))
        case .tabCreate:
            let tab = try makeTab(profileID: a.profileId ?? profiles.defaultProfile.id, activate: false)
            if let url = a.url { try await load(tab, url) }
            return .navigation(navigation(tab))
        case .openURL:
            let tab = try makeTab(profileID: profiles.defaultProfile.id, activate: true)
            try await load(tab, a.url ?? "")
            return .navigation(navigation(tab))
        case .tabClose:
            let tab: BrowserTab
            if let index = a.index {
                guard store.tabs.indices.contains(index) else { throw HostRPCError("pageNotFound", detail: "No browser tab at index \(index)") }
                tab = store.tabs[index]
            } else { tab = try resolve(request.target) }
            await close(tab)
            return action(detail: tab.id)
        default: break
        }

        let tab = try resolve(request.target)
        let state = state(tab)
        host(tab)
        let webView = tab.webView
        switch command {
        case .profileShow:
            let profile = profiles.profile(id: state.profileID) ?? profiles.defaultProfile
            return .profile(BrowserProfileResult(profile: info(profile), pageId: tab.id))
        case .profileSet, .profileUseDefault, .profileClone:
            let id = a.profileId ?? BrowserProfileStore.builtInID
            let profile = try profileCall { try profiles.attach(id: id) }
            _ = try? profiles.detach(id: id)
            let replacement = try makeTab(profileID: profile.id, activate: store.activeID == tab.id)
            var copied: Int?
            if command == .profileClone {
                let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                for cookie in cookies { await replacement.webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) }
                copied = cookies.count
            }
            if let url = tab.url, url != BrowserURLInput.blankURL { try await load(replacement, url) }
            // shortcut: a WKWebView cannot change data store, so set/use-default replace the tab (new page id); clone keeps both.
            if command != .profileClone { await close(tab) }
            return .profile(BrowserProfileResult(profile: info(profile), pageId: replacement.id, cookiesCopied: copied))

        // Navigation.
        case .goto:
            try await load(tab, a.url ?? "")
            return .navigation(navigation(tab))
        case .back, .forward, .reload:
            if command == .back { tab.goBack() } else if command == .forward { tab.goForward() } else { tab.reload() }
            await waitForLoad(webView)
            return .navigation(navigation(tab))

        // Page reads.
        case .snapshot:
            let value = try await js(tab, "return S.snapshot();")
            guard case .object(let o) = value else { throw HostRPCError("javascriptError", detail: "snapshot returned no object") }
            let refs: [BrowserElementRef] = o["refs"]?.array?.compactMap {
                guard let ref = $0["ref"]?.string, let role = $0["role"]?.string else { return nil }
                return BrowserElementRef(ref: ref, role: role, name: $0["name"]?.string ?? "")
            } ?? []
            return .snapshot(BrowserSnapshotResult(pageId: tab.id, url: webView.url?.absoluteString ?? "", title: webView.title,
                                                   snapshot: o["snapshot"]?.string ?? "", refs: refs,
                                                   skippedFrames: o["skippedFrames"]?.int ?? 0))
        case .screenshot: return .image(try await screenshot(tab, full: false, format: a.format ?? .png))
        case .fullScreenshot: return .image(try await screenshot(tab, full: true, format: a.format ?? .png))
        case .pdf:
            let data = try await webView.pdf(configuration: WKPDFConfiguration())
            return .pdf(BrowserPDFResult(dataBase64: data.base64EncodedString(), byteCount: data.count))
        case .eval:
            return .value(BrowserValueResult(value: try await js(tab, """
                const v = await (0, eval)(expression);
                try { return v === undefined ? null : JSON.parse(JSON.stringify(v)); } catch (_) { return String(v); }
                """, ["expression": a.expression ?? ""], world: .page)))
        case .wait: return .value(BrowserValueResult(value: try await wait(tab, a)))
        case .get:
            return .value(BrowserValueResult(value: try await js(tab, """
                if (what === 'url') return location.href;
                if (what === 'title') return document.title;
                if (what === 'count') return document.querySelectorAll(element || '*').length;
                if (!element) throw new Error('missingArgument: get ' + what + ' requires element');
                const el = S.resolve(element);
                switch (what) {
                  case 'text': return el.innerText;
                  case 'html': return el.outerHTML;
                  case 'value': return el.value ?? null;
                  case 'box': { const r = el.getBoundingClientRect(); return { x: r.x, y: r.y, width: r.width, height: r.height }; }
                  default: throw new Error('invalidArgument: get takes text, html, value, url, title, count or box');
                }
                """, ["what": a.what ?? "", "element": a.element ?? NSNull()])))
        case .is:
            return .value(BrowserValueResult(value: try await js(tab, """
                const el = S.resolve(element);
                switch (what) {
                  case 'visible': return S.visible(el);
                  case 'enabled': return !el.disabled;
                  case 'checked': return !!el.checked;
                  default: throw new Error('invalidArgument: is takes visible, enabled or checked');
                }
                """, ["what": a.what ?? "", "element": a.element ?? ""])))
        case .find:
            let actions = ["click", "dblclick", "fill", "hover", "focus", "check", "uncheck", "text"]
            guard let verb = a.action, actions.contains(verb) else {
                throw HostRPCError("invalidArgument", detail: "find --action takes \(actions.joined(separator: ", "))")
            }
            return .value(BrowserValueResult(value: try await js(tab, """
                const el = S.find(locator, value);
                switch (verb) {
                  case 'click': S.click(el); break;
                  case 'dblclick': S.click(el, 2); break;
                  case 'fill': S.setValue(el, text ?? ''); break;
                  case 'hover': S.hover(el); break;
                  case 'focus': el.focus(); break;
                  case 'check': case 'uncheck': if (!!el.checked !== (verb === 'check')) S.click(el); break;
                  case 'text': return el.innerText;
                }
                return { found: true, role: S.role(el), name: S.name(el) };
                """, ["locator": a.locator ?? "", "value": a.value ?? "", "verb": verb, "text": a.text ?? NSNull()])))

        // Pointer input (R-B1: trusted only while smthz is active and the tab is shown).
        case .click, .dblclick:
            let trusted = try await pointerClick(tab, a.element ?? "", count: command == .dblclick ? 2 : 1)
            return action(a.element, trusted: trusted)
        case .check, .uncheck:
            let want = command == .check
            let current = try await js(tab, "return !!S.resolve(element).checked;", ["element": a.element ?? ""])
            var trusted: Bool?
            if current != .bool(want) { trusted = try await pointerClick(tab, a.element ?? "", count: 1) }
            return action(a.element, trusted: trusted, detail: want ? "checked" : "unchecked")
        case .hover:
            let point = try await center(tab, a.element ?? "")
            if nativePointer(tab) { send(.mouseMoved, webView, point); return action(a.element, trusted: true) }
            _ = try await js(tab, "S.hover(S.resolve(element));", ["element": a.element ?? ""])
            return action(a.element, trusted: false)
        case .drag:
            let from = try await center(tab, a.from ?? ""), to = try await center(tab, a.to ?? "")
            if nativePointer(tab) {
                send(.leftMouseDown, webView, from)
                for step in 1...5 {
                    let t = CGFloat(step) / 5
                    send(.leftMouseDragged, webView, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
                }
                send(.leftMouseUp, webView, to)
                return action(a.from, trusted: true)
            }
            _ = try await js(tab, """
                const a = S.resolve(from), b = S.resolve(to), p = S.center(a), q = S.center(b), dt = new DataTransfer();
                S.mouse(a, 'pointerdown', p.x, p.y); S.mouse(a, 'mousedown', p.x, p.y);
                const drag = (el, type, x, y) => el.dispatchEvent(new DragEvent(type, { bubbles: true, cancelable: true, composed: true, clientX: x, clientY: y, dataTransfer: dt }));
                drag(a, 'dragstart', p.x, p.y); drag(b, 'dragenter', q.x, q.y); drag(b, 'dragover', q.x, q.y); drag(b, 'drop', q.x, q.y); drag(a, 'dragend', q.x, q.y);
                S.mouse(b, 'mousemove', q.x, q.y); S.mouse(b, 'pointerup', q.x, q.y); S.mouse(b, 'mouseup', q.x, q.y);
                """, ["from": a.from ?? "", "to": a.to ?? ""])
            return action(a.from, trusted: false)
        case .mouseMove, .mouseDown, .mouseUp:
            if command == .mouseMove { state.mouse = CGPoint(x: a.x ?? 0, y: a.y ?? 0) }
            let button = a.button ?? .left
            if nativePointer(tab) {
                let type: NSEvent.EventType = switch (command, button) {
                case (.mouseMove, _): .mouseMoved
                case (.mouseDown, .left): .leftMouseDown
                case (.mouseUp, .left): .leftMouseUp
                case (.mouseDown, _): button == .right ? .rightMouseDown : .otherMouseDown
                default: button == .right ? .rightMouseUp : .otherMouseUp
                }
                send(type, webView, state.mouse)
                return action(trusted: true)
            }
            let type = command == .mouseMove ? "mousemove" : command == .mouseDown ? "mousedown" : "mouseup"
            _ = try await js(tab, """
                const el = document.elementFromPoint(x, y) || document.body;
                S.mouse(el, type.replace('mouse', 'pointer'), x, y, { button });
                S.mouse(el, type, x, y, { button });
                if (type === 'mouseup' && button === 0) el.click();
                """, ["x": state.mouse.x, "y": state.mouse.y, "type": type,
                      "button": button == .left ? 0 : button == .middle ? 1 : 2])
            return action(trusted: false)

        // Keyboard and wheel stay trusted in the background (A.3).
        case .type:
            try await withFocus(webView) { for character in a.input ?? "" { self.key(webView, String(character)) } }
            return action(trusted: true)
        case .keypress:
            guard let parsed = Self.parseKey(a.key ?? "") else {
                throw HostRPCError("invalidArgument", detail: "Unknown key \(a.key ?? ""); use names like Enter, Tab, Escape, ArrowDown or a character, with optional Shift+/Control+/Alt+/Meta+")
            }
            try await withFocus(webView) { self.key(webView, parsed.characters, code: parsed.code, flags: parsed.flags) }
            return action(trusted: true, detail: a.key)
        case .insertText:
            try await withFocus(webView) { webView.insertText(a.text ?? "") }
            return action(trusted: true)
        case .scroll:
            let amount = Double(a.amount ?? 300)
            return action(trusted: try await wheel(tab, dx: 0, dy: a.direction == .up ? -amount : amount))
        case .mouseWheel:
            return action(trusted: try await wheel(tab, dx: a.dx ?? 0, dy: a.dy ?? 0))
        case .scrollIntoView:
            _ = try await js(tab, "S.resolve(element).scrollIntoView({ block: 'center' });", ["element": a.element ?? ""])
            return action(a.element)

        // Form helpers (JS in the isolated world).
        case .fill, .clear:
            _ = try await js(tab, "S.setValue(S.resolve(element), value);", ["element": a.element ?? "", "value": a.value ?? ""])
            return action(a.element)
        case .focus:
            _ = try await js(tab, "S.resolve(element).focus();", ["element": a.element ?? ""])
            return action(a.element)
        case .selectAll:
            _ = try await js(tab, """
                const el = S.resolve(element); el.focus();
                if (el.select) el.select(); else getSelection().selectAllChildren(el);
                """, ["element": a.element ?? ""])
            return action(a.element)
        case .select:
            let chosen = try await js(tab, """
                const el = S.resolve(element);
                const option = [...(el.options || [])].find((o) => o.value === value || o.label === value || o.text === value);
                if (!option) throw new Error('invalidArgument: no option ' + value);
                S.setValue(el, option.value);
                return option.value;
                """, ["element": a.element ?? "", "value": a.value ?? ""])
            return action(a.element, detail: chosen.string)
        case .upload:
            var files: [[String: String]] = []
            for path in a.files ?? [] {
                let url = URL(fileURLWithPath: path, relativeTo: request.target.cwd.map { URL(fileURLWithPath: $0, isDirectory: true) })
                guard let data = try? Data(contentsOf: url) else { throw HostRPCError("invalidArgument", detail: "Cannot read \(path)") }
                // shortcut: files travel base64 through JS, fine for test fixtures; switch to runOpenPanelWith for very large files.
                files.append(["name": url.lastPathComponent, "data": data.base64EncodedString()])
            }
            _ = try await js(tab, """
                const el = S.resolve(element);
                if (el.type !== 'file') throw new Error('invalidArgument: ' + element + ' is not a file input');
                const dt = new DataTransfer();
                for (const f of files) dt.items.add(new File([Uint8Array.from(atob(f.data), (c) => c.charCodeAt(0))], f.name));
                el.files = dt.files;
                el.dispatchEvent(new Event('input', { bubbles: true })); el.dispatchEvent(new Event('change', { bubbles: true }));
                """, ["element": a.element ?? "", "files": files])
            return action(a.element, detail: "\(files.count) file(s)")
        case .highlight:
            _ = try await js(tab, """
                const el = S.resolve(selector), old = el.style.outline;
                el.scrollIntoView({ block: 'center' }); el.style.outline = '2px solid #f59e0b';
                setTimeout(() => { el.style.outline = old; }, 2000);
                """, ["selector": a.selector ?? ""])
            return action(a.selector)
        case .download:
            return action(a.selector, detail: try await download(tab, selector: a.selector ?? "", path: a.path ?? "", cwd: request.target.cwd))

        // Storage, cookies, clipboard, dialogs.
        case .localGet, .sessionGet:
            return .value(BrowserValueResult(value: try await js(tab, "return (local ? localStorage : sessionStorage).getItem(key);",
                                                                 ["local": command == .localGet, "key": a.key ?? ""])))
        case .localSet, .sessionSet:
            _ = try await js(tab, "(local ? localStorage : sessionStorage).setItem(key, value);",
                             ["local": command == .localSet, "key": a.key ?? "", "value": a.value ?? ""])
            return action(detail: a.key)
        case .localClear, .sessionClear:
            _ = try await js(tab, "(local ? localStorage : sessionStorage).clear();", ["local": command == .localClear])
            return action()
        case .cookieGet:
            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            let host = URL(string: a.url ?? tab.url ?? "")?.host
            return .cookies(BrowserCookieListResult(cookies: cookies.filter { host == nil || Self.domain($0.domain, matches: host!) }.map(Self.cookie)))
        case .cookieSet:
            let host = a.domain ?? URL(string: tab.url ?? "")?.host ?? ""
            var properties: [HTTPCookiePropertyKey: Any] = [.name: a.name ?? "", .value: a.value ?? "", .domain: host, .path: a.path ?? "/"]
            if a.secure == true { properties[.secure] = "TRUE" }
            if a.httpOnly == true { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            if let sameSite = a.sameSite { properties[.sameSitePolicy] = sameSite.capitalized }
            if let expires = a.expires { properties[.expires] = Date(timeIntervalSince1970: expires) }
            guard let cookie = HTTPCookie(properties: properties) else { throw HostRPCError("invalidArgument", detail: "Invalid cookie (domain \(host))") }
            await webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
            return action(detail: a.name)
        case .cookieDelete:
            let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
            let host = a.domain ?? URL(string: a.url ?? tab.url ?? "")?.host
            var removed = 0
            for cookie in await cookieStore.allCookies() where cookie.name == a.name && (host == nil || Self.domain(cookie.domain, matches: host!)) {
                await cookieStore.deleteCookie(cookie)
                removed += 1
            }
            return action(detail: "\(removed) removed")
        case .clipboardRead:
            return .value(BrowserValueResult(value: NSPasteboard.general.string(forType: .string).map(HostJSON.string) ?? .null))
        case .clipboardWrite:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(a.text ?? "", forType: .string)
            return action()
        case .dialogAccept, .dialogDismiss:
            let accept = command == .dialogAccept
            switch tab.dialog {
            case .alert(_, _, let resume)?: resume(())
            case .confirm(_, _, let resume)?: resume(accept)
            case .prompt(_, _, let defaultText, let resume)?: resume(accept ? (a.text ?? defaultText) : nil)
            case .auth(_, _, let resume)?: resume(nil)
            case nil: throw HostRPCError("noDialog", detail: "The page has no open dialog")
            }
            return action()

        // Capture buffers.
        case .console:
            let entries = state.console.suffix(a.limit ?? Self.consoleLimit)
            return .console(BrowserConsoleResult(entries: Array(entries), dropped: state.consoleDropped))
        case .network:
            let entries = state.network.suffix(a.limit ?? Self.networkLimit)
            return .network(BrowserNetworkResult(entries: Array(entries), dropped: state.networkDropped))
        case .captureStart, .captureStop:
            // Buffers always record (bounded); start resets them like a fresh capture.
            if command == .captureStart {
                state.console.removeAll(); state.network.removeAll(); state.consoleDropped = 0; state.networkDropped = 0
            }
            state.capturing = command == .captureStart
            return .capture(BrowserCaptureResult(capturing: state.capturing))

        // Partial emulation (R-B4..R-B7).
        case .interceptEnable, .interceptDisable:
            state.config.intercept = command == .interceptEnable
            state.config.patterns = command == .interceptEnable ? a.patterns ?? [] : []
            if command == .interceptDisable { state.intercepted.removeAll() }
            try await apply(tab)
            return .intercept(BrowserInterceptResult(enabled: state.config.intercept, patterns: state.config.patterns))
        case .interceptList:
            return .intercept(BrowserInterceptResult(enabled: state.config.intercept, patterns: state.config.patterns, requests: state.intercepted))
        case .setHeaders:
            state.config.headers = a.headers ?? [:]
            try await apply(tab)
            return action(detail: "\(state.config.headers.count) header(s); top-level loads and page fetch/XHR only (R-B5)")
        case .setCredentials:
            state.credential = URLCredential(user: a.user ?? "", password: a.pass ?? "", persistence: .forSession)
            return action()
        case .setOffline:
            state.config.offline = a.offline ?? true
            try await apply(tab)
            return action(detail: state.config.offline ? "offline" : "online")
        case .setMedia:
            if let scheme = a.colorScheme { webView.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua) }
            if let motion = a.reducedMotion { state.config.reducedMotion = motion.rawValue }
            try await apply(tab)
            return action()
        case .geolocation:
            state.config.geo = .init(latitude: a.latitude ?? 0, longitude: a.longitude ?? 0, accuracy: a.accuracy)
            try await apply(tab)
            return action()
        case .viewport:
            state.viewport = CGSize(width: a.width ?? 1280, height: a.height ?? 800)
            applyViewport(tab)
            var ignored: [String] = []
            if a.deviceScaleFactor != nil { ignored.append("deviceScaleFactor") }
            if a.mobile == true { ignored.append("touch") }
            return .viewport(BrowserViewportResult(width: state.viewport!.width, height: state.viewport!.height, mobile: a.mobile == true, ignored: ignored))
        case .setDevice:
            guard let device = Self.devices.first(where: { $0.name.caseInsensitiveCompare(a.name ?? "") == .orderedSame }) else {
                throw HostRPCError("invalidArgument", detail: "Unknown device; known: \(Self.devices.map(\.name).joined(separator: ", "))")
            }
            state.viewport = device.size
            applyViewport(tab)
            webView.customUserAgent = device.userAgent
            if device.userAgent == nil { applyIdentity(tab) }
            return .viewport(BrowserViewportResult(width: device.size.width, height: device.size.height, mobile: device.mobile,
                                                   ignored: device.mobile ? ["deviceScaleFactor", "touch"] : []))
        default:
            throw HostRPCError("unsupported", detail: "\(command.rawValue) is not implemented by the app")
        }
    }

    // MARK: Tabs and profiles

    private func resolve(_ target: BrowserTarget) throws -> BrowserTab {
        // shortcut: browser tabs are app-global (BrowserTabStore), so --worktree selectors are not scoped yet; scope them when tabs move into ShellModel.
        if let page = target.page {
            guard let tab = store.tabs.first(where: { $0.id == page }) else { throw HostRPCError("pageNotFound", detail: "No browser tab \(page)") }
            return tab
        }
        if let id = currentID, let tab = store.tabs.first(where: { $0.id == id }) { return tab }
        if let tab = store.activeTab ?? store.tabs.last { return tab }
        throw HostRPCError("noBrowserTab", detail: "No browser tab is open; run smthz browser tab create")
    }

    private func makeTab(profileID: String, activate: Bool) throws -> BrowserTab {
        let profile = try profileCall { try profiles.attach(id: profileID) }
        let configuration = WKWebViewConfiguration()
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.websiteDataStore = profile.scope == .default ? .default() : WKWebsiteDataStore(forIdentifier: profile.dataStoreIdentifier)
        let tab = store.newTab(configuration: configuration, activate: activate)
        state(tab).profileID = profile.id
        applyIdentity(tab)
        currentID = tab.id
        return tab
    }

    private func close(_ tab: BrowserTab) async {
        let profileID = pages[tab.id]?.profileID ?? BrowserProfileStore.builtInID
        store.close(tab.id)
        pages[tab.id] = nil
        if currentID == tab.id { currentID = nil }
        // shortcut: tabs closed from the UI do not detach, so a deferred profile delete waits for an automation close or a restart.
        if let identifier = try? profiles.detach(id: profileID) { await removeDataStore(identifier) }
    }

    private func removeDataStore(_ identifier: UUID) async {
        do {
            try await WKWebsiteDataStore.remove(forIdentifier: identifier)
            try profiles.markDataStoreRemoved(identifier)
        } catch { /* Still in use; stays in pendingDataStoreRemovals for a later attempt. */ }
    }

    private func profileCall<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch let error as BrowserProfileStoreError {
            switch error {
            case .notFound(let id), .pendingDeletion(let id): throw HostRPCError("profileNotFound", detail: "No browser profile \(id)")
            case .invalidLabel: throw HostRPCError("invalidArgument", detail: "Invalid profile label")
            case .invalidScope: throw HostRPCError("invalidArgument", detail: "Invalid profile scope")
            case .builtInProfile: throw HostRPCError("invalidArgument", detail: "The default profile cannot be deleted")
            case .saveFailed(let detail): throw HostRPCError("profileSaveFailed", detail: detail)
            }
        }
    }

    private func info(_ profile: BrowserProfile, defaultID: String? = nil) -> BrowserProfileInfo {
        BrowserProfileInfo(id: profile.id, label: profile.label, scope: profile.scope == .imported ? .imported : .isolated,
                           isDefault: profile.id == (defaultID ?? profiles.defaultProfile.id))
    }

    private func tabInfo(_ tab: BrowserTab, index: Int) -> BrowserTabInfo {
        let profileID = pages[tab.id]?.profileID ?? BrowserProfileStore.builtInID
        return BrowserTabInfo(pageId: tab.id, index: index, url: tab.webView.url?.absoluteString ?? "", title: tab.webView.title,
                              active: tab.id == (currentID ?? store.activeID), profileId: profileID,
                              profileLabel: profiles.profile(id: profileID)?.label)
    }

    private func navigation(_ tab: BrowserTab) -> BrowserNavigationResult {
        BrowserNavigationResult(pageId: tab.id, url: tab.webView.url?.absoluteString ?? "", title: tab.webView.title)
    }

    private func identity() -> BrowserIdentityResult {
        let configured = UserDefaults.standard.string(forKey: "browserIdentityMode").flatMap(BrowserIdentityMode.init(rawValue:))
        return BrowserIdentityResult(configuredMode: configured, appliedMode: configured ?? .native)
    }

    private func applyIdentity(_ tab: BrowserTab) {
        // "clean" presents as plain Safari; "native" keeps WebKit's embedded-view user agent.
        tab.webView.customUserAgent = identity().appliedMode == .clean
            ? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15" : nil
    }

    // MARK: Loading and waits

    private func load(_ tab: BrowserTab, _ input: String) async throws {
        host(tab)
        let headers = state(tab).config.headers
        if headers.isEmpty {
            guard tab.navigate(input) else { throw HostRPCError("invalidArgument", detail: tab.loadError ?? "Cannot open \(input)") }
        } else {
            guard let target = BrowserURLInput.normalize(input, search: store.searchEngine), let url = URL(string: target), !url.isFileURL
            else { throw HostRPCError("invalidArgument", detail: "Cannot open \(input) with extra headers") }
            var request = URLRequest(url: url)
            headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
            tab.webView.load(request)
        }
        await waitForLoad(tab.webView)
        if let error = tab.loadError { throw HostRPCError("navigationFailed", detail: error) }
    }

    private func waitForLoad(_ webView: WKWebView, timeout: TimeInterval = 15) async {
        let deadline = Date().addingTimeInterval(timeout)
        try? await Task.sleep(for: .milliseconds(50))
        while webView.isLoading, Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
    }

    private func wait(_ tab: BrowserTab, _ a: BrowserArguments) async throws -> HostJSON {
        let timeout = Double(a.timeout ?? 10_000) / 1000
        let conditions = [a.selector, a.text, a.url, a.load, a.fn].contains { $0 != nil }
        guard conditions else {
            try? await Task.sleep(for: .seconds(timeout))
            return .object(["waited": .number(Double(a.timeout ?? 10_000))])
        }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let done = try await js(tab, """
                if (selector) {
                  const el = document.querySelector(selector);
                  const shown = !!el && S.visible(el);
                  if (state === 'hidden' ? shown : !shown) return false;
                }
                if (text && !(document.body?.innerText || '').includes(text)) return false;
                if (url && !new RegExp('^' + url.split('*').map((s) => s.replace(/[.+?^${}()|[\\]\\\\]/g, '\\\\$&')).join('.*') + '$').test(location.href)) return false;
                if (load && (load === 'load' || load === 'networkidle') && document.readyState !== 'complete') return false;
                if (load === 'domcontentloaded' && document.readyState === 'loading') return false;
                if (fn && !(await (0, eval)(fn))) return false;
                return true;
                """, ["selector": a.selector ?? NSNull(), "state": a.waitState?.rawValue ?? "visible", "text": a.text ?? NSNull(),
                      "url": a.url ?? NSNull(), "load": a.load ?? NSNull(), "fn": a.fn ?? NSNull()])
            if done == .bool(true), !(a.load != nil && tab.webView.isLoading) { return .bool(true) }
            if Date() >= deadline { throw HostRPCError("timeout", detail: "wait timed out after \(a.timeout ?? 10_000) ms") }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: JavaScript

    /// Runs `body` (an async function body) with `args` bound as parameters; the return value is JSON.
    private func js(_ tab: BrowserTab, _ body: String, _ args: [String: Any] = [:], world: WKContentWorld? = nil) async throws -> HostJSON {
        let source = BrowserRuntimeScript.isolated + "\nconst __r = await (async () => {\n" + body
            + "\n})();\nreturn JSON.stringify(__r === undefined ? null : __r);"
        do {
            let value = try await tab.webView.callAsyncJavaScript(source, arguments: args, in: nil, contentWorld: world ?? Self.world)
            guard let text = value as? String else { return .null }
            return try JSONDecoder().decode(HostJSON.self, from: Data(text.utf8))
        } catch let error as NSError where error.domain == WKError.errorDomain {
            let message = error.userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
            let text = message.hasPrefix("Error: ") ? String(message.dropFirst(7)) : message
            for code in ["elementNotFound", "invalidArgument", "missingArgument"] where text.hasPrefix(code + ": ") {
                throw HostRPCError(code, detail: String(text.dropFirst(code.count + 2)))
            }
            throw HostRPCError("javascriptError", detail: text)
        }
    }

    /// Rewrites the tab's documentStart script and content rules, then updates the live page.
    private func apply(_ tab: BrowserTab) async throws {
        let config = state(tab).config
        let controller = tab.webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(Self.pageScript(config))
        var rules: [[String: Any]] = []
        if config.offline {
            rules.append(["trigger": ["url-filter": ".*"], "action": ["type": "block"]])
        } else if config.intercept {
            // Subresources can only be blocked (R-B4); page fetch/XHR are paused by the page shim instead.
            let types = ["image", "style-sheet", "script", "font", "media", "svg-document"]
            for pattern in config.patterns.isEmpty ? ["*"] : config.patterns {
                let regex = pattern.split(separator: "*", omittingEmptySubsequences: false)
                    .map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: ".*")
                rules.append(["trigger": ["url-filter": regex, "resource-type": types], "action": ["type": "block"]])
            }
        }
        controller.removeAllContentRuleLists()
        if !rules.isEmpty {
            let json = String(decoding: try JSONSerialization.data(withJSONObject: rules), as: UTF8.self)
            guard let list = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "smthz-automation", encodedContentRuleList: json)
            else { throw HostRPCError("invalidArgument", detail: "Content rules did not compile") }
            controller.add(list)
        }
        let encoded = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
        _ = try? await tab.webView.callAsyncJavaScript("window.__smthzConfigure && window.__smthzConfigure(\(encoded));", in: nil, contentWorld: .page)
    }

    // MARK: Window hosting, viewport and screenshots

    /// Gives a tab that is not shown in a pane a window, so rendering, snapshots and key events work.
    private func host(_ tab: BrowserTab) {
        if tab.webView.window == nil {
            tab.webView.translatesAutoresizingMaskIntoConstraints = true
            tab.webView.frame = CGRect(origin: .zero, size: state(tab).viewport ?? CGSize(width: 1280, height: 800))
            offscreen.contentView?.addSubview(tab.webView)
        }
        applyViewport(tab)
    }

    private func applyViewport(_ tab: BrowserTab) {
        let state = state(tab), webView = tab.webView
        guard let size = state.viewport, let parent = webView.superview else { return }
        if parent === offscreen.contentView { webView.setFrameSize(size); return }
        if state.viewportConstraints.first?.isActive == true, state.viewportConstraints.last?.constant == size.height,
           state.viewportConstraints[2].constant == size.width { return }
        // shortcut: a visible pane re-pins the web view when the tab is re-attached, so the emulated size is re-applied on the next command.
        NSLayoutConstraint.deactivate(parent.constraints.filter { $0.firstItem === webView || $0.secondItem === webView })
        state.viewportConstraints = [webView.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
                                     webView.topAnchor.constraint(equalTo: parent.topAnchor),
                                     webView.widthAnchor.constraint(equalToConstant: size.width),
                                     webView.heightAnchor.constraint(equalToConstant: size.height)]
        NSLayoutConstraint.activate(state.viewportConstraints)
        parent.layoutSubtreeIfNeeded()
    }

    private func screenshot(_ tab: BrowserTab, full: Bool, format: BrowserImageFormat) async throws -> BrowserImageResult {
        let webView = tab.webView
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        let image: NSImage
        if full {
            // snapshotRect outside the viewport is blank (A.3), so lay the page out at its full height.
            let height = try await js(tab, "return Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0);")
            // shortcut: capped at 16384 pt (the tested size); tile the capture if longer pages matter.
            let size = CGSize(width: webView.bounds.width, height: min(max(Double(height.int ?? 0), webView.bounds.height), 16_384))
            let parent = webView.superview
            let saved = parent?.constraints.filter { $0.firstItem === webView || $0.secondItem === webView } ?? []
            let wasAutoresizing = webView.translatesAutoresizingMaskIntoConstraints, oldFrame = webView.frame
            webView.removeFromSuperview()
            webView.translatesAutoresizingMaskIntoConstraints = true
            webView.frame = CGRect(origin: .zero, size: size)
            offscreen.contentView?.addSubview(webView)
            defer {
                webView.removeFromSuperview()
                webView.translatesAutoresizingMaskIntoConstraints = wasAutoresizing
                webView.frame = oldFrame
                parent?.addSubview(webView)
                NSLayoutConstraint.activate(saved)
            }
            try? await Task.sleep(for: .milliseconds(150))
            configuration.rect = CGRect(origin: .zero, size: size)
            image = try await webView.takeSnapshot(configuration: configuration)
        } else {
            image = try await webView.takeSnapshot(configuration: configuration)
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: format == .png ? .png : .jpeg, properties: format == .jpeg ? [.compressionFactor: 0.85] : [:])
        else { throw HostRPCError("screenshotFailed", detail: "Could not encode the snapshot") }
        return BrowserImageResult(format: format, width: rep.pixelsWide, height: rep.pixelsHigh, dataBase64: data.base64EncodedString())
    }

    // MARK: Input

    /// Native pointer events are only delivered while smthz is active and the tab's window is key (A.3, R-B1).
    private func nativePointer(_ tab: BrowserTab) -> Bool {
        guard NSApp.isActive, let window = tab.webView.window else { return false }
        return window.isKeyWindow && window !== offscreen && store.activeID == tab.id
    }

    private func center(_ tab: BrowserTab, _ element: String) async throws -> CGPoint {
        let point = try await js(tab, "return S.center(S.resolve(element));", ["element": element])
        return CGPoint(x: point["x"]?.number ?? 0, y: point["y"]?.number ?? 0)
    }

    private func pointerClick(_ tab: BrowserTab, _ element: String, count: Int) async throws -> Bool {
        if nativePointer(tab) {
            let point = try await center(tab, element)
            for click in 1...count {
                send(.leftMouseDown, tab.webView, point, clickCount: click)
                send(.leftMouseUp, tab.webView, point, clickCount: click)
            }
            return true
        }
        _ = try await js(tab, "S.click(S.resolve(element), count);", ["element": element, "count": count])
        return false
    }

    /// `point` is in CSS pixels relative to the viewport.
    private func send(_ type: NSEvent.EventType, _ webView: WKWebView, _ point: CGPoint, clickCount: Int = 1) {
        guard let window = webView.window else { return }
        let scale = webView.pageZoom * webView.magnification
        let local = NSPoint(x: point.x * scale, y: webView.isFlipped ? point.y * scale : webView.bounds.height - point.y * scale)
        guard let event = NSEvent.mouseEvent(with: type, location: webView.convert(local, to: nil), modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: clickCount, pressure: type == .leftMouseUp ? 0 : 1)
        else { return }
        if type == .mouseMoved { webView.mouseMoved(with: event) } else { window.sendEvent(event) }
    }

    /// Makes the web view first responder for the call, then gives focus back (the terminal, usually).
    private func withFocus(_ webView: WKWebView, _ body: () -> Void) async throws {
        guard let window = webView.window else { throw HostRPCError("noBrowserTab", detail: "The tab has no window") }
        let previous = window.firstResponder
        window.makeFirstResponder(webView)
        body()
        // A round trip to the web process lets it handle the queued key events before focus moves.
        _ = try? await webView.callAsyncJavaScript("return 0", in: nil, contentWorld: Self.world)
        try? await Task.sleep(for: .milliseconds(30))
        if previous !== webView { window.makeFirstResponder(previous) }
    }

    private func key(_ webView: WKWebView, _ characters: String, code: UInt16? = nil, flags: NSEvent.ModifierFlags = []) {
        let plain = characters.lowercased()
        let keyCode = code ?? Self.keyCodes[plain] ?? 0
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: webView.window?.windowNumber ?? 0,
                                               context: nil, characters: characters, charactersIgnoringModifiers: plain,
                                               isARepeat: false, keyCode: keyCode) else { continue }
            if type == .keyDown { webView.keyDown(with: event) } else { webView.keyUp(with: event) }
        }
    }

    /// Native wheel first (trusted, works in the background); falls back to JS when the page did not move.
    private func wheel(_ tab: BrowserTab, dx: Double, dy: Double) async throws -> Bool {
        let webView = tab.webView
        let position = "return [scrollX, scrollY];"
        let before = try await js(tab, position)
        if let window = webView.window,
           let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(-dy), wheel2: Int32(-dx), wheel3: 0) {
            let screen = window.convertPoint(toScreen: webView.convert(NSPoint(x: webView.bounds.midX, y: webView.bounds.midY), to: nil))
            cg.location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.height ?? 0) - screen.y)
            if let event = NSEvent(cgEvent: cg) { webView.scrollWheel(with: event) }
            try? await Task.sleep(for: .milliseconds(250))
        }
        if try await js(tab, position) != before { return true }
        _ = try await js(tab, "window.scrollBy(dx, dy);", ["dx": dx, "dy": dy])
        return false
    }

    // MARK: Downloads

    private func download(_ tab: BrowserTab, selector: String, path: String, cwd: String?) async throws -> String {
        let downloads = store.downloads
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("smthz-download-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let previous = downloads.directory, known = Set(downloads.items.map(\.id))
        downloads.directory = staging
        defer { downloads.directory = previous }
        _ = try await js(tab, "S.click(S.resolve(selector));", ["selector": selector])
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let item = downloads.items.first(where: { !known.contains($0.id) }) {
                switch item.state {
                case .finished:
                    guard let source = item.destination else { break }
                    var target = URL(fileURLWithPath: path, relativeTo: cwd.map { URL(fileURLWithPath: $0, isDirectory: true) })
                    var isDirectory: ObjCBool = false
                    if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue {
                        target.appendPathComponent(source.lastPathComponent)
                    }
                    try? FileManager.default.removeItem(at: target)
                    try FileManager.default.moveItem(at: source, to: target)
                    item.destination = target
                    return target.path
                case .failed(let reason): throw HostRPCError("downloadFailed", detail: reason)
                case .cancelled: throw HostRPCError("downloadFailed", detail: "cancelled")
                case .running: break
                }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        throw HostRPCError("timeout", detail: "No download finished within 30 s after clicking \(selector)")
    }

    // MARK: Tables

    static func domain(_ cookieDomain: String, matches host: String) -> Bool {
        let domain = cookieDomain.hasPrefix(".") ? String(cookieDomain.dropFirst()) : cookieDomain
        return host == domain || host.hasSuffix("." + domain)
    }

    static func cookie(_ c: HTTPCookie) -> BrowserCookie {
        BrowserCookie(name: c.name, value: c.value, domain: c.domain, path: c.path, secure: c.isSecure, httpOnly: c.isHTTPOnly,
                      sameSite: c.sameSitePolicy?.rawValue, expires: c.expiresDate?.timeIntervalSince1970)
    }

    struct Device { let name: String; let size: CGSize; let mobile: Bool; let userAgent: String? }
    static let devices: [Device] = {
        let iPhone = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        let iPad = "Mozilla/5.0 (iPad; CPU OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        let pixel = "Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36"
        return [Device(name: "iPhone SE", size: CGSize(width: 375, height: 667), mobile: true, userAgent: iPhone),
                Device(name: "iPhone 14", size: CGSize(width: 390, height: 844), mobile: true, userAgent: iPhone),
                Device(name: "iPhone 15", size: CGSize(width: 393, height: 852), mobile: true, userAgent: iPhone),
                Device(name: "iPhone 15 Pro Max", size: CGSize(width: 430, height: 932), mobile: true, userAgent: iPhone),
                Device(name: "Pixel 7", size: CGSize(width: 412, height: 915), mobile: true, userAgent: pixel),
                Device(name: "iPad Mini", size: CGSize(width: 768, height: 1024), mobile: true, userAgent: iPad),
                Device(name: "iPad Pro 11", size: CGSize(width: 834, height: 1194), mobile: true, userAgent: iPad),
                Device(name: "Desktop", size: CGSize(width: 1280, height: 800), mobile: false, userAgent: nil)]
    }()

    static let keyCodes: [String: UInt16] = {
        var map: [String: UInt16] = [:]
        // ANSI virtual key codes in order 0...50 ("·" marks unused codes).
        for (code, key) in "asdfhgzxcv·bqweryt123465=97-80]ou[ip\rlj'k;\\,/nm.\t `".enumerated() where key != "·" {
            map[String(key)] = UInt16(code)
        }
        map["\u{7f}"] = 51; map["\u{1b}"] = 53
        return map
    }()

    struct Key { let characters: String; let code: UInt16?; let flags: NSEvent.ModifierFlags }

    /// "Enter", "ArrowDown", "a", "Shift+Tab", "Control+a" (Playwright-style names, like Orca's keypress).
    static func parseKey(_ text: String) -> Key? {
        var parts = text.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        if text.hasSuffix("++") { parts.removeLast(2); parts.append("+") }
        guard let name = parts.popLast(), !name.isEmpty else { return nil }
        var flags: NSEvent.ModifierFlags = []
        for modifier in parts {
            switch modifier.lowercased() {
            case "shift": flags.insert(.shift)
            case "control", "ctrl": flags.insert(.control)
            case "alt", "option": flags.insert(.option)
            case "meta", "cmd", "command": flags.insert(.command)
            default: return nil
            }
        }
        func function(_ scalar: Int) -> String { String(UnicodeScalar(UInt32(scalar)).map(Character.init) ?? " ") }
        let named: [String: (String, UInt16)] = [
            "enter": ("\r", 36), "return": ("\r", 36), "tab": ("\t", 48), "escape": ("\u{1b}", 53), "esc": ("\u{1b}", 53),
            "backspace": ("\u{7f}", 51), "space": (" ", 49), "delete": (function(NSDeleteFunctionKey), 117),
            "arrowup": (function(NSUpArrowFunctionKey), 126), "arrowdown": (function(NSDownArrowFunctionKey), 125),
            "arrowleft": (function(NSLeftArrowFunctionKey), 123), "arrowright": (function(NSRightArrowFunctionKey), 124),
            "home": (function(NSHomeFunctionKey), 115), "end": (function(NSEndFunctionKey), 119),
            "pageup": (function(NSPageUpFunctionKey), 116), "pagedown": (function(NSPageDownFunctionKey), 121)]
        if let (characters, code) = named[name.lowercased()] { return Key(characters: characters, code: code, flags: flags) }
        guard name.count == 1 else { return nil }
        return Key(characters: name, code: keyCodes[name.lowercased()], flags: flags)
    }
}

private extension HostJSON {
    var array: [HostJSON]? { if case .array(let v) = self { return v }; return nil }
    var int: Int? { number.map { Int($0) } }
    subscript(key: String) -> HostJSON? { object?[key] }
}

import Foundation

// Wire types for `smthz browser <cmd>`: the CLI builds a BrowserRequest, the host forwards it to the
// app's browser provider (docs/BROWSER-AGENTS-EXPERIMENT.md A.6) and the provider answers a BrowserResult.
// Command paths and RPC method names follow Orca 1.4.238 (src/cli/specs/browser-*.ts, cli/handlers/browser-*.ts).

/// How completely smthz can implement a command with public WebKit API (A.4 legend Y/P/N).
public enum BrowserSupport: String, Codable, Sendable { case full, partial, unsupported }

public enum BrowserResultKind: String, Codable, CaseIterable, Sendable {
    case action, navigation, snapshot, image, pdf, value, tabList, tab, profileList, profile
    case cookies, console, network, intercept, capture, viewport, identity, unsupported
}

/// Every Orca browser command (80 `path:` entries). The raw value is the path after `smthz browser`.
public enum BrowserCommand: String, Codable, CaseIterable, Sendable {
    case identityGet = "identity get", identitySet = "identity set"
    case openURL = "open-url", snapshot, screenshot, click, fill, type, select, scroll, goto, back, reload
    case eval, wait, check, uncheck, focus, clear, selectAll = "select-all", keypress, pdf
    case fullScreenshot = "full-screenshot", hover, drag, upload
    case tabList = "tab list", tabShow = "tab show", tabCurrent = "tab current", tabSwitch = "tab switch"
    case tabCreate = "tab create", tabClose = "tab close"
    case profileList = "tab profile list", profileCreate = "tab profile create", profileDelete = "tab profile delete"
    case profileSet = "tab profile set", profileShow = "tab profile show", profileUseDefault = "tab profile use-default"
    case profileClone = "tab profile clone"
    case exec
    case cookieGet = "cookie get", cookieSet = "cookie set", cookieDelete = "cookie delete"
    case viewport, geolocation
    case interceptEnable = "intercept enable", interceptDisable = "intercept disable", interceptList = "intercept list"
    case captureStart = "capture start", captureStop = "capture stop", console, network
    case dblclick, forward, scrollIntoView = "scrollintoview", get, `is`, insertText = "inserttext"
    case mouseMove = "mouse move", mouseDown = "mouse down", mouseUp = "mouse up", mouseWheel = "mouse wheel"
    case find
    case setDevice = "set device", setOffline = "set offline", setHeaders = "set headers"
    case setCredentials = "set credentials", setMedia = "set media"
    case clipboardRead = "clipboard read", clipboardWrite = "clipboard write"
    case dialogAccept = "dialog accept", dialogDismiss = "dialog dismiss"
    case localGet = "storage local get", localSet = "storage local set", localClear = "storage local clear"
    case sessionGet = "storage session get", sessionSet = "storage session set", sessionClear = "storage session clear"
    case download, highlight

    public var path: [String] { rawValue.split(separator: " ").map(String.init) }

    /// Orca accepts `browser identity show` as an alias of `browser identity get`.
    public init?(path: [String]) {
        if path == ["identity", "show"] { self = .identityGet; return }
        guard let command = BrowserCommand(rawValue: path.joined(separator: " ")) else { return nil }
        self = command
    }

    /// Host RPC method; the same names Orca's CLI calls.
    public var method: String {
        switch self {
        case .identityGet: "browser.identity.get"
        case .identitySet: "browser.identity.set"
        case .openURL: "browser.openUrl"
        case .selectAll: "browser.selectAll"
        case .fullScreenshot: "browser.fullScreenshot"
        case .tabList: "browser.tabList"
        case .tabShow: "browser.tabShow"
        case .tabCurrent: "browser.tabCurrent"
        case .tabSwitch: "browser.tabSwitch"
        case .tabCreate: "browser.tabCreate"
        case .tabClose: "browser.tabClose"
        case .profileList: "browser.profileList"
        case .profileCreate: "browser.profileCreate"
        case .profileDelete: "browser.profileDelete"
        case .profileSet, .profileUseDefault: "browser.tabSetProfile"
        case .profileShow: "browser.tabProfileShow"
        case .profileClone: "browser.tabProfileClone"
        case .cookieGet: "browser.cookie.get"
        case .cookieSet: "browser.cookie.set"
        case .cookieDelete: "browser.cookie.delete"
        case .interceptEnable: "browser.intercept.enable"
        case .interceptDisable: "browser.intercept.disable"
        case .interceptList: "browser.intercept.list"
        case .captureStart: "browser.capture.start"
        case .captureStop: "browser.capture.stop"
        case .scrollIntoView: "browser.scrollIntoView"
        case .insertText: "browser.keyboardInsertText"
        case .mouseMove: "browser.mouseMove"
        case .mouseDown: "browser.mouseDown"
        case .mouseUp: "browser.mouseUp"
        case .mouseWheel: "browser.mouseWheel"
        case .setDevice: "browser.setDevice"
        case .setOffline: "browser.setOffline"
        case .setHeaders: "browser.setHeaders"
        case .setCredentials: "browser.setCredentials"
        case .setMedia: "browser.setMedia"
        case .clipboardRead: "browser.clipboardRead"
        case .clipboardWrite: "browser.clipboardWrite"
        case .dialogAccept: "browser.dialogAccept"
        case .dialogDismiss: "browser.dialogDismiss"
        case .localGet: "browser.storage.local.get"
        case .localSet: "browser.storage.local.set"
        case .localClear: "browser.storage.local.clear"
        case .sessionGet: "browser.storage.session.get"
        case .sessionSet: "browser.storage.session.set"
        case .sessionClear: "browser.storage.session.clear"
        default: "browser." + rawValue
        }
    }

    /// A.4 verdicts: 56 full, 23 partial, 1 unsupported.
    public var support: BrowserSupport {
        switch self {
        case .exec: .unsupported
        case .profileClone, .snapshot, .click, .dblclick, .hover, .drag, .check, .uncheck,
             .mouseMove, .mouseDown, .mouseUp, .network, .captureStart, .captureStop,
             .interceptEnable, .interceptDisable, .interceptList, .setHeaders, .setDevice, .viewport,
             .setMedia, .geolocation, .setOffline: .partial
        default: .full
        }
    }

    /// The A.5 reduction a partial or unsupported command is subject to.
    public var reduction: String? {
        switch self {
        case .click, .dblclick, .hover, .drag, .check, .uncheck, .mouseMove, .mouseDown, .mouseUp: "R-B1"
        case .snapshot: "R-B2"
        case .network, .captureStart, .captureStop: "R-B3"
        case .interceptEnable, .interceptDisable, .interceptList: "R-B4"
        case .setHeaders: "R-B5"
        case .setDevice, .viewport: "R-B6"
        case .geolocation, .setOffline, .setMedia: "R-B7"
        case .exec: "R-B9"
        case .profileClone: "R-B10"
        default: nil
        }
    }

    public var resultKind: BrowserResultKind {
        switch self {
        case .identityGet, .identitySet: .identity
        case .openURL, .goto, .back, .forward, .reload, .tabCreate: .navigation
        case .snapshot: .snapshot
        case .screenshot, .fullScreenshot: .image
        case .pdf: .pdf
        case .eval, .wait, .get, .is, .find, .clipboardRead, .localGet, .sessionGet: .value
        case .tabList: .tabList
        case .tabShow, .tabCurrent, .tabSwitch: .tab
        case .profileList: .profileList
        case .profileCreate, .profileDelete, .profileSet, .profileShow, .profileUseDefault, .profileClone: .profile
        case .cookieGet: .cookies
        case .console: .console
        case .network: .network
        case .interceptEnable, .interceptDisable, .interceptList: .intercept
        case .captureStart, .captureStop: .capture
        case .viewport, .setDevice: .viewport
        case .exec: .unsupported
        default: .action
        }
    }

    public enum TargetScope: Sendable { case none, worktree, worktreeOrPage }

    /// Profile registry and identity commands are host-wide; tab list/current/create/open-url take a worktree only.
    public var targetScope: TargetScope {
        switch self {
        case .identityGet, .identitySet, .profileList, .profileCreate, .profileDelete: .none
        case .openURL, .tabList, .tabCurrent, .tabCreate: .worktree
        default: .worktreeOrPage
        }
    }

    public var requiredArguments: Set<BrowserArgument> {
        switch self {
        case .identitySet: [.mode]
        case .openURL, .goto: [.url]
        case .click, .check, .uncheck, .focus, .clear, .selectAll, .hover, .dblclick, .scrollIntoView: [.element]
        case .fill, .select: [.element, .value]
        case .type: [.input]
        case .scroll: [.direction]
        case .eval: [.expression]
        case .keypress: [.key]
        case .drag: [.from, .to]
        case .upload: [.element, .files]
        case .profileCreate: [.label, .scope]
        case .profileDelete, .profileSet, .profileClone, .profileUseDefault: [.profileId]
        case .exec: [.command]
        case .cookieSet: [.name, .value]
        case .cookieDelete: [.name]
        case .viewport: [.width, .height]
        case .geolocation: [.latitude, .longitude]
        case .get: [.what]
        case .is: [.what, .element]
        case .insertText, .clipboardWrite: [.text]
        case .mouseMove: [.x, .y]
        case .mouseWheel: [.dy]
        case .find: [.locator, .value, .action]
        case .setDevice: [.name]
        case .setOffline: [.offline]
        case .setHeaders: [.headers]
        case .setCredentials: [.user, .pass]
        case .localGet, .sessionGet: [.key]
        case .localSet, .sessionSet: [.key, .value]
        case .download: [.selector, .path]
        case .highlight: [.selector]
        default: []
        }
    }

    public var optionalArguments: Set<BrowserArgument> {
        switch self {
        case .identitySet: [.reset]
        case .screenshot, .fullScreenshot: [.format]
        case .scroll: [.amount]
        case .wait: [.selector, .timeout, .text, .url, .load, .fn, .waitState]
        case .tabList: [.showProfile]
        case .tabSwitch: [.index, .focus]
        case .tabCreate: [.url, .profileId]
        case .tabClose: [.index]
        case .cookieGet: [.url]
        case .cookieSet: [.domain, .path, .secure, .httpOnly, .sameSite, .expires]
        case .cookieDelete: [.domain, .url]
        case .viewport: [.deviceScaleFactor, .mobile]
        case .geolocation: [.accuracy]
        case .interceptEnable: [.patterns]
        case .console, .network: [.limit]
        case .get: [.element]
        case .mouseDown, .mouseUp: [.button]
        case .mouseWheel: [.dx]
        case .find: [.text]
        case .setMedia: [.colorScheme, .reducedMotion]
        case .dialogAccept: [.text]
        default: []
        }
    }
}

/// JSON keys of BrowserArguments.
public enum BrowserArgument: String, CaseIterable, Sendable {
    case url, element, value, input, direction, amount, expression, selector, timeout, text, load, fn
    case waitState, key, format, from, to, files, index, focus, profileId, label, scope, name, domain, path
    case secure, httpOnly, sameSite, expires, width, height, deviceScaleFactor, mobile, latitude, longitude
    case accuracy, patterns, limit, what, x, y, button, dx, dy, locator, action, headers, user, pass
    case colorScheme, reducedMotion, offline, mode, reset, command, showProfile
}

public enum BrowserScrollDirection: String, Codable, Sendable { case up, down }
public enum BrowserImageFormat: String, Codable, Sendable { case png, jpeg }
public enum BrowserProfileScope: String, Codable, Sendable { case isolated, imported }
public enum BrowserIdentityMode: String, Codable, Sendable { case clean, native }
public enum BrowserMouseButton: String, Codable, Sendable { case left, right, middle }
public enum BrowserColorScheme: String, Codable, Sendable { case dark, light }
public enum BrowserReducedMotion: String, Codable, Sendable { case reduce, noPreference = "no-preference" }
public enum BrowserWaitState: String, Codable, Sendable { case hidden, visible }

/// Which tab a command acts on: a stable page id, a worktree selector, or (both nil) the worktree that
/// contains `cwd`. The host resolves selectors like `current` against `cwd`, as Orca's CLI does.
public struct BrowserTarget: Codable, Equatable, Sendable {
    public var worktree: String?
    public var page: String?
    public var cwd: String?
    public init(worktree: String? = nil, page: String? = nil, cwd: String? = nil) {
        self.worktree = worktree; self.page = page; self.cwd = cwd
    }
    public var isEmpty: Bool { worktree == nil && page == nil }
}

/// Union of every command's parameters; BrowserRequest.validate() enforces which ones a command takes.
public struct BrowserArguments: Codable, Equatable, Sendable {
    public var url: String?
    public var element: String?
    public var value: String?
    public var input: String?
    public var direction: BrowserScrollDirection?
    public var amount: Int?
    public var expression: String?
    public var selector: String?
    public var timeout: Int?
    public var text: String?
    public var load: String?
    public var fn: String?
    public var waitState: BrowserWaitState?
    public var key: String?
    public var format: BrowserImageFormat?
    public var from: String?
    public var to: String?
    public var files: [String]?
    public var index: Int?
    public var focus: Bool?
    public var profileId: String?
    public var label: String?
    public var scope: BrowserProfileScope?
    public var name: String?
    public var domain: String?
    public var path: String?
    public var secure: Bool?
    public var httpOnly: Bool?
    public var sameSite: String?
    public var expires: Double?
    public var width: Double?
    public var height: Double?
    public var deviceScaleFactor: Double?
    public var mobile: Bool?
    public var latitude: Double?
    public var longitude: Double?
    public var accuracy: Double?
    public var patterns: [String]?
    public var limit: Int?
    public var what: String?
    public var x: Double?
    public var y: Double?
    public var button: BrowserMouseButton?
    public var dx: Double?
    public var dy: Double?
    public var locator: String?
    public var action: String?
    public var headers: [String: String]?
    public var user: String?
    public var pass: String?
    public var colorScheme: BrowserColorScheme?
    public var reducedMotion: BrowserReducedMotion?
    public var offline: Bool?
    public var mode: BrowserIdentityMode?
    public var reset: Bool?
    public var command: String?
    public var showProfile: Bool?

    public init() {}

    /// Arguments that are set; derived from the encoding so it can never drift from the stored properties.
    public var present: Set<BrowserArgument> {
        let encoder = JSONEncoder()
        // Non-finite numbers must still count as present so validate() reports them as invalid.
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        guard let data = try? encoder.encode(self),
              let object = try? JSONDecoder().decode([String: HostJSON].self, from: data) else { return [] }
        return Set(object.keys.compactMap(BrowserArgument.init(rawValue:)))
    }
}

public struct BrowserRequest: Codable, Equatable, Sendable {
    public var command: BrowserCommand
    public var target: BrowserTarget
    public var arguments: BrowserArguments

    public init(command: BrowserCommand, target: BrowserTarget = BrowserTarget(),
                arguments: BrowserArguments = BrowserArguments()) throws {
        self.command = command; self.target = target; self.arguments = arguments
        try validate()
    }

    private enum CodingKeys: String, CodingKey { case command, target, arguments }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode(String.self, forKey: .command)
        guard let command = BrowserCommand(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(forKey: .command, in: c, debugDescription: "unknownCommand: \(raw)")
        }
        self.command = command
        target = try c.decodeIfPresent(BrowserTarget.self, forKey: .target) ?? BrowserTarget()
        arguments = try c.decodeIfPresent(BrowserArguments.self, forKey: .arguments) ?? BrowserArguments()
        do { try validate() } catch let error as HostRPCError {
            throw DecodingError.dataCorrupted(.init(codingPath: [CodingKeys.arguments],
                                                    debugDescription: "\(error.code): \(error.detail ?? "")"))
        }
    }

    public var method: String { command.method }

    /// Errors are HostRPCError with codes missingArgument, unexpectedArgument or invalidArgument.
    public func validate() throws {
        let present = arguments.present
        let allowed = command.requiredArguments.union(command.optionalArguments)
        if let extra = present.subtracting(allowed).map(\.rawValue).sorted().first {
            throw HostRPCError("unexpectedArgument", detail: "\(command.rawValue) does not take \(extra)")
        }
        if let missing = command.requiredArguments.subtracting(present).map(\.rawValue).sorted().first {
            throw HostRPCError("missingArgument", detail: "\(command.rawValue) requires \(missing)")
        }
        switch command.targetScope {
        case .none where !target.isEmpty || target.cwd != nil:
            throw HostRPCError("unexpectedArgument", detail: "\(command.rawValue) does not target a tab")
        case .worktree where target.page != nil:
            throw HostRPCError("unexpectedArgument", detail: "\(command.rawValue) does not take page")
        default: break
        }
        func invalid(_ detail: String) -> HostRPCError { HostRPCError("invalidArgument", detail: detail) }
        if [.tabShow, .profileShow, .profileUseDefault].contains(command), target.page == nil {
            throw HostRPCError("missingArgument", detail: "\(command.rawValue) requires page")
        }
        if command == .tabSwitch, arguments.index == nil, target.page == nil {
            throw HostRPCError("missingArgument", detail: "tab switch requires index or page")
        }
        if command == .profileSet, target.isEmpty {
            throw HostRPCError("missingArgument", detail: "tab profile set requires page or worktree")
        }
        let a = arguments
        for (name, text) in [("element", a.element), ("url", a.url), ("selector", a.selector), ("key", a.key),
                             ("name", a.name), ("profileId", a.profileId), ("label", a.label), ("from", a.from),
                             ("to", a.to), ("expression", a.expression), ("command", a.command), ("user", a.user)] {
            if let text, text.isEmpty { throw invalid("\(name) must not be empty") }
        }
        if let files = a.files, files.isEmpty || files.contains(where: \.isEmpty) { throw invalid("files must list paths") }
        if let patterns = a.patterns, patterns.contains(where: \.isEmpty) { throw invalid("patterns must not be empty") }
        if let headers = a.headers, headers.isEmpty || headers.keys.contains(where: \.isEmpty) {
            throw invalid("headers must be a non-empty object")
        }
        for (name, number) in [("amount", a.amount), ("timeout", a.timeout), ("limit", a.limit)] {
            if let number, number <= 0 { throw invalid("\(name) must be a positive integer") }
        }
        if let index = a.index, index < 0 { throw invalid("index must be a non-negative integer") }
        for (name, number) in [("width", a.width), ("height", a.height), ("deviceScaleFactor", a.deviceScaleFactor),
                               ("accuracy", a.accuracy)] {
            if let number, !(number.isFinite && number > 0) { throw invalid("\(name) must be a positive number") }
        }
        for (name, number) in [("x", a.x), ("y", a.y), ("dx", a.dx), ("dy", a.dy)] {
            if let number, !number.isFinite { throw invalid("\(name) must be a finite number") }
        }
        if let expires = a.expires, !(expires.isFinite && expires >= 0) { throw invalid("expires must be an epoch >= 0") }
        if let latitude = a.latitude, !(latitude.isFinite && abs(latitude) <= 90) { throw invalid("latitude must be in -90...90") }
        if let longitude = a.longitude, !(longitude.isFinite && abs(longitude) <= 180) { throw invalid("longitude must be in -180...180") }
    }
}

// MARK: - Results

public struct BrowserActionResult: Codable, Equatable, Sendable {
    public var command: BrowserCommand
    public var element: String?
    /// false when pointer input fell back to JS events because smthz was not the active app (R-B1).
    public var trusted: Bool?
    public var detail: String?
    public init(command: BrowserCommand, element: String? = nil, trusted: Bool? = nil, detail: String? = nil) {
        self.command = command; self.element = element; self.trusted = trusted; self.detail = detail
    }
}

public struct BrowserNavigationResult: Codable, Equatable, Sendable {
    public var pageId: String
    public var url: String
    public var title: String?
    public init(pageId: String, url: String, title: String? = nil) { self.pageId = pageId; self.url = url; self.title = title }
}

public struct BrowserElementRef: Codable, Equatable, Sendable {
    public var ref: String
    public var role: String
    public var name: String
    public init(ref: String, role: String, name: String) { self.ref = ref; self.role = role; self.name = name }
}

public struct BrowserSnapshotResult: Codable, Equatable, Sendable {
    public var pageId: String
    public var url: String
    public var title: String?
    public var snapshot: String
    public var refs: [BrowserElementRef]
    /// Frames the DOM walk could not enter (closed shadow roots, unreachable cross-origin frames: R-B2).
    public var skippedFrames: Int
    public init(pageId: String, url: String, title: String? = nil, snapshot: String,
                refs: [BrowserElementRef] = [], skippedFrames: Int = 0) {
        self.pageId = pageId; self.url = url; self.title = title; self.snapshot = snapshot
        self.refs = refs; self.skippedFrames = skippedFrames
    }
}

public struct BrowserImageResult: Codable, Equatable, Sendable {
    public var format: BrowserImageFormat
    public var width: Int
    public var height: Int
    public var dataBase64: String
    public init(format: BrowserImageFormat, width: Int, height: Int, dataBase64: String) {
        self.format = format; self.width = width; self.height = height; self.dataBase64 = dataBase64
    }
}

public struct BrowserPDFResult: Codable, Equatable, Sendable {
    public var dataBase64: String
    public var byteCount: Int
    public init(dataBase64: String, byteCount: Int) { self.dataBase64 = dataBase64; self.byteCount = byteCount }
}

public struct BrowserValueResult: Codable, Equatable, Sendable {
    public var value: HostJSON
    public init(value: HostJSON) { self.value = value }
}

public struct BrowserTabInfo: Codable, Equatable, Sendable {
    public var pageId: String
    public var index: Int
    public var url: String
    public var title: String?
    public var active: Bool
    public var worktree: String?
    public var profileId: String?
    public var profileLabel: String?
    public init(pageId: String, index: Int, url: String, title: String? = nil, active: Bool,
                worktree: String? = nil, profileId: String? = nil, profileLabel: String? = nil) {
        self.pageId = pageId; self.index = index; self.url = url; self.title = title; self.active = active
        self.worktree = worktree; self.profileId = profileId; self.profileLabel = profileLabel
    }
}

public struct BrowserTabListResult: Codable, Equatable, Sendable {
    public var tabs: [BrowserTabInfo]
    public init(tabs: [BrowserTabInfo]) { self.tabs = tabs }
}

public struct BrowserProfileInfo: Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var scope: BrowserProfileScope
    public var isDefault: Bool
    public init(id: String, label: String, scope: BrowserProfileScope, isDefault: Bool) {
        self.id = id; self.label = label; self.scope = scope; self.isDefault = isDefault
    }
}

public struct BrowserProfileListResult: Codable, Equatable, Sendable {
    public var profiles: [BrowserProfileInfo]
    public init(profiles: [BrowserProfileInfo]) { self.profiles = profiles }
}

/// create/delete/set/show/use-default/clone. `deferred` marks a delete that waits for open views (A.4).
public struct BrowserProfileResult: Codable, Equatable, Sendable {
    public var profile: BrowserProfileInfo?
    public var pageId: String?
    public var deleted: Bool?
    public var deferred: Bool?
    public var cookiesCopied: Int?
    public init(profile: BrowserProfileInfo? = nil, pageId: String? = nil, deleted: Bool? = nil,
                deferred: Bool? = nil, cookiesCopied: Int? = nil) {
        self.profile = profile; self.pageId = pageId; self.deleted = deleted
        self.deferred = deferred; self.cookiesCopied = cookiesCopied
    }
}

public struct BrowserCookie: Codable, Equatable, Sendable {
    public var name: String
    public var value: String
    public var domain: String
    public var path: String
    public var secure: Bool
    public var httpOnly: Bool
    public var sameSite: String?
    public var expires: Double?
    public init(name: String, value: String, domain: String, path: String = "/", secure: Bool = false,
                httpOnly: Bool = false, sameSite: String? = nil, expires: Double? = nil) {
        self.name = name; self.value = value; self.domain = domain; self.path = path; self.secure = secure
        self.httpOnly = httpOnly; self.sameSite = sameSite; self.expires = expires
    }
}

public struct BrowserCookieListResult: Codable, Equatable, Sendable {
    public var cookies: [BrowserCookie]
    public init(cookies: [BrowserCookie]) { self.cookies = cookies }
}

public struct BrowserConsoleEntry: Codable, Equatable, Sendable {
    public var level: String
    public var text: String
    public var timestamp: Double
    public init(level: String, text: String, timestamp: Double) { self.level = level; self.text = text; self.timestamp = timestamp }
}

public struct BrowserConsoleResult: Codable, Equatable, Sendable {
    public var entries: [BrowserConsoleEntry]
    public var dropped: Int
    public init(entries: [BrowserConsoleEntry], dropped: Int = 0) { self.entries = entries; self.dropped = dropped }
}

/// Where a network entry came from; resourceTiming entries carry no status or headers (R-B3).
public enum BrowserNetworkSource: String, Codable, Sendable { case document, script, resourceTiming, proxy }

public struct BrowserNetworkEntry: Codable, Equatable, Sendable {
    public var url: String
    public var method: String?
    public var status: Int?
    public var mimeType: String?
    public var size: Int?
    public var source: BrowserNetworkSource
    public init(url: String, method: String? = nil, status: Int? = nil, mimeType: String? = nil,
                size: Int? = nil, source: BrowserNetworkSource) {
        self.url = url; self.method = method; self.status = status; self.mimeType = mimeType
        self.size = size; self.source = source
    }
}

public struct BrowserNetworkResult: Codable, Equatable, Sendable {
    public var entries: [BrowserNetworkEntry]
    public var dropped: Int
    public init(entries: [BrowserNetworkEntry], dropped: Int = 0) { self.entries = entries; self.dropped = dropped }
}

public struct BrowserInterceptedRequest: Codable, Equatable, Sendable {
    public var id: String
    public var method: String
    public var url: String
    public var resourceType: String
    public init(id: String, method: String, url: String, resourceType: String) {
        self.id = id; self.method = method; self.url = url; self.resourceType = resourceType
    }
}

public struct BrowserInterceptResult: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var patterns: [String]
    /// Only page fetch/XHR can be paused (R-B4); subresources are blocked or allowed, never listed here.
    public var requests: [BrowserInterceptedRequest]
    public init(enabled: Bool, patterns: [String] = [], requests: [BrowserInterceptedRequest] = []) {
        self.enabled = enabled; self.patterns = patterns; self.requests = requests
    }
}

public struct BrowserCaptureResult: Codable, Equatable, Sendable {
    public var capturing: Bool
    public init(capturing: Bool) { self.capturing = capturing }
}

public struct BrowserViewportResult: Codable, Equatable, Sendable {
    public var width: Double
    public var height: Double
    public var mobile: Bool
    /// Requested settings WebKit cannot apply, e.g. deviceScaleFactor and touch (R-B6).
    public var ignored: [String]
    public init(width: Double, height: Double, mobile: Bool = false, ignored: [String] = []) {
        self.width = width; self.height = height; self.mobile = mobile; self.ignored = ignored
    }
}

public struct BrowserIdentityResult: Codable, Equatable, Sendable {
    public var configuredMode: BrowserIdentityMode?
    public var appliedMode: BrowserIdentityMode
    public var restartRequired: Bool
    public init(configuredMode: BrowserIdentityMode?, appliedMode: BrowserIdentityMode, restartRequired: Bool = false) {
        self.configuredMode = configuredMode; self.appliedMode = appliedMode; self.restartRequired = restartRequired
    }
}

public struct BrowserUnsupportedResult: Codable, Equatable, Sendable {
    public var command: BrowserCommand
    public var reason: String
    public var reduction: String?
    public init(command: BrowserCommand, reason: String, reduction: String? = nil) {
        self.command = command; self.reason = reason; self.reduction = reduction
    }
}

/// Encoded as {"kind": <BrowserResultKind>, "data": <payload>}.
public enum BrowserResult: Codable, Equatable, Sendable {
    case action(BrowserActionResult)
    case navigation(BrowserNavigationResult)
    case snapshot(BrowserSnapshotResult)
    case image(BrowserImageResult)
    case pdf(BrowserPDFResult)
    case value(BrowserValueResult)
    case tabList(BrowserTabListResult)
    case tab(BrowserTabInfo)
    case profileList(BrowserProfileListResult)
    case profile(BrowserProfileResult)
    case cookies(BrowserCookieListResult)
    case console(BrowserConsoleResult)
    case network(BrowserNetworkResult)
    case intercept(BrowserInterceptResult)
    case capture(BrowserCaptureResult)
    case viewport(BrowserViewportResult)
    case identity(BrowserIdentityResult)
    case unsupported(BrowserUnsupportedResult)

    /// `exec` has no WebKit equivalent: there is no CDP endpoint for agent-browser to attach to.
    public static func unsupported(_ command: BrowserCommand) -> BrowserResult {
        .unsupported(BrowserUnsupportedResult(command: command,
            reason: "smthz uses WebKit, which has no CDP endpoint; use the smthz browser commands instead",
            reduction: command.reduction))
    }

    public var kind: BrowserResultKind {
        switch self {
        case .action: .action
        case .navigation: .navigation
        case .snapshot: .snapshot
        case .image: .image
        case .pdf: .pdf
        case .value: .value
        case .tabList: .tabList
        case .tab: .tab
        case .profileList: .profileList
        case .profile: .profile
        case .cookies: .cookies
        case .console: .console
        case .network: .network
        case .intercept: .intercept
        case .capture: .capture
        case .viewport: .viewport
        case .identity: .identity
        case .unsupported: .unsupported
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, data }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode(String.self, forKey: .kind)
        guard let kind = BrowserResultKind(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown result kind \(raw)")
        }
        switch kind {
        case .action: self = .action(try c.decode(BrowserActionResult.self, forKey: .data))
        case .navigation: self = .navigation(try c.decode(BrowserNavigationResult.self, forKey: .data))
        case .snapshot: self = .snapshot(try c.decode(BrowserSnapshotResult.self, forKey: .data))
        case .image: self = .image(try c.decode(BrowserImageResult.self, forKey: .data))
        case .pdf: self = .pdf(try c.decode(BrowserPDFResult.self, forKey: .data))
        case .value: self = .value(try c.decode(BrowserValueResult.self, forKey: .data))
        case .tabList: self = .tabList(try c.decode(BrowserTabListResult.self, forKey: .data))
        case .tab: self = .tab(try c.decode(BrowserTabInfo.self, forKey: .data))
        case .profileList: self = .profileList(try c.decode(BrowserProfileListResult.self, forKey: .data))
        case .profile: self = .profile(try c.decode(BrowserProfileResult.self, forKey: .data))
        case .cookies: self = .cookies(try c.decode(BrowserCookieListResult.self, forKey: .data))
        case .console: self = .console(try c.decode(BrowserConsoleResult.self, forKey: .data))
        case .network: self = .network(try c.decode(BrowserNetworkResult.self, forKey: .data))
        case .intercept: self = .intercept(try c.decode(BrowserInterceptResult.self, forKey: .data))
        case .capture: self = .capture(try c.decode(BrowserCaptureResult.self, forKey: .data))
        case .viewport: self = .viewport(try c.decode(BrowserViewportResult.self, forKey: .data))
        case .identity: self = .identity(try c.decode(BrowserIdentityResult.self, forKey: .data))
        case .unsupported: self = .unsupported(try c.decode(BrowserUnsupportedResult.self, forKey: .data))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind.rawValue, forKey: .kind)
        switch self {
        case .action(let v): try c.encode(v, forKey: .data)
        case .navigation(let v): try c.encode(v, forKey: .data)
        case .snapshot(let v): try c.encode(v, forKey: .data)
        case .image(let v): try c.encode(v, forKey: .data)
        case .pdf(let v): try c.encode(v, forKey: .data)
        case .value(let v): try c.encode(v, forKey: .data)
        case .tabList(let v): try c.encode(v, forKey: .data)
        case .tab(let v): try c.encode(v, forKey: .data)
        case .profileList(let v): try c.encode(v, forKey: .data)
        case .profile(let v): try c.encode(v, forKey: .data)
        case .cookies(let v): try c.encode(v, forKey: .data)
        case .console(let v): try c.encode(v, forKey: .data)
        case .network(let v): try c.encode(v, forKey: .data)
        case .intercept(let v): try c.encode(v, forKey: .data)
        case .capture(let v): try c.encode(v, forKey: .data)
        case .viewport(let v): try c.encode(v, forKey: .data)
        case .identity(let v): try c.encode(v, forKey: .data)
        case .unsupported(let v): try c.encode(v, forKey: .data)
        }
    }
}

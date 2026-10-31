import Foundation
import SmthzCore

/// `smthz browser <cmd>`: parses with BrowserCommandParser and sends the BrowserRequest as host RPC
/// `browser.*`. The host forwards it to the app's browser provider (BROWSER-AGENTS-EXPERIMENT A.6).
func runBrowserCommand(args: [String], defaultSocket: String) throws {
    try BrowserCommands.run(arguments: args, defaultSocket: defaultSocket)
}

enum BrowserCommands {
    static func run(arguments: [String], defaultSocket: String) throws {
        let invocation: BrowserInvocation
        switch try BrowserCommandParser.parse(arguments, cwd: FileManager.default.currentDirectoryPath) {
        case .help(let text): print(text); return
        case .invocation(let value): invocation = value
        }
        let request = invocation.request
        if request.command.support == .unsupported, case .unsupported(let info) = BrowserResult.unsupported(request.command) {
            throw HostRPCError("unsupported", detail: info.reason)
        }
        let client = try HostClient(socketPath: invocation.socket ?? defaultSocket)
        defer { client.disconnect() }
        let result = try client.browser(request, requestID: invocation.requestID ?? RequestID.generate().rawValue,
                                        timeoutMilliseconds: invocation.timeoutMilliseconds)
        let body = try JSONDecoder().decode([String: HostJSON].self, from: JSONEncoder().encode(result))
        if invocation.json { try CLICommon.printResult(body); return }
        print(summary(result, request: request))
    }

    static func summary(_ result: BrowserResult, request: BrowserRequest) -> String {
        func json(_ value: HostJSON) -> String {
            if case .string(let text) = value { return text }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
        }
        func tabLine(_ tab: BrowserTabInfo) -> String {
            var line = "\(tab.active ? "*" : " ") [\(tab.index)] \(tab.pageId) \(tab.url)"
            if let title = tab.title, !title.isEmpty { line += " \"\(title)\"" }
            if request.arguments.showProfile == true || request.command != .tabList {
                if let profile = tab.profileLabel ?? tab.profileId { line += " (profile \(profile))" }
            }
            return line
        }
        switch result {
        case .action(let v):
            var line = "\(v.command.rawValue): ok"
            if let element = v.element { line += " \(element)" }
            if let detail = v.detail { line += " (\(detail))" }
            if v.trusted == false { line += " [untrusted JS events: smthz was not active]" }
            return line
        case .navigation(let v): return "\(v.pageId) \(v.url)" + (v.title.map { " \"\($0)\"" } ?? "")
        case .snapshot(let v):
            var text = v.snapshot
            if v.skippedFrames > 0 { text += "\n(\(v.skippedFrames) frame(s) not captured)" }
            return text
        case .image(let v): return "\(v.format.rawValue) \(v.width)x\(v.height), \(Data(base64Encoded: v.dataBase64)?.count ?? 0) bytes (use --json for the data)"
        case .pdf(let v): return "PDF, \(v.byteCount) bytes (use --json for the data)"
        case .value(let v): return json(v.value)
        case .tabList(let v): return v.tabs.isEmpty ? "No browser tabs" : v.tabs.map(tabLine).joined(separator: "\n")
        case .tab(let v): return tabLine(v)
        case .profileList(let v):
            return v.profiles.map { "\($0.isDefault ? "*" : " ") \($0.id)\t\($0.label)\t\($0.scope.rawValue)" }.joined(separator: "\n")
        case .profile(let v):
            if v.deleted == true { return v.deferred == true ? "Profile deletion deferred until its tabs close" : "Profile deleted" }
            var line = v.profile.map { "\($0.id) \($0.label) (\($0.scope.rawValue))" } ?? "default"
            if let page = v.pageId { line = "\(page): " + line }
            if let copied = v.cookiesCopied { line += ", \(copied) cookie(s) copied" }
            return line
        case .cookies(let v):
            return v.cookies.isEmpty ? "No cookies" : v.cookies.map { "\($0.name)=\($0.value) (\($0.domain))" }.joined(separator: "\n")
        case .console(let v):
            return v.entries.isEmpty ? "No console entries" : v.entries.map { "[\($0.level)] \($0.text)" }.joined(separator: "\n")
        case .network(let v):
            if v.entries.isEmpty { return "No network entries" }
            return v.entries.map { e in
                "\(e.status.map(String.init) ?? "-") \(e.method ?? "GET") \(e.url) (\(e.mimeType ?? "?"), \(e.size.map(String.init) ?? "?")B, \(e.source.rawValue))"
            }.joined(separator: "\n")
        case .intercept(let v):
            if request.command == .interceptList {
                return v.requests.isEmpty ? "No paused requests"
                    : v.requests.map { "[\($0.id)] \($0.method) \($0.url) (\($0.resourceType))" }.joined(separator: "\n")
            }
            return v.enabled ? "Interception enabled for: \(v.patterns.isEmpty ? "*" : v.patterns.joined(separator: ", "))" : "Interception disabled"
        case .capture(let v): return v.capturing ? "Capture started (console + network)" : "Capture stopped"
        case .viewport(let v):
            var line = "Viewport \(Int(v.width))x\(Int(v.height))\(v.mobile ? " (mobile)" : "")"
            if !v.ignored.isEmpty { line += "; not supported by WebKit: \(v.ignored.joined(separator: ", "))" }
            return line
        case .identity(let v):
            return "Browser identity: \(v.configuredMode?.rawValue ?? "unset") (applied: \(v.appliedMode.rawValue)\(v.restartRequired ? ", restart required" : ""))"
        case .unsupported(let v): return "\(v.command.rawValue) is not supported: \(v.reason)"
        }
    }
}

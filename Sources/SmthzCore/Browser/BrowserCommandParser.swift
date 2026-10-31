import Foundation

/// A parsed `smthz browser <cmd> ...` line.
public struct BrowserInvocation: Equatable, Sendable {
    public var request: BrowserRequest
    public var json: Bool
    public var socket: String?
    public var requestID: String?
    /// Client-side RPC budget: navigation and waits outlive the default timeout (Orca uses 60 s).
    public var timeoutMilliseconds: Int {
        switch request.command {
        case .goto, .reload, .openURL, .tabCreate: 60_000
        case .wait: request.arguments.timeout.map { $0 + 5_000 } ?? 60_000
        default: 15_000
        }
    }
}

public enum BrowserParseOutcome: Equatable, Sendable {
    case invocation(BrowserInvocation)
    case help(String)
}

/// Argument grammar of Orca's browser commands: `--flag value`, `--flag=value` (the only way to pass a value
/// starting with `--`), boolean flags without a value, and command path words anywhere on the line.
/// Errors are HostRPCError: unknownCommand, unexpectedArgument, missingArgument, invalidArgument.
public enum BrowserCommandParser {
    static let globalFlags: Set<String> = ["json", "help", "socket", "request-id"]
    static let booleanFlags: Set<String> = ["json", "help", "focus", "mobile", "secure", "httpOnly", "reset", "show-profile"]
    /// Orca accepts an empty string only where it is meaningful (cookie/storage values, empty passwords).
    static let emptyAllowed: Set<BrowserArgument> = [.pass]

    /// CLI flag spelling of each argument.
    public static func flag(for argument: BrowserArgument) -> String {
        switch argument {
        case .waitState, .offline: "state"
        case .profileId: "profile"
        case .deviceScaleFactor: "scale"
        case .colorScheme: "color-scheme"
        case .reducedMotion: "reduced-motion"
        case .showProfile: "show-profile"
        default: argument.rawValue
        }
    }

    static func targetFlags(_ command: BrowserCommand) -> [String] {
        switch command.targetScope {
        case .none: []
        case .worktree: ["worktree"]
        case .worktreeOrPage: ["worktree", "page"]
        }
    }

    static func arguments(_ command: BrowserCommand) -> [String: BrowserArgument] {
        var map: [String: BrowserArgument] = [:]
        for argument in command.requiredArguments.union(command.optionalArguments) { map[flag(for: argument)] = argument }
        return map
    }

    public static func parse(_ args: [String], cwd: String? = nil) throws -> BrowserParseOutcome {
        var words: [String] = []
        var flags: [(name: String, value: String?)] = []
        var i = 0
        while i < args.count {
            let token = args[i]
            i += 1
            guard token.hasPrefix("--"), token.count > 2 else { words.append(token); continue }
            let body = String(token.dropFirst(2))
            if let eq = body.firstIndex(of: "=") {
                flags.append((String(body[..<eq]), String(body[body.index(after: eq)...])))
            } else if booleanFlags.contains(body) {
                flags.append((body, nil))
            } else if i < args.count, !args[i].hasPrefix("--") {
                flags.append((body, args[i])); i += 1
            } else {
                throw HostRPCError("missingArgument", detail: "--\(body) needs a value")
            }
        }
        if words.isEmpty || words == ["help"] {
            if flags.contains(where: { $0.name == "help" }) || words == ["help"] || flags.isEmpty { return .help(overview) }
            throw HostRPCError("unknownCommand", detail: "Pass a browser command; see smthz browser --help")
        }
        guard let command = BrowserCommand(path: words) else {
            throw HostRPCError("unknownCommand", detail: "Unknown browser command: \(words.joined(separator: " "))")
        }
        if flags.contains(where: { $0.name == "help" }) { return .help(usage(for: command)) }

        let argumentFlags = arguments(command)
        let allowed = globalFlags.union(targetFlags(command)).union(argumentFlags.keys)
        var values: [String: String?] = [:]
        for (name, value) in flags {
            guard allowed.contains(name) else {
                throw HostRPCError("unexpectedArgument", detail: "\(command.rawValue) does not accept --\(name)")
            }
            guard values[name] == nil else { throw HostRPCError("invalidArgument", detail: "--\(name) given more than once") }
            if booleanFlags.contains(name), let value, !["true", "false"].contains(value) {
                throw HostRPCError("invalidArgument", detail: "--\(name) is a switch (true or false)")
            }
            values[name] = .some(value)
        }
        func bool(_ name: String) -> Bool { values[name].map { $0 != "false" } ?? false }
        func string(_ name: String) -> String? { values[name] ?? nil }

        var target = BrowserTarget(worktree: string("worktree"), page: string("page"))
        if command.targetScope != .none { target.cwd = cwd }
        var a = BrowserArguments()
        for (name, argument) in argumentFlags {
            guard let raw = values[name] else { continue }
            if booleanFlags.contains(name) {
                try assign(argument, bool(name) ? "true" : "false", to: &a)
                continue
            }
            let text = raw ?? ""
            let allowsEmpty = emptyAllowed.contains(argument)
                || (argument == .value && [.cookieSet, .localSet, .sessionSet].contains(command))
            if text.isEmpty, !allowsEmpty { throw HostRPCError("missingArgument", detail: "--\(name) must not be empty") }
            try assign(argument, text, to: &a)
        }
        // Orca defaults these on the client side.
        if command == .profileCreate, a.scope == nil { a.scope = .isolated }
        if command == .setOffline, a.offline == nil { a.offline = true }
        if command == .profileUseDefault { a.profileId = "default" }
        if command == .fullScreenshot, a.format == nil { a.format = .png }
        // False switches are dropped so the request matches Orca's "only when set" payloads.
        for argument in [BrowserArgument.focus, .mobile, .secure, .httpOnly, .reset, .showProfile] where bool(flag(for: argument)) == false {
            try? assign(argument, nil, to: &a)
        }
        let request = try BrowserRequest(command: command, target: target, arguments: a)
        return .invocation(BrowserInvocation(request: request, json: bool("json"), socket: string("socket"),
                                             requestID: string("request-id")))
    }

    static func assign(_ argument: BrowserArgument, _ raw: String?, to a: inout BrowserArguments) throws {
        let flagName = "--" + flag(for: argument)
        func invalid(_ expected: String) -> HostRPCError {
            HostRPCError("invalidArgument", detail: "\(flagName) must be \(expected)")
        }
        func number() throws -> Double? {
            guard let raw else { return nil }
            guard let value = Double(raw), value.isFinite else { throw invalid("a number") }
            return value
        }
        func integer() throws -> Int? {
            guard let raw else { return nil }
            guard let value = Int(raw) else { throw invalid("an integer") }
            return value
        }
        func choice<T: RawRepresentable>(_: T.Type, _ names: String) throws -> T? where T.RawValue == String {
            guard let raw else { return nil }
            guard let value = T(rawValue: raw) else { throw invalid(names) }
            return value
        }
        func list() -> [String]? { raw.map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } } }
        switch argument {
        case .url: a.url = raw
        case .element: a.element = raw
        case .value: a.value = raw
        case .input: a.input = raw
        case .direction: a.direction = try choice(BrowserScrollDirection.self, "up or down")
        case .amount: a.amount = try integer()
        case .expression: a.expression = raw
        case .selector: a.selector = raw
        case .timeout: a.timeout = try integer()
        case .text: a.text = raw
        case .load: a.load = raw
        case .fn: a.fn = raw
        case .waitState: a.waitState = try choice(BrowserWaitState.self, "hidden or visible")
        case .key: a.key = raw
        case .format: a.format = try choice(BrowserImageFormat.self, "png or jpeg")
        case .from: a.from = raw
        case .to: a.to = raw
        case .files: a.files = list()
        case .index: a.index = try integer()
        case .focus: a.focus = raw.map { $0 == "true" }
        case .profileId: a.profileId = raw
        case .label: a.label = raw
        case .scope: a.scope = try choice(BrowserProfileScope.self, "isolated or imported")
        case .name: a.name = raw
        case .domain: a.domain = raw
        case .path: a.path = raw
        case .secure: a.secure = raw.map { $0 == "true" }
        case .httpOnly: a.httpOnly = raw.map { $0 == "true" }
        case .sameSite: a.sameSite = raw
        case .expires: a.expires = try number()
        case .width: a.width = try number()
        case .height: a.height = try number()
        case .deviceScaleFactor: a.deviceScaleFactor = try number()
        case .mobile: a.mobile = raw.map { $0 == "true" }
        case .latitude: a.latitude = try number()
        case .longitude: a.longitude = try number()
        case .accuracy: a.accuracy = try number()
        case .patterns: a.patterns = list()
        case .limit: a.limit = try integer()
        case .what: a.what = raw
        case .x: a.x = try number()
        case .y: a.y = try number()
        case .button: a.button = try choice(BrowserMouseButton.self, "left, right or middle")
        case .dx: a.dx = try number()
        case .dy: a.dy = try number()
        case .locator: a.locator = raw
        case .action: a.action = raw
        case .headers:
            guard let raw else { a.headers = nil; return }
            guard let object = try? JSONDecoder().decode([String: String].self, from: Data(raw.utf8)) else {
                throw invalid("a JSON object of string values")
            }
            a.headers = object
        case .user: a.user = raw
        case .pass: a.pass = raw
        case .colorScheme: a.colorScheme = try choice(BrowserColorScheme.self, "dark or light")
        case .reducedMotion: a.reducedMotion = try choice(BrowserReducedMotion.self, "reduce or no-preference")
        case .offline:
            guard let raw else { a.offline = nil; return }
            guard ["on", "off"].contains(raw) else { throw invalid("on or off") }
            a.offline = raw == "on"
        case .mode: a.mode = try choice(BrowserIdentityMode.self, "clean or native")
        case .reset: a.reset = raw.map { $0 == "true" }
        case .command: a.command = raw
        case .showProfile: a.showProfile = raw.map { $0 == "true" }
        }
    }

    static func placeholder(_ argument: BrowserArgument) -> String {
        switch argument {
        case .element, .from, .to: "<ref>"
        case .direction: "<up|down>"
        case .format: "<png|jpeg>"
        case .scope: "<isolated|imported>"
        case .mode: "<clean|native>"
        case .button: "<left|right|middle>"
        case .colorScheme: "<dark|light>"
        case .reducedMotion: "<reduce|no-preference>"
        case .waitState: "<hidden|visible>"
        case .offline: "<on|off>"
        case .files: "<path,...>"
        case .patterns: "<glob,...>"
        case .headers: "<json>"
        case .profileId: "<id>"
        case .amount, .timeout, .limit, .index, .width, .height, .deviceScaleFactor, .latitude, .longitude,
             .accuracy, .expires, .x, .y, .dx, .dy: "<n>"
        default: "<\(flag(for: argument))>"
        }
    }

    public static func usage(for command: BrowserCommand) -> String {
        let order = BrowserArgument.allCases
        var parts = ["smthz browser " + command.rawValue]
        for argument in order where command.requiredArguments.contains(argument) {
            parts.append("--\(flag(for: argument)) \(placeholder(argument))")
        }
        for argument in order where command.optionalArguments.contains(argument) {
            let isSwitch = booleanFlags.contains(flag(for: argument))
            parts.append(isSwitch ? "[--\(flag(for: argument))]" : "[--\(flag(for: argument)) \(placeholder(argument))]")
        }
        let page = "--page <id>"
        switch command.targetScope {
        case .none: break
        case .worktree: parts.append("[--worktree <selector>]")
        case .worktreeOrPage:
            let pageRequired = [.tabShow, .profileShow, .profileUseDefault].contains(command)
            parts.append(pageRequired ? page : "[\(page)]")
            parts.append("[--worktree <selector>]")
        }
        parts.append("[--socket <path>] [--json]")
        var line = parts.joined(separator: " ")
        if command.support != .full, let reduction = command.reduction {
            line += "\n  \(command.support == .partial ? "Partial" : "Unsupported") in smthz (\(reduction), docs/BROWSER-AGENTS-EXPERIMENT.md A.5)"
        }
        return line
    }

    public static var overview: String {
        "Usage: smthz browser <command> [flags]\n" + BrowserCommand.allCases.map { "  " + usage(for: $0) }.joined(separator: "\n")
    }
}

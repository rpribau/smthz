import Foundation
import SmthzCore
import Darwin

let usage = """
Usage: smthz --version | --help | paths
       smthz ping [--socket <path>]
       smthz run [--socket <path>] [--cwd <dir>] -- <absolute-exe> [args...]
       smthz sessions [--socket <path>]
       smthz write <id> <text> [--socket <path>]
       smthz read <id> [--from N] [--socket <path>]
       smthz kill <id> [--socket <path>]
       smthz attach <id> [--socket <path>]
       smthz agent list|launch [--agent <id>] [--cwd <dir>] [--prompt <text>] [--draft] [--permission default|auto|bypass] [--socket <path>] [--json]
  smthz job list|get|cancel|wait [--job-id <id>] [--socket <path>] [--json]
  Non-interactive commands accept --json.
write decodes literal \\n escapes; attach detaches on Ctrl-] and leaves the session running.
"""

struct UsageError: Error { let message: String }
struct TerminalError: Error { let message: String }
nonisolated(unsafe) var receivedSignal: sig_atomic_t = 0
nonisolated(unsafe) var windowChanged: sig_atomic_t = 0

func terminalSize() -> (rows: Int, cols: Int) {
    var size = winsize()
    if ioctl(STDIN_FILENO, TIOCGWINSZ, &size) == 0, size.ws_row > 0, size.ws_col > 0 {
        return (Int(size.ws_row), Int(size.ws_col))
    }
    return (24, 80)
}

func exitDescription(_ status: HostSessionExit?) -> String {
    if let code = status?.code { return String(code) }
    return status?.displayDescription ?? "running"
}

func attach(_ client: HostClient, id: String) throws {
    guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
        throw TerminalError(message: "attach requires a terminal on stdin and stdout")
    }
    var original = termios()
    guard tcgetattr(STDIN_FILENO, &original) == 0 else {
        throw TerminalError(message: "cannot read terminal settings")
    }
    // Handlers only set flags. All terminal restoration and RPC work stays in this loop.
    let signals: [Int32] = [SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGTSTP, SIGWINCH, SIGPIPE]
    var previous: [(Int32, sigaction)] = []
    defer {
        _ = tcsetattr(STDIN_FILENO, TCSANOW, &original)
        for (number, saved) in previous {
            var action = saved
            sigaction(number, &action, nil)
        }
    }
    receivedSignal = 0
    windowChanged = 1
    for number in signals {
        var action = sigaction()
        sigemptyset(&action.sa_mask)
        action.__sigaction_u.__sa_handler = { number in
            if number == SIGWINCH { windowChanged = 1 }
            else { receivedSignal = number }
        }
        var saved = sigaction()
        guard sigaction(number, &action, &saved) == 0 else {
            throw TerminalError(message: "cannot install terminal signal handler")
        }
        previous.append((number, saved))
    }
    var raw = original
    cfmakeraw(&raw)
    guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else {
        throw TerminalError(message: "cannot enable raw terminal mode")
    }
    var offset: UInt64 = 0
    var exitedAndEmpty = false
    while receivedSignal == 0 {
        if windowChanged != 0 {
            windowChanged = 0
            let size = terminalSize()
            try client.resize(id: id, rows: size.rows, cols: size.cols)
        }
        let result = try client.read(id: id, from: offset)
        try FileHandle.standardOutput.write(contentsOf: result.data)
        offset = result.next
        if result.exit != nil, result.data.isEmpty {
            if exitedAndEmpty { return }
            exitedAndEmpty = true
        } else { exitedAndEmpty = false }
        var event = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let ready = poll(&event, 1, 50)
        if ready < 0 {
            if errno == EINTR { continue }
            throw TerminalError(message: "cannot poll stdin")
        }
        if ready > 0 {
            if event.revents & Int16(POLLERR | POLLNVAL) != 0 {
                throw TerminalError(message: "terminal input failed")
            }
            if event.revents & Int16(POLLIN | POLLHUP) != 0 {
                var bytes = [UInt8](repeating: 0, count: 4096)
                let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
                if count == 0 { return }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw TerminalError(message: "cannot read stdin")
                }
                let input = bytes.prefix(count)
                let prefix = input.prefix { $0 != 0x1d }
                if !prefix.isEmpty { try client.write(id: id, data: Data(prefix)) }
                if prefix.count != input.count { return }
            }
        }
    }
    throw TerminalError(message: "attach interrupted by signal \(receivedSignal)")
}

func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let command = arguments.first ?? "--help"
    if command == "hook" { HookCommand.run(arguments: Array(arguments.dropFirst())); return }
    var rest = Array(arguments.dropFirst())
    let home = getpwuid(getuid()).map { URL(fileURLWithPath: String(cString: $0.pointee.pw_dir)) }
        ?? FileManager.default.homeDirectoryForCurrentUser
    var socket = ApplicationIdentity.applicationSupportDirectory(home: home).appending(path: "smthzd.sock").path
    var cwd: String?
    var from: UInt64 = 0
    var positional: [String] = []
    let commands = ["ping", "run", "sessions", "write", "read", "kill", "attach"]
    if command == "--help" {
        guard rest.isEmpty || rest == ["--json"] else { throw UsageError(message: usage) }
        if rest == ["--json"] { try CLICommon.printResult(["usage": .string(usage)]) } else { print(usage) }
        return
    }
    if command == "--version" || command == "-v" {
        guard rest.isEmpty || rest == ["--json"] else { throw UsageError(message: usage) }
        if rest == ["--json"] { try CLICommon.printResult(["version": .string(ApplicationIdentity.version)]) }
        else { print("smthz \(ApplicationIdentity.version)") }
        return
    }
    if command == "paths" {
        guard rest.isEmpty || rest == ["--json"] else { throw UsageError(message: usage) }
        let home = FileManager.default.homeDirectoryForCurrentUser
        if rest == ["--json"] {
            try CLICommon.printResult(["applicationSupport": .string(ApplicationIdentity.applicationSupportDirectory(home: home).path),
                "cache": .string(ApplicationIdentity.cacheDirectory(home: home).path), "logs": .string(ApplicationIdentity.logDirectory(home: home).path)])
            return
        }
        print(ApplicationIdentity.applicationSupportDirectory(home: home).path)
        print(ApplicationIdentity.cacheDirectory(home: home).path)
        print(ApplicationIdentity.logDirectory(home: home).path)
        return
    }
    if command == "agent" { try AgentCommands.run(arguments: rest, defaultSocket: socket); return }
    if try CLICommon.dispatch(command: command, arguments: rest, defaultSocket: socket) { return }
    var jsonOutput = false
    guard commands.contains(command) else { throw UsageError(message: "unknown command: \(command)\n\(usage)") }
    var executable: String?
    var childArguments: [String] = []
    while !rest.isEmpty {
        let token = rest.removeFirst()
        if command == "run", token == "--" {
            guard let path = rest.first, path.hasPrefix("/") else { throw UsageError(message: usage) }
            executable = path; childArguments = Array(rest.dropFirst()); rest = []; break
        }
        // Once the id has been consumed, write's next argument is literal text, even if it starts with --.
        if command == "write", positional.count == 1 {
            positional.append(token); continue
        }
        switch token {
        case "--json": jsonOutput = true
        case "--socket":
            guard !rest.isEmpty else { throw UsageError(message: "missing socket path") }
            socket = rest.removeFirst()
        case "--cwd" where command == "run":
            guard !rest.isEmpty else { throw UsageError(message: "missing working directory") }
            cwd = rest.removeFirst()
        case "--from" where command == "read":
            guard !rest.isEmpty, let value = UInt64(rest.removeFirst()) else { throw UsageError(message: "invalid read offset") }
            from = value
        default:
            guard !token.hasPrefix("--") else { throw UsageError(message: "unknown option: \(token)") }
            positional.append(token)
        }
    }
    let expected = ["write": 2, "read": 1, "kill": 1, "attach": 1][command] ?? 0
    guard positional.count == expected, command != "run" || executable != nil else { throw UsageError(message: usage) }
    let client = try HostClient(socketPath: socket)
    defer { client.disconnect() }
    if jsonOutput {
        var method = ""
        var params: [String: HostJSON] = [:]
        switch command {
        case "ping": method = "ping"
        case "run":
            method = "session.create"
            let size = terminalSize()
            params = ["executable": .string(executable!), "arguments": .array(childArguments.map(HostJSON.string)),
                      "rows": .number(Double(size.rows)), "cols": .number(Double(size.cols))]
            params["cwd"] = cwd.map(HostJSON.string)
        case "sessions": method = "session.list"
        case "write":
            method = "session.write"
            params = ["id": .string(positional[0]), "data_base64": .string(Data(positional[1].replacingOccurrences(of: "\\n", with: "\n").utf8).base64EncodedString())]
        case "read": method = "session.read"; params = ["id": .string(positional[0]), "from": .number(Double(from))]
        case "kill": method = "session.close"; params = ["id": .string(positional[0])]
        default: throw HostRPCError("badRequest", detail: "attach requires interactive output")
        }
        try CLICommon.printResult(CLICommon.call(client, method, params))
        return
    }
    switch command {
    case "ping":
        struct Params: Encodable {}
        struct Pong: Decodable { let result: String }
        let response: Pong = try client.call(method: "ping", params: Params())
        guard response.result == "pong" else { throw HostClientError.invalidResponse }
        print(response.result)
    case "run":
        let size = terminalSize()
        let session = try client.createSession(executable: executable!, arguments: childArguments,
                                              cwd: cwd, rows: size.rows, cols: size.cols)
        print(session.id)
    case "sessions":
        for session in try client.list().sessions {
            let state: String
            if session.running { state = "running" }
            else { state = "exited(\(exitDescription(try client.read(id: session.id).exit)))" }
            print("\(session.id) \(session.pid) \(state)")
        }
    case "write": try client.write(id: positional[0], data: Data(positional[1].replacingOccurrences(of: "\\n", with: "\n").utf8))
    case "read":
        let result = try client.read(id: positional[0], from: from)
        try FileHandle.standardOutput.write(contentsOf: result.data)
        try FileHandle.standardError.write(contentsOf: Data("next=\(result.next) exit=\(exitDescription(result.exit))\n".utf8))
    case "kill": try client.close(id: positional[0])
    case "attach": try attach(client, id: positional[0])
    default: break
    }
}

do { try run() }
catch let error as UsageError {
    if CommandLine.arguments.contains("--json") { CLICommon.printError(error); exit(1) }
    FileHandle.standardError.write(Data((error.message + "\n").utf8)); exit(2)
} catch {
    if CommandLine.arguments.dropFirst().prefix(while: { $0 != "--" }).contains("--json") {
        CLICommon.printError(error); exit(error is CLIInterrupted ? 130 : 1)
    }
    if error is CLIInterrupted { exit(130) }
    let message = (error as? TerminalError)?.message ?? String(describing: error)
    FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1)
}

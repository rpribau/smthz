import Foundation
import Testing
@testable import SmthzCore

private func invocation(_ line: [String], cwd: String? = "/tmp/repo") throws -> BrowserInvocation {
    guard case .invocation(let value) = try BrowserCommandParser.parse(line, cwd: cwd) else {
        throw HostRPCError("unexpectedHelp")
    }
    return value
}

private func parseCode(_ line: [String]) -> String? {
    do { _ = try BrowserCommandParser.parse(line); return nil } catch let error as HostRPCError { return error.code } catch { return "other" }
}

@Suite struct BrowserCommandParserTests {
    @Test func everyCommandParsesFromItsRequiredFlags() throws {
        for command in BrowserCommand.allCases {
            var line = command.path
            for argument in command.requiredArguments where !(command == .profileUseDefault && argument == .profileId) {
                line += ["--" + BrowserCommandParser.flag(for: argument), browserSampleValue(argument)]
            }
            if [.tabShow, .profileShow, .profileUseDefault, .tabSwitch, .profileSet].contains(command) { line += ["--page", "p1"] }
            let parsed = try invocation(line)
            #expect(parsed.request.command == command, "\(line)")
            #expect(parsed.request.target.cwd == (command.targetScope == .none ? nil : "/tmp/repo"))
        }
    }

    @Test func everyCommandParsesWithAllOptionalFlags() throws {
        for command in BrowserCommand.allCases {
            var line = command.path + ["--json", "--socket", "/tmp/s.sock", "--request-id", "r-1"]
            for argument in command.requiredArguments.union(command.optionalArguments)
            where !(command == .profileUseDefault && argument == .profileId) {
                let flag = "--" + BrowserCommandParser.flag(for: argument)
                if BrowserCommandParser.booleanFlags.contains(BrowserCommandParser.flag(for: argument)) { line.append(flag) }
                else { line += [flag, browserSampleValue(argument)] }
            }
            if command.targetScope != .none { line += ["--worktree", "name:main"] }
            if command.targetScope == .worktreeOrPage { line += ["--page", "p1"] }
            let parsed = try invocation(line)
            #expect(parsed.request.command == command)
            #expect(parsed.json && parsed.socket == "/tmp/s.sock" && parsed.requestID == "r-1")
            #expect(parsed.request.arguments.present.isSuperset(of: command.requiredArguments))
        }
    }

    @Test func convertsValuesLikeOrca() throws {
        let upload = try invocation(["upload", "--element", "e3", "--files", "/a, /b c"]).request.arguments
        #expect(upload.files == ["/a", "/b c"])
        let headers = try invocation(["set", "headers", "--headers", #"{"X-A":"1","X-B":"two"}"#]).request.arguments
        #expect(headers.headers == ["X-A": "1", "X-B": "two"])
        let wheel = try invocation(["mouse", "wheel", "--dy", "-120", "--dx", "4.5"]).request.arguments
        #expect(wheel.dy == -120 && wheel.dx == 4.5)
        let typed = try invocation(["type", "--input=--not-a-flag"]).request.arguments
        #expect(typed.input == "--not-a-flag")
        let cookie = try invocation(["cookie", "set", "--name", "sid", "--value", "", "--secure", "--httpOnly", "--expires", "0"])
        #expect(cookie.request.arguments.value == "" && cookie.request.arguments.secure == true && cookie.request.arguments.httpOnly == true)
        #expect(cookie.request.arguments.expires == 0)
        let wait = try invocation(["wait", "--selector", "#go", "--state", "hidden", "--timeout", "2000"])
        #expect(wait.request.arguments.waitState == .hidden)
        #expect(wait.timeoutMilliseconds == 7_000)
        #expect(try invocation(["goto", "--url", "https://a"]).timeoutMilliseconds == 60_000)
        #expect(try invocation(["snapshot"]).timeoutMilliseconds == 15_000)
        // Command words may come after flags, as in Orca.
        #expect(try invocation(["--json", "tab", "list", "--show-profile"]).request.arguments.showProfile == true)
    }

    @Test func appliesOrcaClientDefaults() throws {
        #expect(try invocation(["tab", "profile", "create", "--label", "Work"]).request.arguments.scope == .isolated)
        #expect(try invocation(["set", "offline"]).request.arguments.offline == true)
        #expect(try invocation(["set", "offline", "--state", "off"]).request.arguments.offline == false)
        #expect(try invocation(["tab", "profile", "use-default", "--page", "p1"]).request.arguments.profileId == "default")
        #expect(try invocation(["full-screenshot"]).request.arguments.format == .png)
        #expect(try invocation(["identity", "show"]).request.command == .identityGet)
        let unset = try invocation(["tab", "switch", "--index", "0", "--focus=false"]).request.arguments
        #expect(unset.focus == nil && unset.index == 0)
        let host = try invocation(["tab", "profile", "list"]).request
        #expect(host.target == BrowserTarget())
    }

    @Test func rejectsBadLines() {
        #expect(parseCode(["teleport"]) == "unknownCommand")
        #expect(parseCode(["tab", "profile"]) == "unknownCommand")
        #expect(parseCode(["click", "--element"]) == "missingArgument")
        #expect(parseCode(["click"]) == "missingArgument")
        #expect(parseCode(["click", "--element", ""]) == "missingArgument")
        #expect(parseCode(["click", "--element", "e1", "--url", "x"]) == "unexpectedArgument")
        #expect(parseCode(["tab", "list", "--page", "p1"]) == "unexpectedArgument")
        #expect(parseCode(["tab", "profile", "list", "--worktree", "w"]) == "unexpectedArgument")
        #expect(parseCode(["click", "--element", "a", "--element", "b"]) == "invalidArgument")
        #expect(parseCode(["scroll", "--direction", "left"]) == "invalidArgument")
        #expect(parseCode(["scroll", "--direction", "up", "--amount", "1.5"]) == "invalidArgument")
        #expect(parseCode(["viewport", "--width", "0", "--height", "10"]) == "invalidArgument")
        #expect(parseCode(["viewport", "--width", "w", "--height", "10"]) == "invalidArgument")
        #expect(parseCode(["set", "headers", "--headers", "[1]"]) == "invalidArgument")
        #expect(parseCode(["set", "offline", "--state", "maybe"]) == "invalidArgument")
        #expect(parseCode(["tab", "list", "--show-profile=yes"]) == "invalidArgument")
        #expect(parseCode(["geolocation", "--latitude", "100", "--longitude", "0"]) == "invalidArgument")
        #expect(parseCode(["--json"]) == "unknownCommand")
    }

    @Test func helpListsEveryCommand() throws {
        guard case .help(let overview) = try BrowserCommandParser.parse([]) else { Issue.record("no help"); return }
        for command in BrowserCommand.allCases { #expect(overview.contains("smthz browser " + command.rawValue + " ")) }
        guard case .help(let one) = try BrowserCommandParser.parse(["drag", "--help"]) else { Issue.record("no help"); return }
        #expect(one.hasPrefix("smthz browser drag --from <ref> --to <ref>"))
        #expect(one.contains("R-B1"))
        #expect(BrowserCommandParser.usage(for: .exec).contains("Unsupported"))
    }
}

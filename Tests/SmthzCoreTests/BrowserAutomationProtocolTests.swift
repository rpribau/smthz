import Foundation
import Testing
@testable import SmthzCore

/// CLI spelling of a valid sample value for each argument.
func browserSampleValue(_ argument: BrowserArgument) -> String {
    switch argument {
    case .url: "https://example.com/"
    case .direction: "down"
    case .format: "jpeg"
    case .scope: "imported"
    case .mode: "native"
    case .button: "right"
    case .colorScheme: "dark"
    case .reducedMotion: "no-preference"
    case .waitState: "visible"
    case .offline: "off"
    case .files: "/tmp/a.txt,/tmp/b.txt"
    case .patterns: "*.js,*.css"
    case .headers: #"{"X-Test":"1"}"#
    case .amount, .timeout, .limit, .index, .width, .height, .deviceScaleFactor, .accuracy, .expires: "3"
    case .latitude, .longitude, .x, .y, .dx, .dy: "-12.5"
    case .focus, .mobile, .secure, .httpOnly, .reset, .showProfile: "true"
    default: "v-\(argument.rawValue)"
    }
}

private func sampleRequest(_ command: BrowserCommand, includeOptional: Bool = false) throws -> BrowserRequest {
    var arguments = BrowserArguments()
    var wanted = command.requiredArguments
    if includeOptional { wanted.formUnion(command.optionalArguments) }
    for argument in wanted { try BrowserCommandParser.assign(argument, browserSampleValue(argument), to: &arguments) }
    var target = BrowserTarget()
    switch command.targetScope {
    case .none: break
    case .worktree: target = BrowserTarget(worktree: "name:main", cwd: "/tmp/repo")
    case .worktreeOrPage: target = BrowserTarget(worktree: "name:main", page: "page-1", cwd: "/tmp/repo")
    }
    return try BrowserRequest(command: command, target: target, arguments: arguments)
}

private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
}

private func rpcCode(_ body: () throws -> Void) -> String? {
    do { try body(); return nil } catch let error as HostRPCError { return error.code } catch { return "other" }
}

@Suite struct BrowserAutomationProtocolTests {
    @Test func coversEveryOrcaBrowserCommandWithTheA4Verdicts() {
        let all = BrowserCommand.allCases
        #expect(all.count == 80)
        #expect(Set(all.map(\.rawValue)).count == 80)
        #expect(all.filter { $0.support == .full }.count == 56)
        #expect(all.filter { $0.support == .partial }.count == 23)
        #expect(all.filter { $0.support == .unsupported } == [.exec])
        for command in all where command.support != .full { #expect(command.reduction != nil) }
        #expect(BrowserCommand(path: ["identity", "show"]) == .identityGet)
        #expect(BrowserCommand(path: ["tab", "profile", "use-default"]) == .profileUseDefault)
        #expect(BrowserCommand(path: ["tab", "profile"]) == nil)
    }

    @Test func methodsAreOrcaRPCNames() {
        let methods = BrowserCommand.allCases.map(\.method)
        #expect(methods.allSatisfy { $0.hasPrefix("browser.") })
        // Only `tab profile set` and `tab profile use-default` share browser.tabSetProfile, as in Orca.
        #expect(Set(methods).count == 79)
        #expect(BrowserCommand.selectAll.method == "browser.selectAll")
        #expect(BrowserCommand.insertText.method == "browser.keyboardInsertText")
        #expect(BrowserCommand.sessionSet.method == "browser.storage.session.set")
        #expect(BrowserCommand.click.method == "browser.click")
        #expect(BrowserCommand.profileUseDefault.method == BrowserCommand.profileSet.method)
    }

    @Test func everyRequestRoundTripsWithRequiredAndOptionalArguments() throws {
        for command in BrowserCommand.allCases {
            for includeOptional in [false, true] {
                let request = try sampleRequest(command, includeOptional: includeOptional)
                #expect(try roundTrip(request) == request, "\(command.rawValue)")
                #expect(request.arguments.present.isSuperset(of: command.requiredArguments))
            }
        }
    }

    @Test func wireShapeUsesCommandPathAndOmitsUnsetArguments() throws {
        var arguments = BrowserArguments()
        arguments.element = "e7"
        let request = try BrowserRequest(command: .click, target: BrowserTarget(page: "p1"), arguments: arguments)
        let object = try JSONDecoder().decode([String: HostJSON].self, from: JSONEncoder().encode(request))
        #expect(object["command"] == .string("click"))
        #expect(object["arguments"] == .object(["element": .string("e7")]))
        #expect(object["target"] == .object(["page": .string("p1")]))
        let profile = try sampleRequest(.profileClone)
        let encoded = String(decoding: try JSONEncoder().encode(profile), as: UTF8.self)
        #expect(encoded.contains(#""command":"tab profile clone""#))
    }

    @Test func unknownCommandIsRejectedOnDecode() {
        let json = #"{"command":"teleport","target":{},"arguments":{}}"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(BrowserRequest.self, from: Data(json.utf8)) }
        let invalid = #"{"command":"click","target":{},"arguments":{}}"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(BrowserRequest.self, from: Data(invalid.utf8)) }
        let ok = #"{"command":"click","arguments":{"element":"e1"}}"#
        #expect(throws: Never.self) { try JSONDecoder().decode(BrowserRequest.self, from: Data(ok.utf8)) }
    }

    @Test func validationRejectsMissingExtraAndBadValues() {
        #expect(rpcCode { _ = try BrowserRequest(command: .fill) } == "missingArgument")
        var extra = BrowserArguments(); extra.url = "https://a"
        #expect(rpcCode { _ = try BrowserRequest(command: .back, arguments: extra) } == "unexpectedArgument")
        #expect(rpcCode { _ = try BrowserRequest(command: .profileList, target: BrowserTarget(page: "p")) } == "unexpectedArgument")
        #expect(rpcCode { _ = try BrowserRequest(command: .tabList, target: BrowserTarget(page: "p")) } == "unexpectedArgument")
        #expect(rpcCode { _ = try BrowserRequest(command: .tabShow) } == "missingArgument")
        #expect(rpcCode { _ = try BrowserRequest(command: .tabSwitch) } == "missingArgument")
        #expect(rpcCode { _ = try BrowserRequest(command: .tabSwitch, target: BrowserTarget(page: "p")) } == nil)
        var profile = BrowserArguments(); profile.profileId = "work"
        #expect(rpcCode { _ = try BrowserRequest(command: .profileSet, arguments: profile) } == "missingArgument")

        func bad(_ command: BrowserCommand, _ edit: (inout BrowserArguments) -> Void) -> String? {
            var a = (try? sampleRequest(command).arguments) ?? BrowserArguments()
            edit(&a)
            return rpcCode { _ = try BrowserRequest(command: command, target: BrowserTarget(page: "p"), arguments: a) }
        }
        #expect(bad(.viewport) { $0.width = -1 } == "invalidArgument")
        #expect(bad(.viewport) { $0.height = .infinity } == "invalidArgument")
        #expect(bad(.geolocation) { $0.latitude = 91 } == "invalidArgument")
        #expect(bad(.geolocation) { $0.longitude = -181 } == "invalidArgument")
        #expect(bad(.upload) { $0.files = [] } == "invalidArgument")
        #expect(bad(.scroll) { $0.amount = 0 } == "invalidArgument")
        #expect(bad(.click) { $0.element = "" } == "invalidArgument")
        #expect(bad(.setHeaders) { $0.headers = [:] } == "invalidArgument")
        #expect(bad(.mouseWheel) { $0.dy = .nan } == "invalidArgument")
        #expect(bad(.cookieSet) { $0.expires = -5 } == "invalidArgument")
        #expect(bad(.cookieSet) { $0.value = "" } == nil)
        #expect(bad(.setCredentials) { $0.pass = "" } == nil)
    }

    @Test func resultsRoundTripForEveryKind() throws {
        let tab = BrowserTabInfo(pageId: "p1", index: 0, url: "https://a/", title: "A", active: true,
                                 worktree: "w1", profileId: "default", profileLabel: "Default")
        let profile = BrowserProfileInfo(id: "work", label: "Work", scope: .isolated, isDefault: false)
        let samples: [BrowserResult] = [
            .action(BrowserActionResult(command: .click, element: "e1", trusted: false, detail: "js")),
            .navigation(BrowserNavigationResult(pageId: "p1", url: "https://a/", title: "A")),
            .snapshot(BrowserSnapshotResult(pageId: "p1", url: "https://a/", snapshot: "- button \"Go\" [ref=e1]",
                                            refs: [BrowserElementRef(ref: "e1", role: "button", name: "Go")], skippedFrames: 1)),
            .image(BrowserImageResult(format: .png, width: 2, height: 3, dataBase64: "AAEC")),
            .pdf(BrowserPDFResult(dataBase64: "JVBERg==", byteCount: 4)),
            .value(BrowserValueResult(value: .object(["n": .number(1), "list": .array([.null, .bool(true)])]))),
            .tabList(BrowserTabListResult(tabs: [tab])),
            .tab(tab),
            .profileList(BrowserProfileListResult(profiles: [profile])),
            .profile(BrowserProfileResult(profile: profile, pageId: "p1", deleted: true, deferred: true, cookiesCopied: 4)),
            .cookies(BrowserCookieListResult(cookies: [BrowserCookie(name: "sid", value: "x", domain: ".a", secure: true,
                                                                     httpOnly: true, sameSite: "Lax", expires: 1_900_000_000)])),
            .console(BrowserConsoleResult(entries: [BrowserConsoleEntry(level: "warn", text: "hi", timestamp: 1.5)], dropped: 2)),
            .network(BrowserNetworkResult(entries: [BrowserNetworkEntry(url: "https://a/x.js", source: .resourceTiming),
                                                    BrowserNetworkEntry(url: "https://a/", method: "GET", status: 200,
                                                                        mimeType: "text/html", size: 10, source: .document)])),
            .intercept(BrowserInterceptResult(enabled: true, patterns: ["*.js"],
                                              requests: [BrowserInterceptedRequest(id: "r1", method: "POST", url: "https://a/api", resourceType: "fetch")])),
            .capture(BrowserCaptureResult(capturing: true)),
            .viewport(BrowserViewportResult(width: 390, height: 844, mobile: true, ignored: ["deviceScaleFactor", "touch"])),
            .identity(BrowserIdentityResult(configuredMode: nil, appliedMode: .clean, restartRequired: true)),
            .unsupported(.exec),
        ]
        #expect(Set(samples.map(\.kind)) == Set(BrowserResultKind.allCases))
        for sample in samples { #expect(try roundTrip(sample) == sample) }
        let object = try JSONDecoder().decode([String: HostJSON].self, from: JSONEncoder().encode(samples[14]))
        #expect(object == ["kind": .string("capture"), "data": .object(["capturing": .bool(true)])])
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(BrowserResult.self, from: Data(#"{"kind":"hologram","data":{}}"#.utf8))
        }
    }

    @Test func execMapsToTheUnsupportedResult() {
        #expect(BrowserCommand.exec.resultKind == .unsupported)
        guard case .unsupported(let info) = BrowserResult.unsupported(.exec) else { Issue.record("not unsupported"); return }
        #expect(info.command == .exec)
        #expect(info.reduction == "R-B9")
        #expect(BrowserCommand.allCases.filter { $0.resultKind == .unsupported } == [.exec])
    }
}

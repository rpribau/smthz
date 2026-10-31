import Foundation
import Testing
@testable import SmthzCore

private final class BrowserForwardingFixture: @unchecked Sendable {
    let directory: URL
    let service: HostService
    let server: UnixSocketServer
    let client: HostClient
    var provider: HostBrowserProvider?
    let workers = DispatchGroup()

    init() throws {
        directory = URL(fileURLWithPath: "/tmp/smthz-bf-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let journal = try EventJournal(path: directory.appendingPathComponent("journal").path)
        let host = HostService(journal: journal, hostIdentity: nil)
        service = host
        let path = directory.appendingPathComponent("host.sock").path
        server = try UnixSocketServer(path: path, handler: { host.handle($0) },
            streamHandler: { host.stream($0, send: $1, cancelled: $2) })
        client = try HostClient(socketPath: path)
    }

    func fake(_ body: @escaping @Sendable (HostBrowserProvider) throws -> Void) throws {
        provider = try client.registerBrowserProvider()
        workers.enter()
        Thread.detachNewThread { [self] in
            defer { workers.leave() }
            do { try body(provider!) }
            catch { Issue.record(error) }
        }
    }

    func close() {
        provider?.interrupt()
        #expect(workers.wait(timeout: .now() + 10) == .success)
        provider?.disconnect()
        client.disconnect()
        server.stop()
        service.stop()
        try? FileManager.default.removeItem(at: directory)
    }
}

struct BrowserForwardingTests {
    @Test func roundTripPreservesCommandAndRequestID() throws {
        let f = try BrowserForwardingFixture(); defer { f.close() }
        let request = try BrowserRequest(command: .tabList, target: BrowserTarget(worktree: "project"))
        let id = RequestID.generate().rawValue
        try f.fake { provider in
            let command = try provider.receive()
            #expect(command.request == request)
            #expect(command.requestID == id)
            try provider.reply(to: command, result: .tabList(BrowserTabListResult(tabs: [])))
        }
        let result = try f.client.browser(request, requestID: id)
        guard case .tabList(let list) = result else { Issue.record("Expected tab list"); return }
        #expect(list.tabs.isEmpty)
    }

    @Test func noProviderReturnsActionableError() throws {
        let f = try BrowserForwardingFixture(); defer { f.close() }
        #expect(throws: HostClientError.detailedHostError(code: "noBrowserProvider", detail: "No browser provider: start the smthz app")) {
            try f.client.browser(BrowserRequest(command: .tabList))
        }
    }

    @Test func disconnectMidRequestFailsPromptly() throws {
        let f = try BrowserForwardingFixture(); defer { f.close() }
        try f.fake { provider in
            _ = try provider.receive()
            provider.interrupt()
        }
        #expect(throws: HostClientError.detailedHostError(code: "browserProviderDisconnected", detail: "Browser provider disconnected during the request")) {
            try f.client.browser(BrowserRequest(command: .tabList), timeoutMilliseconds: 5_000)
        }
    }

    @Test func timeoutExpiresDeliveryAndDoesNotJournalIt() throws {
        let f = try BrowserForwardingFixture(); defer { f.close() }
        let timedOut = DispatchSemaphore(value: 0)
        let replied = DispatchSemaphore(value: 0)
        try f.fake { provider in
            let command = try provider.receive()
            #expect(timedOut.wait(timeout: .now() + 10) == .success)
            #expect(throws: HostClientError.detailedHostError(code: "browserRequestExpired", detail: nil)) {
                try provider.reply(to: command, result: .tabList(BrowserTabListResult(tabs: [])))
            }
            replied.signal()
        }
        let id = RequestID.generate().rawValue
        #expect(throws: HostClientError.detailedHostError(code: "deadlineExceeded", detail: nil)) {
            try f.client.browser(BrowserRequest(command: .tabList), requestID: id, timeoutMilliseconds: 1_000)
        }
        timedOut.signal()
        #expect(replied.wait(timeout: .now() + 10) == .success)
        let journal = try EventJournal(path: f.directory.appendingPathComponent("journal").path)
        #expect(try journal.entry(requestID: id) == nil)
    }

    @Test func successfulReplayDoesNotNeedProviderAndConflictsFail() throws {
        let f = try BrowserForwardingFixture(); defer { f.close() }
        try f.fake { provider in
            let command = try provider.receive()
            try provider.reply(to: command, result: .tabList(BrowserTabListResult(tabs: [])))
            provider.interrupt()
        }
        let id = RequestID.generate().rawValue
        let request = try BrowserRequest(command: .tabList)
        let first = try f.client.browser(request, requestID: id)
        let replay = try f.client.browser(request, requestID: id)
        #expect(try JSONDecoder().decode(HostJSON.self, from: JSONEncoder().encode(first)) ==
                JSONDecoder().decode(HostJSON.self, from: JSONEncoder().encode(replay)))
        #expect(throws: HostClientError.detailedHostError(code: "idempotencyConflict", detail: nil)) {
            try f.client.browser(BrowserRequest(command: .tabCurrent), requestID: id)
        }
    }

    @Test func execIsUnsupportedWithoutProvider() throws {
        let f = try BrowserForwardingFixture(); defer { f.close() }
        var args = BrowserArguments(); args.command = "anything"
        #expect(throws: HostClientError.detailedHostError(code: "unsupported", detail: "browser exec is unsupported (R-B9)")) {
            try f.client.browser(BrowserRequest(command: .exec, arguments: args))
        }
    }

    @Test func onlyOneProviderCanRegister() throws {
        let f = try BrowserForwardingFixture(); defer { f.close() }
        f.provider = try f.client.registerBrowserProvider()
        #expect(throws: HostClientError.detailedHostError(code: "browserProviderAlreadyRegistered", detail: nil)) {
            try f.client.registerBrowserProvider()
        }
    }

    @Test func providerErrorIsForwardedAndReplayed() throws {
        let f = try BrowserForwardingFixture(); defer { f.close() }
        try f.fake { provider in
            try provider.reply(to: provider.receive(), error: HostRPCError("pageNotFound", detail: "No such page"))
        }
        let id = RequestID.generate().rawValue
        for _ in 0..<2 {
            #expect(throws: HostClientError.detailedHostError(code: "pageNotFound", detail: "No such page")) {
                try f.client.browser(BrowserRequest(command: .tabList), requestID: id)
            }
        }
    }

    @Test func mismatchedMethodAndUnauthenticatedRegistrationAreRejected() throws {
        let f = try BrowserForwardingFixture(); defer { f.close() }
        let request = try BrowserRequest(command: .tabList)
        let payload = try f.client.rawCall(method: BrowserCommand.tabCurrent.method, params: JSONEncoder().encode(request))
        #expect(try JSONDecoder().decode([String: HostJSON].self, from: payload)["error"] == .string("badRequest"))
        let wire = RPCEnvelope(version: RPCEnvelope.currentVersion, requestID: "unauthenticated",
            method: "browser.provider.register", payload: Data("{}".utf8))
        let response = try JSONDecoder().decode(RPCEnvelope.self, from: f.service.handle(JSONEncoder().encode(wire)))
        #expect(try JSONDecoder().decode([String: HostJSON].self, from: response.payload)["error"] == .string("unauthorized"))
    }

    @Test func browserAcceptsNavigationBudgetBeyondOrdinaryHostLimit() throws {
        let f = try BrowserForwardingFixture(); defer { f.close() }
        try f.fake { provider in
            try provider.reply(to: provider.receive(), result: .tabList(BrowserTabListResult(tabs: [])))
        }
        _ = try f.client.browser(BrowserRequest(command: .tabList), timeoutMilliseconds: 60_000)
    }

    @Test func providerRepliesDrainWhenHostAdmissionIsFull() throws {
        let f = try BrowserForwardingFixture(); defer { f.close() }
        f.provider = try f.client.registerBrowserProvider()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()
        f.service.router.register("test.browser.block", methodClass: .read) { _, _ in
            entered.signal()
            _ = release.wait(timeout: .now() + 15)
            return [:]
        }
        defer {
            for _ in 0..<HostService.maximumPendingRequests { release.signal() }
            #expect(finished.wait(timeout: .now() + 10) == .success)
        }
        for _ in 0..<HostService.maximumPendingRequests {
            finished.enter()
            Thread.detachNewThread {
                defer { finished.leave() }
                let request = RPCEnvelope(version: 1, requestID: UUID().uuidString,
                    method: "test.browser.block", payload: Data("{}".utf8))
                _ = try? f.service.handleAuthenticatedTestRequest(JSONEncoder().encode(request))
            }
        }
        for _ in 0..<HostService.maximumPendingRequests {
            #expect(entered.wait(timeout: .now() + 10) == .success)
        }
        let expired = HostBrowserCommand(deliveryID: "expired", requestID: "expired", request: try BrowserRequest(command: .tabList))
        #expect(throws: HostClientError.detailedHostError(code: "browserRequestExpired", detail: nil)) {
            try f.provider!.reply(to: expired, result: .tabList(BrowserTabListResult(tabs: [])))
        }
    }
}

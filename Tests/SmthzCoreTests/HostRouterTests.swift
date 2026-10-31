import Foundation
import Testing
@testable import SmthzCore

final class HostCoreFixture: @unchecked Sendable {
    let directory: URL
    let journal: EventJournal
    let router = HostRouter()
    let service: HostService
    init() throws {
        directory = URL(fileURLWithPath: "/tmp/smthz-hc-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        journal = try EventJournal(path: directory.appendingPathComponent("journal").path)
        service = HostService(journal: journal, hostIdentity: nil, router: router)
    }
    deinit { service.stop(); try? FileManager.default.removeItem(at: directory) }
    func call(_ method: String, _ params: [String: HostJSON] = [:], id: String = UUID().uuidString, timeout: Int? = nil) throws -> [String: HostJSON] {
        let request = RPCEnvelope(version: 1, requestID: id, method: method, payload: try JSONEncoder().encode(params), timeoutMilliseconds: timeout)
        let envelope = try JSONDecoder().decode(RPCEnvelope.self, from: service.handleAuthenticatedTestRequest(JSONEncoder().encode(request)))
        return try JSONDecoder().decode([String: HostJSON].self, from: envelope.payload)
    }
}

struct HostRouterTests {
    @Test func readsAndUnknownMethodsLeaveNoJournalRows() throws {
        let f = try HostCoreFixture()
        f.router.register("test.read", methodClass: .read) { _, _ in ["value": .string("live")] }
        for method in ["ping", "version", "host.identity", "session.list", "test.read", "job.list", "repo.list"] {
            _ = try f.call(method)
        }
        #expect(try f.journal.read(after: 0, limit: 100).isEmpty)
    }
    @Test func longJobDoesNotDelaySessionWrite() throws {
        let f = try HostCoreFixture()
        let session = try f.service.sessionManager.create(executable: "/bin/cat", arguments: [])
        let started = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        f.router.register("test.job", methodClass: .job) { [jobs = f.router.jobs] _, _ in
            let id = try jobs.submit(repository: "repo") { _ in
                started.signal(); Thread.sleep(forTimeInterval: 3); finished.signal(); return .null
            }
            return ["jobId": .string(id)]
        }
        #expect(try f.call("test.job")["ok"] == .bool(true))
        #expect(started.wait(timeout: .now() + 2) == .success)
        let start = ContinuousClock.now
        #expect(try f.call("session.write", ["id": .string(session.id), "data_base64": .string(Data("x\n".utf8).base64EncodedString())])["ok"] == .bool(true))
        #expect(start.duration(to: .now) < .milliseconds(100))
        #expect(finished.wait(timeout: .now() + 5) == .success)
    }
    @Test func mutationsAndJobsShareRepositoryGateWhileReadsProceed() throws {
        let f = try HostCoreFixture()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let id = try f.router.jobs.submit(repository: "same") { _ in
            entered.signal(); _ = release.wait(timeout: .now() + 3); return .null
        }
        #expect(entered.wait(timeout: .now() + 2) == .success)
        let attempting = DispatchSemaphore(value: 0)
        f.router.register("test.mutate", methodClass: .mutation, repository: { params in
            attempting.signal(); return params["repoId"]?.string
        }) { _, _ in [:] }
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread { _ = try? f.call("test.mutate", ["repoId": .string("same")]); done.signal() }
        #expect(attempting.wait(timeout: .now() + 2) == .success)
        #expect(done.wait(timeout: .now() + 0.05) == .timedOut)
        #expect(try f.call("job.get", ["jobId": .string(id)])["state"] == .string("running"))
        #expect(try f.call("ping")["result"] == .string("pong"))
        release.signal()
        #expect(done.wait(timeout: .now() + 2) == .success)
    }
    @Test func routedAdmissionStillCapsPendingAt64() throws {
        let f = try HostCoreFixture()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()
        f.router.register("test.block", methodClass: .read) { _, _ in
            entered.signal(); _ = release.wait(timeout: .now() + 5); return [:]
        }
        for _ in 0..<64 {
            finished.enter()
            Thread.detachNewThread { _ = try? f.call("test.block"); finished.leave() }
        }
        for _ in 0..<64 { #expect(entered.wait(timeout: .now() + 3) == .success) }
        #expect(try f.call("ping")["error"] == .string("limitExceeded"))
        for _ in 0..<64 { release.signal() }
        #expect(finished.wait(timeout: .now() + 3) == .success)
        #expect(try f.call("ping")["result"] == .string("pong"))
    }

    @Test func routedDeadlineKillsGitWithoutJournalingAbortedRequest() throws {
        let f = try HostCoreFixture()
        let directory = f.directory
        f.router.register("test.slowMutation", methodClass: .mutation) { _, context in
            let result = BlockingGitResult()
            Task {
                do { result.finish(.success(try await GitService().run(["-c", "alias.slow=!echo $$ > deadline-child.pid; exec /bin/sleep 30", "slow"],
                    at: directory, control: context.processControl))) }
                catch { result.finish(.failure(error)) }
            }
            _ = try result.wait().get()
            return [:]
        }
        let start = ContinuousClock.now
        #expect(try f.call("test.slowMutation", id: "deadline", timeout: 100)["error"] == .string("deadlineExceeded"))
        // Launch/reap can be delayed by concurrent test processes; the request must
        // still return close to its deadline, well before the child's 30 s sleep.
        #expect(start.duration(to: .now) < .milliseconds(100) + .seconds(5))
        if let text = try? String(contentsOf: directory.appendingPathComponent("deadline-child.pid"), encoding: .utf8),
           let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           let child = ProcessIdentity.lookup(pid: pid) {
            let reapDeadline = ContinuousClock.now + .seconds(3)
            while child.isStillRunning(), ContinuousClock.now < reapDeadline { Thread.sleep(forTimeInterval: 0.01) }
            #expect(!child.isStillRunning(), "deadline left its Git child alive")
        }
        #expect(try f.journal.entry(requestID: "deadline") == nil)
    }

    @Test func detailSurvivesRawAndTypedClient() throws {
        let clipped = try #require(HostRPCError("gitFailed", detail: "a" + String(repeating: "💥", count: 5_000)).detail)
        #expect(clipped.utf8.count <= 16_384)
        #expect(!clipped.contains("\u{fffd}"))
        let f = try HostCoreFixture()
        f.router.register("test.failure", methodClass: .read) { _, _ in throw HostRPCError("gitFailed", detail: "hook rejected") }
        let socket = f.directory.appendingPathComponent("s").path
        let server = try UnixSocketServer(path: socket) { f.service.handle($0) }; defer { server.stop() }
        let client = try HostClient(socketPath: socket); defer { client.disconnect() }
        let body = try JSONDecoder().decode([String: HostJSON].self, from: client.rawCall(method: "test.failure"))
        #expect(body["detail"] == .string("hook rejected"))
        struct Empty: Encodable {}
        #expect(throws: HostClientError.detailedHostError(code: "gitFailed", detail: "hook rejected")) {
            let _: HostAcknowledgement = try client.callWithDetail(method: "test.failure", params: Empty())
        }
    }
}

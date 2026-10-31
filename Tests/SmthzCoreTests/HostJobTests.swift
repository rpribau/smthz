import Foundation
import Darwin
import Testing
@testable import SmthzCore

struct HostJobTests {
    @Test func replayReturnsSameJobAndConflictingParamsFail() throws {
        let f = try HostCoreFixture()
        f.router.register("test.job", methodClass: .job) { [jobs = f.router.jobs] _, _ in
            ["jobId": .string(try jobs.submit { _ in .object(["answer": .number(42)]) })]
        }
        let first = try f.call("test.job", id: "same")
        #expect(try f.call("test.job", id: "same") == first)
        #expect(try f.call("test.job", ["changed": .bool(true)], id: "same")["error"] == .string("idempotencyConflict"))
        #expect(f.router.jobs.list().count == 1)
        #expect(try f.journal.read(after: 0, limit: 10).count == 1)
    }
    @Test func eventsAreBoundedAndAfterSeqFilters() throws {
        let jobs = HostJobs()
        let done = DispatchSemaphore(value: 0)
        let id = try jobs.submit { context in
            context.event("phase", "add")
            for i in 0..<1_100 { context.event("log", String(repeating: "x", count: 400) + String(i)) }
            context.event("progress", "Updating files", done: 10, total: 20)
            done.signal(); return .string("done")
        }
        #expect(done.wait(timeout: .now() + 5) == .success)
        let deadline = Date(timeIntervalSinceNow: 10)
        while try jobs.get(id)["state"] != .string("succeeded"), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        let snapshot = try jobs.get(id)
        guard case .array(let events) = snapshot["events"] else { Issue.record("missing events"); return }
        #expect(events.count <= 1_000)
        #expect(try JSONEncoder().encode(events).count <= 256 * 1_024)
        #expect(snapshot["progress"] == .object(["done": .number(10), "total": .number(20)]))
        let seq = try #require(events.last?.object?["seq"]?.number)
        #expect(try jobs.get(id, afterSeq: Int(seq))["events"] == .array([]))
    }
    @Test func cancelKillsRunningGitAndItsChild() throws {
        let f = try HostCoreFixture()
        let pidFile = f.directory.appendingPathComponent("pid")
        // Git launches a real helper shell; cancellation must kill its whole group.
        let id = try f.router.jobs.submit { context in
            let task = Task {
                try await GitService().run(["-c", "alias.slow=!echo $$ > '" + pidFile.path + "'; exec /bin/sleep 30", "slow"],
                    at: f.directory, control: context.processControl)
            }
            let result = BlockingGitResult()
            Task { do { result.finish(.success(try await task.value)) } catch { result.finish(.failure(error)) } }
            return try result.wait().map { _ in HostJSON.null }.get()
        }
        // The shell creates the file before `echo` writes it: wait for a parseable pid, not just the file.
        func readPid() -> Int32? {
            (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        let deadline = Date(timeIntervalSinceNow: 10)
        while readPid() == nil, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        let child = try #require(readPid())
        try f.router.jobs.cancel(id)
        let end = Date(timeIntervalSinceNow: 10)
        while (try f.router.jobs.get(id)["state"] != .string("cancelled") || kill(child, 0) == 0), Date() < end { Thread.sleep(forTimeInterval: 0.01) }
        #expect(try f.router.jobs.get(id)["state"] == .string("cancelled"))
        let survived = kill(child, 0) == 0
        if survived { _ = kill(child, SIGKILL) }
        #expect(!survived)
    }
    @Test func cancellingQueuedJobNeverRunsWork() throws {
        let jobs = HostJobs()
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        _ = try jobs.submit(repository: "r") { _ in started.signal(); _ = release.wait(timeout: .now() + 10); return .null }
        #expect(started.wait(timeout: .now() + 10) == .success)
        let id = try jobs.submit(repository: "r") { _ in Issue.record("cancelled job ran"); return .null }
        try jobs.cancel(id); release.signal()
        let end = Date(timeIntervalSinceNow: 10)
        while try jobs.get(id)["state"] != .string("cancelled"), Date() < end { Thread.sleep(forTimeInterval: 0.01) }
        #expect(try jobs.get(id)["state"] == .string("cancelled"))
        #expect(throws: HostRPCError("jobNotFound")) { try jobs.cancel("missing") }
        jobs.stop()
        #expect(throws: HostRPCError("hostStopping")) { try jobs.submit { _ in .null } }
    }
}

final class BlockingGitResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<GitService.Output, any Error>?
    private let ready = DispatchSemaphore(value: 0)
    func finish(_ value: Result<GitService.Output, any Error>) { lock.withLock { result = value }; ready.signal() }
    func wait() -> Result<GitService.Output, any Error> { ready.wait(); return lock.withLock { result! } }
}

import Foundation

public final class HostJobContext: @unchecked Sendable {
    public let processControl = GitProcessControl()
    private let lock = NSLock()
    private var cancelled = false
    private let emit: @Sendable (String, String, Int?, Int?) -> Void
    init(emit: @escaping @Sendable (String, String, Int?, Int?) -> Void) { self.emit = emit }
    public var isCancelled: Bool { lock.withLock { cancelled } }
    public func checkCancellation() throws { if isCancelled { throw HostRPCError("cancelled") } }
    public func event(_ kind: String = "log", _ text: String, done: Int? = nil, total: Int? = nil) {
        emit(kind, text, done, total)
    }
    func cancel() { lock.withLock { cancelled = true }; processControl.cancel() }
}

public final class HostJobs: @unchecked Sendable {
    private struct Record {
        let id: String
        let context: HostJobContext
        var state = "queued"
        var phase = "queued"
        var progress: HostJSON?
        var events: [[String: HostJSON]] = []
        var bytes = 0
        var sequence = 0
        var result: HostJSON?
        var error: String?
        var detail: String?
        var finishedAt: Date?
    }
    private let workers = DispatchGroup()
    private let lock = NSLock()
    private var records: [String: Record] = [:]
    private var stopping = false
    public let repoGate: HostRepoGate
    public init(repoGate: HostRepoGate = HostRepoGate()) { self.repoGate = repoGate }
    @discardableResult public func submit(repository: String? = nil,
        work: @escaping @Sendable (HostJobContext) throws -> HostJSON) throws -> String {
        let id = UUID().uuidString.lowercased()
        let context = HostJobContext { [weak self] kind, text, done, total in
            self?.append(id, kind: kind, text: text, done: done, total: total)
        }
        try lock.withLock {
            prune()
            guard !stopping else { throw HostRPCError("hostStopping") }
            records[id] = Record(id: id, context: context)
            workers.enter()
        }
        Thread.detachNewThread { [self] in
            defer { workers.leave() }
            do {
                let result = try repoGate.withGate(repository, cancellation: { context.isCancelled ? "cancelled" : nil }) {
                    try context.checkCancellation()
                    lock.withLock { records[id]?.state = "running" }
                    return try work(context)
                }
                finish(id, result: result, error: context.isCancelled ? HostRPCError("cancelled") : nil)
            } catch { finish(id, result: nil, error: error) }
        }
        return id
    }
    private func prune() {
        let cutoff = Date(timeIntervalSinceNow: -900)
        records = records.filter { $0.value.finishedAt.map { $0 > cutoff } ?? true }
    }
    private func append(_ id: String, kind: String, text: String, done: Int?, total: Int?) {
        lock.withLock {
            guard var r = records[id], r.finishedAt == nil else { return }
            let text = String(decoding: text.utf8.prefix(16_384), as: UTF8.self)
            r.sequence += 1
            if kind == "phase" { r.phase = text }
            if let done, let total { r.progress = .object(["done": .number(Double(done)), "total": .number(Double(total))]) }
            let event: [String: HostJSON] = ["seq": .number(Double(r.sequence)), "at": .number(Date().timeIntervalSince1970), "kind": .string(kind), "text": .string(text)]
            r.events.append(event)
            r.bytes += ((try? JSONEncoder().encode(event).count) ?? text.utf8.count) + 1
            while r.events.count > 1_000 || r.bytes > 256 * 1_024 {
                let first = r.events.removeFirst()
                r.bytes -= ((try? JSONEncoder().encode(first).count) ?? 0) + 1
            }
            records[id] = r
        }
    }
    private func finish(_ id: String, result: HostJSON?, error: (any Error)?) {
        lock.withLock {
            guard var r = records[id] else { return }
            let rpc = error.map { error -> HostRPCError in
                if let rpc = error as? HostRPCError { return rpc }
                if let git = error as? GitError {
                    switch git {
                    case .cancelled: return HostRPCError("cancelled")
                    case .authenticationRequired(let detail): return HostRPCError("authenticationRequired", detail: detail)
                    case .commandFailed(_, let detail): return HostRPCError("gitFailed", detail: detail)
                    default: break
                    }
                }
                return HostRPCError("gitFailed", detail: String(describing: error))
            }
            r.state = rpc == nil ? "succeeded" : rpc?.code == "cancelled" ? "cancelled" : "failed"
            r.result = result; r.error = rpc?.code; r.detail = rpc?.detail; r.finishedAt = Date()
            records[id] = r
        }
    }
    public func get(_ id: String, afterSeq: Int = 0) throws -> [String: HostJSON] {
        try lock.withLock {
            prune()
            guard let r = records[id] else { throw HostRPCError("jobNotFound") }
            return snapshot(r, afterSeq: afterSeq)
        }
    }
    public func list() -> [[String: HostJSON]] {
        lock.withLock { prune(); return records.values.sorted { $0.id < $1.id }.map { snapshot($0, afterSeq: Int.max) } }
    }
    private func snapshot(_ r: Record, afterSeq: Int) -> [String: HostJSON] {
        var value: [String: HostJSON] = ["jobId": .string(r.id), "state": .string(r.state), "phase": .string(r.phase),
            "events": .array(r.events.filter { ($0["seq"]?.number ?? 0) > Double(afterSeq) }.map(HostJSON.object))]
        value["progress"] = r.progress; value["result"] = r.result
        value["error"] = r.error.map(HostJSON.string); value["detail"] = r.detail.map(HostJSON.string)
        return value
    }
    public func cancel(_ id: String) throws {
        let context: HostJobContext? = try lock.withLock {
            guard let record = records[id] else { throw HostRPCError("jobNotFound") }
            return record.finishedAt == nil ? record.context : nil
        }
        context?.cancel()
    }
    public func stop() {
        let contexts = lock.withLock { stopping = true; return records.values.filter { $0.finishedAt == nil }.map(\.context) }
        contexts.forEach { $0.cancel() }
        workers.wait()
    }
}

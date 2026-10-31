import Foundation

/// JSON shared by extensible RPC handlers, domain storage helpers, and raw clients.
public enum HostJSON: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([HostJSON]), object([String: HostJSON])
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([HostJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: HostJSON].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var number: Double? { if case .number(let v) = self { return v }; return nil }
    public var object: [String: HostJSON]? { if case .object(let v) = self { return v }; return nil }
}

public struct HostRPCError: Error, Equatable, Sendable {
    public let code: String
    public let detail: String?
    public init(_ code: String, detail: String? = nil) {
        self.code = code
        self.detail = detail.map {
            var bytes = $0.utf8.prefix(16_384)
            while String(bytes: bytes, encoding: .utf8) == nil { bytes = bytes.dropLast() }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}

public enum HostMethodClass: Sendable { case read, mutation, job }
public struct HostRequestContext: Sendable {
    public let requestID: String
    public let processControl: GitProcessControl
    public let cancellationError: @Sendable () -> String?
    public func checkCancellation() throws {
        if let code = cancellationError() { throw HostRPCError(code) }
    }
}

/// Gates are shared by immediate mutations and background jobs. No host or journal
/// lock is held while waiting for a repository, or while running its Git process.
public final class HostRepoGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var busy: Set<String> = []
    public init() {}
    public func withGate<T>(_ key: String?, cancellation: @Sendable () -> String? = { nil },
                            body: () throws -> T) throws -> T {
        guard let key else { return try body() }
        condition.lock()
        while busy.contains(key) {
            if let error = cancellation() { condition.unlock(); throw HostRPCError(error) }
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.01))
        }
        if let error = cancellation() { condition.unlock(); throw HostRPCError(error) }
        busy.insert(key)
        condition.unlock()
        defer { condition.lock(); busy.remove(key); condition.broadcast(); condition.unlock() }
        return try body()
    }
}

public final class HostRouter: @unchecked Sendable {
    public typealias Handler = @Sendable ([String: HostJSON], HostRequestContext) throws -> [String: HostJSON]
    public typealias RepoKey = @Sendable ([String: HostJSON]) throws -> String?
    public struct Route: Sendable {
        public let methodClass: HostMethodClass
        public let repository: RepoKey
        public let handler: Handler
    }
    private let lock = NSLock()
    private var routes: [String: Route] = [:]
    public let repoGate: HostRepoGate
    public let jobs: HostJobs
    public init() {
        let gate = HostRepoGate()
        repoGate = gate
        jobs = HostJobs(repoGate: gate)
        register("job.get", methodClass: .read) { [jobs] p, _ in
            guard let id = p["jobId"]?.string else { throw HostRPCError("badRequest") }
            guard let after = Int(exactly: p["afterSeq"]?.number ?? 0), after >= 0 else { throw HostRPCError("badRequest") }
            return try jobs.get(id, afterSeq: after)
        }
        register("job.list", methodClass: .read) { [jobs] _, _ in ["jobs": .array(jobs.list().map(HostJSON.object))] }
        register("job.cancel", methodClass: .mutation) { [jobs] p, _ in
            guard let id = p["jobId"]?.string else { throw HostRPCError("badRequest") }
            try jobs.cancel(id)
            return [:]
        }
    }
    public func register(_ method: String, methodClass: HostMethodClass,
                         repository: @escaping RepoKey = { $0["repoId"]?.string }, handler: @escaping Handler) {
        lock.withLock { routes[method] = Route(methodClass: methodClass, repository: repository, handler: handler) }
    }
    public func route(_ method: String) -> Route? { lock.withLock { routes[method] } }
}

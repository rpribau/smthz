import CoreServices
import Foundation

/// Host-side change feed for `fs.changes` (M4-PLAN §5.2): one FSEvents stream per root, a ring
/// buffer of the last 10,000 changed root-relative paths, closed after 60 s without polling.
/// Cursors come from one process-wide counter, so a cursor from a closed watcher reads as overflow.
public final class FileWatchers: @unchecked Sendable {
    public struct Changes: Equatable, Sendable {
        public let cursor: UInt64
        public let changed: [String]
        /// The caller missed events (cursor too old, watcher restarted, or FSEvents dropped some): reload.
        public let overflow: Bool
    }

    public let capacity: Int
    public let idleTimeout: TimeInterval
    private let lock = NSLock()
    private var watchers: [String: Watcher] = [:]
    private var sequence: UInt64 = 0
    private let queue = DispatchQueue(label: "dev.smthz.fs-watch")

    public init(capacity: Int = 10_000, idleTimeout: TimeInterval = 60) {
        self.capacity = capacity
        self.idleTimeout = idleTimeout
    }

    deinit { stopAll() }

    /// Starts watching on first use. `cursor` nil (or a cursor issued before this watcher started)
    /// returns the current cursor with `overflow` set when it was non-nil.
    public func changes(root: String, cursor: UInt64?) throws -> Changes {
        try lock.withLock {
            sweep()
            let watcher: Watcher
            if let existing = watchers[root] { watcher = existing } else {
                sequence += 1
                watcher = Watcher(root: root, start: sequence, owner: self)
                guard watcher.start(queue: queue) else { throw HostRPCError("watchFailed", detail: root) }
                watchers[root] = watcher
            }
            watcher.lastPoll = Date()
            guard let cursor else { return Changes(cursor: sequence, changed: [], overflow: false) }
            if cursor < watcher.start || cursor > sequence || cursor < watcher.lostBefore || cursor < watcher.dropped {
                return Changes(cursor: sequence, changed: [], overflow: true)
            }
            var seen = Set<String>(), changed: [String] = []
            for event in watcher.events where event.seq > cursor && seen.insert(event.path).inserted {
                changed.append(event.path)
            }
            return Changes(cursor: sequence, changed: changed, overflow: false)
        }
    }

    public var watchedRoots: [String] { lock.withLock { sweep(); return watchers.keys.sorted() } }

    /// Waits for the watch queue, so no callback runs afterwards. Never called with `lock` held.
    public func stopAll() {
        let stopping = lock.withLock { () -> [Watcher] in defer { watchers = [:] }; return Array(watchers.values) }
        queue.sync { stopping.forEach { $0.stop() } }
    }

    private func sweep() {
        let cutoff = Date(timeIntervalSinceNow: -idleTimeout)
        for (root, watcher) in watchers where watcher.lastPoll < cutoff {
            watchers[root] = nil
            // On the watch queue: callbacks already queued finish first and keep the watcher alive.
            queue.async { watcher.stop() }
        }
    }

    fileprivate func record(_ watcher: Watcher, paths: [String], mustRescan: Bool) {
        lock.withLock {
            guard watchers[watcher.root] === watcher else { return }
            let prefix = watcher.root.hasSuffix("/") ? watcher.root : watcher.root + "/"
            for path in paths {
                let relative: String
                if path == watcher.root || path + "/" == prefix { relative = "" }
                else if path.hasPrefix(prefix) { relative = String(path.dropFirst(prefix.count)) }
                else if let resolved = watcher.resolvedRoot, path.hasPrefix(resolved + "/") {
                    relative = String(path.dropFirst(resolved.count + 1))
                } else { continue }
                sequence += 1
                watcher.events.append((sequence, relative))
                if watcher.events.count > capacity {
                    watcher.events.removeFirst(watcher.events.count - capacity)
                    watcher.dropped = watcher.events.first!.seq - 1
                }
            }
            if mustRescan { sequence += 1; watcher.lostBefore = sequence }
        }
    }

    fileprivate final class Watcher: @unchecked Sendable {
        let root: String
        let start: UInt64
        var resolvedRoot: String?
        weak var owner: FileWatchers?
        var events: [(seq: UInt64, path: String)] = []
        var dropped: UInt64 = 0
        var lostBefore: UInt64 = 0
        var lastPoll = Date()
        private var stream: FSEventStreamRef?

        init(root: String, start: UInt64, owner: FileWatchers) {
            self.root = root
            self.start = start
            self.owner = owner
            resolvedRoot = (try? WorkspaceStore.canonicalPath(root)).flatMap { $0 == root ? nil : $0 }
        }

        func start(queue: DispatchQueue) -> Bool {
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                               retain: nil, release: nil, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
                guard let info else { return }
                let watcher = Unmanaged<Watcher>.fromOpaque(info).takeUnretainedValue()
                let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
                var rescan = false
                for index in 0..<count {
                    let flag = Int(flags[index])
                    if flag & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                               | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged) != 0 { rescan = true }
                }
                watcher.owner?.record(watcher, paths: list, mustRescan: rescan)
            }
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                                                 | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
            guard let stream = FSEventStreamCreate(nil, callback, &context, [root] as CFArray,
                                                   FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags) else {
                return false
            }
            FSEventStreamSetDispatchQueue(stream, queue)
            guard FSEventStreamStart(stream) else { FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); return false }
            self.stream = stream
            return true
        }

        /// Stops and flushes synchronously, so no callback can run after the watcher is released.
        func stop() {
            guard let stream else { return }
            self.stream = nil
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}

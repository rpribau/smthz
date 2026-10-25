import Foundation
import Darwin

public struct ProcessIdentity: Codable, Hashable, Sendable {
    public let pid: Int32
    public let startSeconds: UInt64
    public let startMicroseconds: UInt64

    public init(pid: Int32, startSeconds: UInt64, startMicroseconds: UInt64) {
        self.pid = pid
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
    }

    public static func lookup(pid: Int32) -> ProcessIdentity? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) != size {
            return nil
        }
        return ProcessIdentity(
            pid: pid,
            startSeconds: UInt64(info.pbi_start_tvsec),
            startMicroseconds: UInt64(info.pbi_start_tvusec)
        )
    }

    public static func current() -> ProcessIdentity? {
        return lookup(pid: getpid())
    }

    public func isStillRunning() -> Bool {
        return ProcessIdentity.lookup(pid: pid) == self
    }
}

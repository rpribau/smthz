import Darwin
import Dispatch
import Foundation
import SmthzCore

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let home = getpwuid(getuid()).map { URL(fileURLWithPath: String(cString: $0.pointee.pw_dir)) }
    ?? FileManager.default.homeDirectoryForCurrentUser
var directory = ApplicationIdentity.applicationSupportDirectory(home: home)
var explicitSocket: String?
var explicitJournal: String?
let arguments = Array(CommandLine.arguments.dropFirst())
var index = 0
while index < arguments.count {
    switch arguments[index] {
    case "--version":
        print("smthzd \(ApplicationIdentity.version)")
        exit(0)
    case "--state-dir", "--socket", "--journal":
        let option = arguments[index]
        index += 1
        guard index < arguments.count, !arguments[index].isEmpty else { fail("missing value for \(option)", code: 2) }
        switch option {
        case "--state-dir": directory = URL(fileURLWithPath: arguments[index], isDirectory: true)
        case "--socket": explicitSocket = arguments[index]
        default: explicitJournal = arguments[index]
        }
    default:
        fail("unknown option: \(arguments[index])", code: 2)
    }
    index += 1
}
let socketPath = explicitSocket ?? directory.appendingPathComponent("smthzd.sock").path
let journalPath = explicitJournal ?? directory.appendingPathComponent("journal.sqlite").path

do {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                           attributes: [.posixPermissions: 0o700])
    // Keep this descriptor open until process exit. Never unlink the lock file:
    // another contender must always lock the same inode, including during stop.
    let lockPath = directory.appendingPathComponent("smthzd.lock").path
    let lockFD = Darwin.open(lockPath, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard lockFD >= 0 else { fail("smthzd: cannot open instance lock", code: 1) }
    var metadata = stat()
    guard fstat(lockFD, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
          metadata.st_uid == geteuid(), metadata.st_nlink == 1,
          fchmod(lockFD, 0o600) == 0 else { fail("smthzd: invalid instance lock", code: 1) }
    guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
        if errno == EWOULDBLOCK { fail("smthzd already running", code: 3) }
        fail("smthzd: cannot acquire instance lock", code: 1)
    }
    let journalDirectory = (journalPath as NSString).deletingLastPathComponent
    if !journalDirectory.isEmpty {
        try FileManager.default.createDirectory(atPath: journalDirectory,
                                               withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
    }
    let store = try WorkspaceStore(path: directory.appendingPathComponent("workspace.sqlite").path)
    try store.reconcileAfterRestart()
    let router = HostRouter()
    GitWriteRPC.register(on: router, store: store)
    FilesRPC.register(on: router, store: store)
    let journal = try EventJournal(path: journalPath)
    let scrollback = directory.appendingPathComponent("scrollback", isDirectory: true)
    let manager = SessionManager(journal: journal, scrollbackDirectory: scrollback,
                                 scrollbackLimit: 16 * 1_048_576)
    WorktreeRPC.register(on: router, store: store, sessions: manager)
    CleanupRPC.register(on: router, store: store, sessions: manager)
    RepoRPC.register(on: router, store: store,
                     liveSessionCWDs: { manager.list().filter(\.running).compactMap(\.cwd) })
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let service = HostService(journal: journal, hostIdentity: ProcessIdentity.current(), sessionManager: manager,
                              capabilityTokenPath: HostCapabilityToken.path(socketPath: socketPath),
                              scrollbackDirectory: scrollback, router: router, agentSocketPath: socketPath,
                              agentStateDirectory: directory, onShutdown: {
        DispatchQueue.main.async { _ = Darwin.kill(getpid(), SIGTERM) }
    })
    let server = try UnixSocketServer(path: socketPath, handler: { service.handle($0) },
                                      afterResponse: { service.responseFlushed($0) },
                                      streamHandler: { service.stream($0, send: $1, cancelled: $2) })
    let sources = [SIGINT, SIGTERM].map { number in
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler {
            service.stop()
            server.stop()
            exit(0)
        }
        source.resume()
        return source
    }
    print("smthzd listening on \(socketPath)")
    fflush(stdout)
    withExtendedLifetime((sources, lockFD)) { dispatchMain() }
} catch {
    fail("smthzd: \(error)", code: 1)
}

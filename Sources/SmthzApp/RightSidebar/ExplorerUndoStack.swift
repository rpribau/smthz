import Foundation
import SmthzCore

/// Runs one host call off the main actor on a fresh connection.
enum FilesHost {
    static func run<T: Sendable>(_ body: @escaping @Sendable (HostClient) throws -> T) async throws -> T {
        let socket = await MainActor.run { HostController.socketPath }
        return try await Task.detached(priority: .userInitiated) {
            let client = try HostClient(socketPath: socket)
            defer { client.disconnect() }
            return try body(client)
        }.value
    }

    /// Human text for a failed call (host code + detail).
    static func describe(_ error: any Error) -> String {
        switch error {
        case HostClientError.hostNotRunning: return "Host not running"
        case HostClientError.detailedHostError(let code, let detail):
            let text: String = switch code {
            case "alreadyExists": "An item with that name already exists"
            case "pathOutsideRoot": "That location is outside the workspace"
            case "notFound": "The item no longer exists"
            case "invalidPath": "That name or location is not allowed"
            case "permissionDenied": "Permission denied"
            default: code
            }
            return detail.map { "\(text) (\($0))" } ?? text
        case HostClientError.hostError(let code): return code
        default: return String(describing: error)
        }
    }
}

/// One undoable Explorer operation (Orca `fileExplorer.undo/redo`). Every case stores what it
/// needs to run in both directions; a delete is undone by restoring the Trash item.
enum ExplorerFileOperation: Equatable, Sendable {
    /// Created file or folder. Undo trashes it (`trashed` is filled in then), redo restores it.
    case create(path: String, isDirectory: Bool, trashed: String?)
    case rename(from: String, to: String)
    /// Trashed item; undo restores it to `path`.
    case trash(path: String, trashed: String)
    /// Copy, duplicate or Finder import; undo trashes the copies, redo restores them.
    case copy(paths: [String], trashed: [String])

    var label: String {
        switch self {
        case .create(let path, let dir, _): "\(dir ? "New Folder" : "New File") \((path as NSString).lastPathComponent)"
        case .rename(_, let to): "Rename to \((to as NSString).lastPathComponent)"
        case .trash(let path, _): "Delete \((path as NSString).lastPathComponent)"
        case .copy(let paths, _): paths.count == 1 ? "Copy \((paths[0] as NSString).lastPathComponent)" : "Copy \(paths.count) items"
        }
    }
}

/// Last 50 Explorer operations per root, undone/redone through the host (`fs.*`).
@MainActor @Observable
final class ExplorerUndoStack {
    static let limit = 50
    private(set) var undoItems: [ExplorerFileOperation] = []
    private(set) var redoItems: [ExplorerFileOperation] = []
    private(set) var root: String?

    var canUndo: Bool { !undoItems.isEmpty }
    var canRedo: Bool { !redoItems.isEmpty }

    func reset(root: String?) {
        guard root != self.root else { return }
        self.root = root; undoItems = []; redoItems = []
    }

    func record(_ op: ExplorerFileOperation) {
        undoItems.append(op)
        if undoItems.count > Self.limit { undoItems.removeFirst(undoItems.count - Self.limit) }
        redoItems = []
    }

    /// Returns the undone operation, or throws the host failure (the stack is left unchanged then).
    func undo() async throws -> ExplorerFileOperation? {
        guard let root, let op = undoItems.last else { return nil }
        let inverse = try await Self.revert(op, root: root)
        undoItems.removeLast()
        redoItems.append(inverse)
        return op
    }

    func redo() async throws -> ExplorerFileOperation? {
        guard let root, let op = redoItems.last else { return nil }
        let replayed = try await Self.replay(op, root: root)
        redoItems.removeLast()
        undoItems.append(replayed)
        return op
    }

    /// Undo; returns the operation to keep on the redo stack (with new Trash locations).
    private static func revert(_ op: ExplorerFileOperation, root: String) async throws -> ExplorerFileOperation {
        try await FilesHost.run { client in
            switch op {
            case .create(let path, let dir, _):
                return .create(path: path, isDirectory: dir, trashed: try client.fsTrash(root: root, path: path))
            case .rename(let from, let to):
                try client.fsRename(root: root, from: to, to: from)
                return op
            case .trash(let path, let trashed):
                try client.fsRestore(root: root, trashedPath: trashed, to: path)
                return op
            case .copy(let paths, _):
                return .copy(paths: paths, trashed: try paths.reversed().map { try client.fsTrash(root: root, path: $0) }.reversed())
            }
        }
    }

    /// Redo; returns the operation to put back on the undo stack.
    private static func replay(_ op: ExplorerFileOperation, root: String) async throws -> ExplorerFileOperation {
        try await FilesHost.run { client in
            switch op {
            case .create(let path, let dir, let trashed):
                if let trashed { try client.fsRestore(root: root, trashedPath: trashed, to: path) }
                else if dir { try client.fsCreateDirectory(root: root, path: path) }
                else { try client.fsCreateFile(root: root, path: path) }
                return .create(path: path, isDirectory: dir, trashed: nil)
            case .rename(let from, let to):
                try client.fsRename(root: root, from: from, to: to)
                return op
            case .trash(let path, _):
                return .trash(path: path, trashed: try client.fsTrash(root: root, path: path))
            case .copy(let paths, let trashed):
                for (path, item) in zip(paths, trashed) { try client.fsRestore(root: root, trashedPath: item, to: path) }
                return .copy(paths: paths, trashed: [])
            }
        }
    }
}

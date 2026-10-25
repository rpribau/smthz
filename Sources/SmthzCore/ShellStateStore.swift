import Foundation
import CoreGraphics
import Darwin

public struct ShellLoadReport: Equatable, Sendable {
    public var salvaged: [String]
    public var backupPath: String?
    public init(salvaged: [String] = [], backupPath: String? = nil) {
        self.salvaged = salvaged
        self.backupPath = backupPath
    }
}

public enum ShellStateStore {
    public static let currentVersion = 1

    /// Loading never starts processes or discards healthy siblings of a malformed record.
    public static func load(from url: URL) -> (ShellState, ShellLoadReport) {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch {
            if (error as NSError).domain == NSCocoaErrorDomain,
               (error as NSError).code == NSFileReadNoSuchFileError { return (.empty, .init()) }
            return (.empty, .init(salvaged: ["Unable to read state: \(error)"]))
        }
        struct Header: Decodable { let version: Int }
        let decoder = JSONDecoder()
        do {
            let header = try decoder.decode(Header.self, from: data)
            if header.version > currentVersion { return backup(url, kind: "future") }
            guard header.version == currentVersion else { return backup(url, kind: "corrupt") }
            let diagnostics = StoreDiagnostics()
            decoder.userInfo[StoreDiagnostics.key] = diagnostics
            let decoded = try decoder.decode(StoredShell.self, from: data).state
            let repaired = decoded.repaired()
            diagnostics.messages += decoded.violations()
            if decoded != repaired && diagnostics.messages.isEmpty {
                diagnostics.messages.append("Repaired shell state")
            }
            return (repaired, .init(salvaged: diagnostics.messages))
        } catch { return backup(url, kind: "corrupt") }
    }

    private static func backup(_ url: URL, kind: String) -> (ShellState, ShellLoadReport) {
        let suffix = "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.lowercased())"
        let destination = url.appendingPathExtension("\(kind)-\(suffix)")
        do {
            try FileManager.default.moveItem(at: url, to: destination)
            return (.empty, .init(backupPath: destination.path))
        } catch {
            return (.empty, .init(salvaged: ["Unable to back up \(kind) state: \(error)"]))
        }
    }

    /// A same-directory, exclusive 0600 temp file is synced before atomic replacement.
    /// Callers serialize saves and debounce them; termination can call this synchronously.
    public static func save(_ state: ShellState, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixError() }
        defer { close(fd); unlink(temporary.path) }
        guard fchmod(fd, 0o600) == 0 else { throw posixError() }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw posixError() }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw posixError() }
        guard rename(temporary.path, url.path) == 0 else { throw posixError() }
        let directoryFD = open(directory.path, O_RDONLY | O_CLOEXEC)
        guard directoryFD >= 0 else { throw posixError() }
        defer { close(directoryFD) }
        guard fsync(directoryFD) == 0 else { throw posixError() }
    }

    private static func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}

public enum FrameValidation {
    public static func isUsable(_ frame: CGRect, screens: [CGRect],
                                minimumVisible: CGSize = .init(width: 100, height: 50)) -> Bool {
        func finite(_ rect: CGRect) -> Bool {
            // CGRect.infinite uses finite sentinel components, so check it explicitly.
            !rect.isInfinite
                && [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height].allSatisfy(\.isFinite)
                && rect.size.width > 0 && rect.size.height > 0
                && rect.size.width <= 1_000_000 && rect.size.height <= 1_000_000
        }
        guard finite(frame), minimumVisible.width.isFinite, minimumVisible.height.isFinite,
              minimumVisible.width > 0, minimumVisible.height > 0 else { return false }
        return screens.contains { screen in
            guard finite(screen) else { return false }
            let visible = frame.intersection(screen)
            return !visible.isNull && visible.width >= minimumVisible.width && visible.height >= minimumVisible.height
        }
    }
}

private final class StoreDiagnostics {
    static let key = CodingUserInfoKey(rawValue: "ShellStateStore.diagnostics")!
    var messages: [String] = []
}
private func recordDrop(_ decoder: any Decoder, _ detail: String) {
    let path = decoder.codingPath.map(\.stringValue).joined(separator: ".")
    (decoder.userInfo[StoreDiagnostics.key] as? StoreDiagnostics)?.messages.append("\(path): \(detail)")
}

/// ShellStringID dictionary keys encode as alternating key/value arrays with Swift Codable.
private struct StoredMap<Key: ShellStringID, Value: Decodable>: Decodable {
    var values: [Key: Value] = [:]
    init(from decoder: any Decoder) throws {
        var items = try decoder.unkeyedContainer()
        while !items.isAtEnd {
            let keyDecoder = try items.superDecoder()
            guard !items.isAtEnd else { recordDrop(keyDecoder, "dictionary key has no value"); break }
            let valueDecoder = try items.superDecoder()
            do {
                let key = try Key(from: keyDecoder)
                do { values[key] = try Value(from: valueDecoder) }
                catch { recordDrop(valueDecoder, "dropped \(key.rawValue): \(error)") }
            } catch { recordDrop(keyDecoder, "dropped invalid key: \(error)") }
        }
    }
}
private struct StoredArray<Value: Decodable>: Decodable {
    var values: [Value] = []
    init(from decoder: any Decoder) throws {
        var items = try decoder.unkeyedContainer()
        while !items.isAtEnd {
            let item = try items.superDecoder()
            do { values.append(try Value(from: item)) }
            catch { recordDrop(item, "dropped record: \(error)") }
        }
    }
}
private enum StoreKey: String, CodingKey {
    case version, workspaces, windows, workspaceOrder, lastVisited
    case key, displayName, rootPath, tabs, groups, groupLayout, activeGroup, panes, recentlyClosed, nextDefaultTitleNumber
}
private extension KeyedDecodingContainer where Key == StoreKey {
    func optional<T: Decodable>(_ type: T.Type, _ key: StoreKey, decoder: any Decoder) -> T? {
        do { return try decodeIfPresent(type, forKey: key) }
        catch { recordDrop(decoder, "repaired \(key.rawValue): \(error)"); return nil }
    }
    func salvage<T: Decodable>(_ type: T.Type, _ key: StoreKey, default fallback: T,
                               decoder: any Decoder) -> T {
        do { return try decode(type, forKey: key) }
        catch { recordDrop(decoder, "repaired \(key.rawValue): \(error)"); return fallback }
    }
}
private struct StoredWorkspace: Decodable {
    var workspace: WorkspaceLayout
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: StoreKey.self)
        workspace = WorkspaceLayout(key: try c.decode(WorkspaceKey.self, forKey: .key),
                                    displayName: try c.decode(String.self, forKey: .displayName))
        workspace.rootPath = c.optional(String.self, .rootPath, decoder: decoder)
        workspace.tabs = c.salvage(StoredMap<TabID, TerminalTabRecord>.self, .tabs,
                                  default: .init(values: [:]), decoder: decoder).values
        workspace.groups = c.salvage(StoredMap<GroupID, TabGroup>.self, .groups,
                                    default: .init(values: [:]), decoder: decoder).values
        workspace.panes = c.salvage(StoredMap<PaneID, PaneRecord>.self, .panes,
                                   default: .init(values: [:]), decoder: decoder).values
        workspace.groupLayout = c.optional(LayoutNode<GroupID>.self, .groupLayout, decoder: decoder)
        workspace.activeGroup = c.optional(GroupID.self, .activeGroup, decoder: decoder)
        workspace.recentlyClosed = c.salvage(StoredArray<ClosedTabSnapshot>.self, .recentlyClosed,
                                            default: .init(values: []), decoder: decoder).values
        workspace.nextDefaultTitleNumber = c.salvage(Int.self, .nextDefaultTitleNumber, default: 1, decoder: decoder)
    }
}
private struct StoredShell: Decodable {
    var state: ShellState
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: StoreKey.self)
        state = ShellState(version: try c.decode(Int.self, forKey: .version))
        state.workspaces = try c.decode(StoredMap<WorkspaceKey, StoredWorkspace>.self, forKey: .workspaces)
            .values.mapValues(\.workspace)
        state.windows = c.salvage(StoredArray<WindowState>.self, .windows,
                                 default: .init(values: []), decoder: decoder).values
        state.workspaceOrder = c.salvage([WorkspaceKey].self, .workspaceOrder, default: [], decoder: decoder)
        state.lastVisited = c.salvage(StoredMap<WorkspaceKey, Date>.self, .lastVisited,
                                     default: .init(values: [:]), decoder: decoder).values
    }
}

private extension StoredMap {
    init(values: [Key: Value]) { self.values = values }
}
private extension StoredArray {
    init(values: [Value]) { self.values = values }
}

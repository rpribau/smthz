import Foundation
import Darwin

public enum BrowserProfileKind: String, Codable, Sendable {
    case `default`, isolated, imported
}

/// Where a profile's cookies came from (Orca `BrowserSessionProfileSource`).
public struct BrowserProfileSourceInfo: Codable, Equatable, Sendable {
    public var browser: BrowserCookieSource
    public var profileName: String?
    public var importedAt: Date

    public init(browser: BrowserCookieSource, profileName: String? = nil, importedAt: Date) {
        self.browser = browser; self.profileName = profileName; self.importedAt = importedAt
    }
}

public struct BrowserProfile: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var scope: BrowserProfileKind
    /// Passed to `WKWebsiteDataStore(forIdentifier:)` by the app.
    public var dataStoreIdentifier: UUID
    public var source: BrowserProfileSourceInfo?
    public var createdAt: Date
    /// Deleted while views were still using its data store; removed when the last one closes.
    public var pendingDeletion: Bool
}

public enum BrowserProfileDeletion: Equatable, Sendable {
    /// The app must now call `WKWebsiteDataStore.remove(forIdentifier:)` and then `markDataStoreRemoved`.
    case removed(dataStoreIdentifier: UUID)
    /// Views are open; the store reports the removal from the last `detach`.
    case deferred
}

public enum BrowserProfileStoreError: Error, Equatable, Sendable {
    case notFound(String)
    case invalidLabel
    case invalidScope
    case builtInProfile
    case pendingDeletion(String)
    case saveFailed(String)
}

/// Registry of browser profiles persisted as `<state-dir>/browser-profiles.json` (0600).
/// WebKit data stores cannot be removed while any web view or store reference uses them
/// ("Data store is in use"), so deletion is deferred until every attached view detaches, and
/// removals that the app has not confirmed survive restarts in `pendingDataStoreRemovals`.
public final class BrowserProfileStore: @unchecked Sendable {
    public static let builtInID = "default"
    public static let fileName = "browser-profiles.json"
    public static let currentVersion = 1

    struct Stored: Codable, Equatable {
        var version: Int
        var defaultProfileID: String
        var profiles: [BrowserProfile]
        var pendingDataStoreRemovals: [UUID]
    }

    public let url: URL
    /// Messages from loading (backed-up corrupt or future files).
    public let loadReport: [String]
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var state: Stored
    private var attachments: [String: Int] = [:]

    public init(stateDirectory: URL, now: @escaping @Sendable () -> Date = Date.init) {
        url = stateDirectory.appendingPathComponent(Self.fileName)
        self.now = now
        var report: [String] = []
        var loaded = Self.load(url, report: &report) ?? Stored(version: Self.currentVersion,
                                                               defaultProfileID: Self.builtInID,
                                                               profiles: [], pendingDataStoreRemovals: [])
        let before = loaded
        // A new process has no views, so profiles deleted in an earlier run can be finalized now.
        for profile in loaded.profiles where profile.pendingDeletion {
            loaded.pendingDataStoreRemovals.append(profile.dataStoreIdentifier)
        }
        loaded.profiles.removeAll(where: \.pendingDeletion)
        if !loaded.profiles.contains(where: { $0.id == Self.builtInID }) {
            loaded.profiles.insert(BrowserProfile(id: Self.builtInID, label: "Default", scope: .default,
                                                  dataStoreIdentifier: UUID(), source: nil, createdAt: now(),
                                                  pendingDeletion: false), at: 0)
        }
        if !loaded.profiles.contains(where: { $0.id == loaded.defaultProfileID }) {
            loaded.defaultProfileID = Self.builtInID
        }
        state = loaded
        if loaded != before {
            do { try Self.save(loaded, to: url) } catch { report.append("Unable to save browser profiles: \(error)") }
        }
        loadReport = report
    }

    // MARK: Queries

    public var profiles: [BrowserProfile] { lock.withLock { state.profiles.filter { !$0.pendingDeletion } } }

    public func profile(id: String) -> BrowserProfile? {
        lock.withLock { state.profiles.first { $0.id == id && !$0.pendingDeletion } }
    }

    public var defaultProfile: BrowserProfile {
        lock.withLock { state.profiles.first { $0.id == state.defaultProfileID }! }
    }

    /// Data stores deleted from the registry whose removal the app has not confirmed yet.
    public var pendingDataStoreRemovals: [UUID] { lock.withLock { state.pendingDataStoreRemovals } }

    public func attachedViewCount(id: String) -> Int { lock.withLock { attachments[id, default: 0] } }

    // MARK: Mutations

    @discardableResult
    public func create(label: String, scope: BrowserProfileKind = .isolated) throws -> BrowserProfile {
        let label = try Self.validated(label)
        guard scope != .default else { throw BrowserProfileStoreError.invalidScope }
        let profile = BrowserProfile(id: UUID().uuidString.lowercased(), label: label, scope: scope,
                                     dataStoreIdentifier: UUID(), source: nil, createdAt: now(), pendingDeletion: false)
        try mutate { $0.profiles.append(profile) }
        return profile
    }

    public func rename(id: String, label: String) throws {
        let label = try Self.validated(label)
        try mutate { state in state.profiles[try Self.index(of: id, in: state)].label = label }
    }

    public func updateSource(id: String, source: BrowserProfileSourceInfo?) throws {
        try mutate { state in state.profiles[try Self.index(of: id, in: state)].source = source }
    }

    public func setDefault(id: String) throws {
        try mutate { state in
            _ = try Self.index(of: id, in: state)
            state.defaultProfileID = id
        }
    }

    /// Orca `tab profile use-default`: back to the built-in profile.
    public func resetDefault() throws { try setDefault(id: Self.builtInID) }

    /// The built-in profile cannot be deleted. Deleting the default profile resets the default.
    public func delete(id: String) throws -> BrowserProfileDeletion {
        guard id != Self.builtInID else { throw BrowserProfileStoreError.builtInProfile }
        return try lock.withLock {
            var next = state
            let index = try Self.index(of: id, in: next)
            if next.defaultProfileID == id { next.defaultProfileID = Self.builtInID }
            let result: BrowserProfileDeletion
            if attachments[id, default: 0] > 0 {
                next.profiles[index].pendingDeletion = true
                result = .deferred
            } else {
                let identifier = next.profiles.remove(at: index).dataStoreIdentifier
                next.pendingDataStoreRemovals.append(identifier)
                result = .removed(dataStoreIdentifier: identifier)
            }
            try commit(next)
            return result
        }
    }

    /// A view starts using the profile's data store. Fails for unknown or deleted profiles.
    public func attach(id: String) throws -> BrowserProfile {
        try lock.withLock {
            let index = try Self.index(of: id, in: state)
            attachments[id, default: 0] += 1
            return state.profiles[index]
        }
    }

    /// A view released its data store. Returns the identifier to remove when this was the last
    /// view of a profile deleted meanwhile.
    @discardableResult
    public func detach(id: String) throws -> UUID? {
        try lock.withLock {
            let count = attachments[id, default: 0]
            guard count > 0 else { return nil }
            if count > 1 { attachments[id] = count - 1; return nil }
            attachments[id] = nil
            guard let index = state.profiles.firstIndex(where: { $0.id == id }), state.profiles[index].pendingDeletion
            else { return nil }
            var next = state
            let identifier = next.profiles.remove(at: index).dataStoreIdentifier
            next.pendingDataStoreRemovals.append(identifier)
            try commit(next)
            return identifier
        }
    }

    /// The app confirms `WKWebsiteDataStore.remove(forIdentifier:)` succeeded.
    public func markDataStoreRemoved(_ identifier: UUID) throws {
        try mutate { $0.pendingDataStoreRemovals.removeAll { $0 == identifier } }
    }

    // MARK: Persistence

    private func mutate(_ change: (inout Stored) throws -> Void) throws {
        try lock.withLock {
            var next = state
            try change(&next)
            try commit(next)
        }
    }

    /// Caller holds the lock. Memory changes only after the file is written.
    private func commit(_ next: Stored) throws {
        guard next != state else { return }
        do { try Self.save(next, to: url) } catch { throw BrowserProfileStoreError.saveFailed("\(error)") }
        state = next
    }

    private static func index(of id: String, in state: Stored) throws -> Int {
        guard let index = state.profiles.firstIndex(where: { $0.id == id }) else {
            throw BrowserProfileStoreError.notFound(id)
        }
        guard !state.profiles[index].pendingDeletion else { throw BrowserProfileStoreError.pendingDeletion(id) }
        return index
    }

    private static func validated(_ label: String) throws -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 128 else { throw BrowserProfileStoreError.invalidLabel }
        return trimmed
    }

    private static func load(_ url: URL, report: inout [String]) -> Stored? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        struct Header: Decodable { let version: Int }
        let kind: String
        if let header = try? decoder.decode(Header.self, from: data) {
            if header.version == currentVersion, let stored = try? decoder.decode(Stored.self, from: data) {
                return stored
            }
            kind = header.version > currentVersion ? "future" : "corrupt"
        } else {
            kind = "corrupt"
        }
        let backup = url.appendingPathExtension("\(kind)-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))")
        do {
            try FileManager.default.moveItem(at: url, to: backup)
            report.append("Backed up \(kind) browser profiles to \(backup.path)")
        } catch {
            report.append("Unable to back up \(kind) browser profiles: \(error)")
        }
        return nil
    }

    static func save(_ stored: Stored, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(stored)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw BrowserProfileStoreError.saveFailed("cannot write \(temporary.path)")
        }
        guard Darwin.rename(temporary.path, url.path) == 0 else {
            let code = errno
            unlink(temporary.path)
            throw BrowserProfileStoreError.saveFailed(String(cString: strerror(code)))
        }
    }
}

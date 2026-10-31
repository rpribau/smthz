import Foundation
import SQLite3

// MARK: - Shared import model (used by the Chromium, Firefox and Safari importers)

public enum BrowserCookieSource: String, Codable, Sendable, CaseIterable {
    case chrome, edge, arc, brave, comet, helium, firefox, safari, manual
}

public enum BrowserCookieSameSite: String, Codable, Sendable {
    case unspecified, noRestriction, lax, strict

    /// Chromium's net::CookieSameSite (-1 unspecified, 0 None, 1 Lax, 2 Strict). Firefox overlaps on
    /// 1/2 but writes 256 or 0 for unset rows, so every other value stays unspecified (Orca `databaseSameSite`).
    public static func fromDatabase(_ raw: Int64?) -> BrowserCookieSameSite {
        switch raw {
        case 0: .noRestriction
        case 1: .lax
        case 2: .strict
        default: .unspecified
        }
    }
}

public struct BrowserImportedCookie: Equatable, Sendable {
    public var name: String
    public var value: String
    /// As stored by the source: a leading dot marks a domain cookie, none a host-only cookie.
    public var domain: String
    public var path: String
    public var secure: Bool
    public var httpOnly: Bool
    public var sameSite: BrowserCookieSameSite
    /// nil for a session cookie.
    public var expires: Date?

    public init(name: String, value: String, domain: String, path: String = "/", secure: Bool = false,
                httpOnly: Bool = false, sameSite: BrowserCookieSameSite = .unspecified, expires: Date? = nil) {
        self.name = name; self.value = value; self.domain = domain; self.path = path
        self.secure = secure; self.httpOnly = httpOnly; self.sameSite = sameSite; self.expires = expires
    }

    /// The value handed to `WKHTTPCookieStore.setCookie` by the app; nil when Foundation rejects it.
    public var httpCookie: HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: value, .domain: domain, .path: path.isEmpty ? "/" : path
        ]
        if secure { properties[.secure] = "TRUE" }
        if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if let expires { properties[.expires] = expires }
        switch sameSite {
        case .lax: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax.rawValue
        case .strict: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict.rawValue
        case .noRestriction, .unspecified: break
        }
        return HTTPCookie(properties: properties)
    }
}

public struct BrowserCookieImportResult: Equatable, Sendable {
    public var source: BrowserCookieSource
    public var cookies: [BrowserImportedCookie]
    public var totalCookies: Int
    public var skippedCookies: Int
    public var googleCookiesSkipped: Int
    public var expiredSkipped: Int
    /// Rows whose value could not be decrypted (subset of `skippedCookies`).
    public var decryptFailed: Int
    /// Rows with Chromium's app-bound "v20" prefix (subset of `decryptFailed`).
    public var appBoundFailed: Int
    public var keyUnavailable: Bool

    public var importedCookies: Int { cookies.count }
    public var domains: [String] {
        Array(Set(cookies.compactMap { BrowserCookieImportPolicy.normalizeDomain($0.domain) })).sorted()
    }
    public var httpCookies: [HTTPCookie] { cookies.compactMap(\.httpCookie) }
}

public enum BrowserCookieImportError: Error, Equatable, Sendable {
    case notFound(path: String)
    /// Safari's container needs Full Disk Access (System Settings > Privacy & Security).
    case permissionDenied(path: String)
    case copyFailed(String)
    case unreadable(String)
    case keyUnavailable(service: String, status: OSStatus)
    case noCookies
}

public enum BrowserCookieImportPolicy {
    /// Registrable domains whose sessions are device-bound server-side (Orca `NON_TRANSPLANTABLE_DOMAINS`):
    /// an import never writes them because the site rejects the transplanted session.
    public static let nonTransplantableDomains = ["google.com"]

    public static func normalizeDomain(_ domain: String) -> String? {
        var host = domain.trimmingCharacters(in: .whitespaces).lowercased()
        while host.hasPrefix(".") { host.removeFirst() }
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, host.count <= 253,
              host.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-._".unicodeScalars.contains($0) }),
              !host.contains("..") else { return nil }
        // Why: a single-label domain other than localhost is a public suffix or junk, not a site.
        guard host.contains(".") || host == "localhost" else { return nil }
        return host
    }

    public static func isNonTransplantable(domain: String) -> Bool {
        guard let host = normalizeDomain(domain) else { return false }
        return nonTransplantableDomains.contains { host == $0 || host.hasSuffix(".\($0)") }
    }
}

/// Applies the filters every importer shares and keeps the counters.
struct BrowserCookieImportAccumulator {
    var result: BrowserCookieImportResult
    let now: Date

    init(source: BrowserCookieSource, now: Date) {
        result = BrowserCookieImportResult(source: source, cookies: [], totalCookies: 0, skippedCookies: 0,
                                           googleCookiesSkipped: 0, expiredSkipped: 0, decryptFailed: 0,
                                           appBoundFailed: 0, keyUnavailable: false)
        self.now = now
    }

    /// Call once per source row before decrypting; false means the row is already counted as skipped.
    mutating func admit(name: String, domain: String) -> Bool {
        result.totalCookies += 1
        if BrowserCookieImportPolicy.isNonTransplantable(domain: domain) {
            result.googleCookiesSkipped += 1
            result.skippedCookies += 1
            return false
        }
        guard !name.isEmpty, BrowserCookieImportPolicy.normalizeDomain(domain) != nil else {
            result.skippedCookies += 1
            return false
        }
        return true
    }

    mutating func decryptFailure(appBound: Bool) {
        result.decryptFailed += 1
        if appBound { result.appBoundFailed += 1 }
        result.skippedCookies += 1
    }

    mutating func append(_ cookie: BrowserImportedCookie) {
        if let expires = cookie.expires, expires <= now {
            result.expiredSkipped += 1
            result.skippedCookies += 1
            return
        }
        result.cookies.append(cookie)
    }
}

/// One profile of an installed browser, ready to import from.
public struct BrowserSourceProfile: Equatable, Sendable {
    public var source: BrowserCookieSource
    public var name: String
    public var directory: String
    public var cookiesPath: String
}

/// Cookie values are raw bytes; prefer UTF-8 and keep 0x00-0xFF intact via Latin-1 otherwise.
func cookieString(_ bytes: Data) -> String {
    String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .isoLatin1) ?? ""
}

// MARK: - Database snapshot

enum SQLiteCell: Equatable {
    case integer(Int64), text(String), blob(Data), null

    var int: Int64? {
        switch self {
        case .integer(let v): v
        case .text(let s): Int64(s)
        default: nil
        }
    }
    var string: String? {
        switch self {
        case .text(let s): s
        case .blob(let d): cookieString(d)
        case .integer(let v): String(v)
        case .null: nil
        }
    }
    var data: Data? {
        switch self {
        case .blob(let d): d
        case .text(let s): Data(s.utf8)
        default: nil
        }
    }
}

/// Browsers keep their cookie DB locked and in WAL mode, so readers work on a private copy
/// (DB plus -wal/-shm sidecars) that is deleted afterwards. The source file is never opened.
final class BrowserCookieDatabaseSnapshot {
    let directory: URL
    private var db: OpaquePointer?

    init(copying source: URL, fileName: String) throws {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw BrowserCookieImportError.notFound(path: source.path)
        }
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("smthz-ck-\(UUID().uuidString.prefix(8).lowercased())")
        let target = directory.appendingPathComponent(fileName)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.copyItem(at: source, to: target)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            if isPermissionError(error) { throw BrowserCookieImportError.permissionDenied(path: source.path) }
            throw BrowserCookieImportError.copyFailed(source.path)
        }
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: source.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) {
                try? FileManager.default.copyItem(at: sidecar, to: URL(fileURLWithPath: target.path + suffix))
            }
        }
        guard sqlite3_open_v2(target.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            db = nil
            try? FileManager.default.removeItem(at: directory)
            throw BrowserCookieImportError.unreadable(source.path)
        }
    }

    deinit {
        sqlite3_close(db)
        try? FileManager.default.removeItem(at: directory)
    }

    func columns(of table: String) throws -> Set<String> {
        Set(try rows("PRAGMA table_info(\(table))").compactMap { $0["name"]?.string })
    }

    func rows(_ sql: String) throws -> [[String: SQLiteCell]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            throw BrowserCookieImportError.unreadable(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        var result: [[String: SQLiteCell]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw BrowserCookieImportError.unreadable(String(cString: sqlite3_errmsg(db))) }
            var row: [String: SQLiteCell] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER: row[name] = .integer(sqlite3_column_int64(statement, index))
                case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(statement, index)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, index))
                    if let bytes = sqlite3_column_blob(statement, index), count > 0 {
                        row[name] = .blob(Data(bytes: bytes, count: count))
                    } else {
                        row[name] = .blob(Data())
                    }
                case SQLITE_FLOAT: row[name] = .integer(Int64(sqlite3_column_double(statement, index)))
                default: row[name] = .null
                }
            }
            result.append(row)
        }
        return result
    }
}

func isPermissionError(_ error: Error) -> Bool {
    let ns = error as NSError
    if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoPermissionError { return true }
    if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
        return underlying.code == Int(EPERM) || underlying.code == Int(EACCES)
    }
    return ns.domain == NSPOSIXErrorDomain && (ns.code == Int(EPERM) || ns.code == Int(EACCES))
}

// MARK: - Chromium browsers (Chrome, Edge, Arc, Brave, Comet, Helium)

public struct ChromiumBrowser: Equatable, Sendable {
    public var source: BrowserCookieSource
    public var label: String
    public var keychainService: String
    public var keychainAccount: String
    /// Relative to ~/Library/Application Support.
    public var macRoot: String

    /// Orca `CHROMIUM_BROWSERS` (macOS roots only).
    public static let all: [ChromiumBrowser] = [
        .init(source: .chrome, label: "Google Chrome", keychainService: "Chrome Safe Storage",
              keychainAccount: "Chrome", macRoot: "Google/Chrome"),
        .init(source: .edge, label: "Microsoft Edge", keychainService: "Microsoft Edge Safe Storage",
              keychainAccount: "Microsoft Edge", macRoot: "Microsoft Edge"),
        .init(source: .arc, label: "Arc", keychainService: "Arc Safe Storage", keychainAccount: "Arc",
              macRoot: "Arc/User Data"),
        .init(source: .brave, label: "Brave", keychainService: "Brave Safe Storage", keychainAccount: "Brave",
              macRoot: "BraveSoftware/Brave-Browser"),
        .init(source: .comet, label: "Comet", keychainService: "Comet Safe Storage", keychainAccount: "Comet",
              macRoot: "Comet"),
        // Why (Orca): Helium's Keychain service breaks the "<Browser> Safe Storage" convention.
        .init(source: .helium, label: "Helium", keychainService: "Helium Storage Key", keychainAccount: "Helium",
              macRoot: "net.imput.helium")
    ]

    public static func browser(for source: BrowserCookieSource) -> ChromiumBrowser? {
        all.first { $0.source == source }
    }

    public func root(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support").appendingPathComponent(macRoot)
    }
}

public enum BrowserCookieImportChrome {
    /// Profile directories become path segments, so Local State's keys must be plain names.
    public static func isSafeProfileDirectory(_ directory: String) -> Bool {
        !directory.isEmpty && directory != "." && !directory.contains("\0") && !directory.contains("/")
            && !directory.contains("\\") && !directory.contains("..")
    }

    /// Chromium 96+ keeps the DB under Network/, older profiles at the profile root.
    public static func cookiesPath(profileDirectory: URL) -> URL? {
        let network = profileDirectory.appendingPathComponent("Network/Cookies")
        if FileManager.default.fileExists(atPath: network.path) { return network }
        let legacy = profileDirectory.appendingPathComponent("Cookies")
        return FileManager.default.fileExists(atPath: legacy.path) ? legacy : nil
    }

    /// (display name, directory) pairs from Local State's profile.info_cache; "Default" when absent.
    public static func profileEntries(root: URL) -> [(name: String, directory: String)] {
        let fallback = [(name: "Default", directory: "Default")]
        guard let data = try? Data(contentsOf: root.appendingPathComponent("Local State")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cache = (json["profile"] as? [String: Any])?["info_cache"] as? [String: Any] else { return fallback }
        let entries = cache.keys.sorted().filter(isSafeProfileDirectory).map { directory in
            (name: ((cache[directory] as? [String: Any])?["name"] as? String) ?? directory, directory: directory)
        }
        return entries.isEmpty ? fallback : entries
    }

    /// Profiles of one browser that actually have a cookie DB.
    public static func discoverProfiles(_ browser: ChromiumBrowser,
                                        home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [BrowserSourceProfile] {
        let root = browser.root(home: home)
        return profileEntries(root: root).compactMap { entry in
            guard let path = cookiesPath(profileDirectory: root.appendingPathComponent(entry.directory)) else { return nil }
            return BrowserSourceProfile(source: browser.source, name: entry.name, directory: entry.directory,
                                        cookiesPath: path.path)
        }
    }

    /// Reads a copy of a Chromium `Cookies` DB. The Keychain password is fetched only when an
    /// encrypted row exists; if it is unavailable those rows count as `decryptFailed`.
    public static func importCookies(from database: URL, browser: ChromiumBrowser,
                                     keyProvider: ChromiumKeyProvider,
                                     now: Date = Date()) throws -> BrowserCookieImportResult {
        let snapshot = try BrowserCookieDatabaseSnapshot(copying: database, fileName: "Cookies")
        let columns = try snapshot.columns(of: "cookies")
        for required in ["host_key", "name", "path", "expires_utc"] where !columns.contains(required) {
            throw BrowserCookieImportError.unreadable("cookies table lacks \(required)")
        }
        let optional = ["value", "encrypted_value", "is_secure", "is_httponly", "samesite"].filter(columns.contains)
        let rows = try snapshot.rows("SELECT host_key, name, path, expires_utc"
                                     + optional.map { ", \($0)" }.joined() + " FROM cookies")
        var accumulator = BrowserCookieImportAccumulator(source: browser.source, now: now)
        var key: Data?
        var keyFetched = false
        for row in rows {
            let domain = row["host_key"]?.string ?? ""
            let name = row["name"]?.string ?? ""
            guard accumulator.admit(name: name, domain: domain) else { continue }
            let value: String
            if let blob = row["encrypted_value"]?.data, !blob.isEmpty {
                let version = ChromiumCookieCrypto.encryptionVersion(blob)
                if !keyFetched, version == "v10" || version == "v11" {
                    keyFetched = true
                    key = (try? keyProvider.password(service: browser.keychainService, account: browser.keychainAccount))
                        .flatMap { ChromiumCookieCrypto.deriveKey(password: $0) }
                    accumulator.result.keyUnavailable = key == nil
                }
                guard let key, let plain = ChromiumCookieCrypto.decrypt(blob, key: key, hostKey: domain) else {
                    accumulator.decryptFailure(appBound: version == "v20")
                    continue
                }
                value = cookieString(plain)
            } else {
                value = row["value"]?.string ?? ""
            }
            let expires = ChromiumCookieCrypto.unixTime(fromChromium: row["expires_utc"]?.int ?? 0)
                .map { Date(timeIntervalSince1970: $0) }
            accumulator.append(BrowserImportedCookie(
                name: name, value: value, domain: domain, path: row["path"]?.string ?? "/",
                secure: row["is_secure"]?.int == 1, httpOnly: row["is_httponly"]?.int == 1,
                sameSite: .fromDatabase(row["samesite"]?.int ?? -1), expires: expires))
        }
        guard accumulator.result.totalCookies > 0 else { throw BrowserCookieImportError.noCookies }
        return accumulator.result
    }
}

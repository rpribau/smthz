import Foundation
import SQLite3
import Testing
@testable import SmthzCore

enum CookieFixtureValue {
    case int(Int64), text(String), blob(Data), null
}

/// Builds throwaway SQLite cookie DBs; never touches a real browser profile.
struct CookieFixtureDirectory {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("smthz-ckt-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    func cleanup() { try? FileManager.default.removeItem(at: url) }

    func database(_ relativePath: String, schema: String, table: String,
                  rows: [[String: CookieFixtureValue]]) throws -> URL {
        let path = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(path.path, &db) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for row in rows {
            let keys = row.keys.sorted()
            let sql = "INSERT INTO \(table) (\(keys.joined(separator: ","))) VALUES (\(keys.map { _ in "?" }.joined(separator: ",")))"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
            for (index, key) in keys.enumerated() {
                let position = Int32(index + 1)
                switch row[key]! {
                case .int(let v): sqlite3_bind_int64(statement, position, v)
                case .text(let s): sqlite3_bind_text(statement, position, s, -1, transient)
                case .blob(let d):
                    _ = d.withUnsafeBytes { sqlite3_bind_blob(statement, position, $0.baseAddress, Int32(d.count), transient) }
                case .null: sqlite3_bind_null(statement, position)
                }
            }
            let step = sqlite3_step(statement)
            sqlite3_finalize(statement)
            guard step == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
        }
        return path
    }
}

private let chromeSchema = """
CREATE TABLE cookies (creation_utc INTEGER NOT NULL DEFAULT 0, host_key TEXT NOT NULL, top_frame_site_key TEXT NOT NULL DEFAULT '',
 name TEXT NOT NULL, value TEXT NOT NULL DEFAULT '', encrypted_value BLOB NOT NULL DEFAULT X'', path TEXT NOT NULL,
 expires_utc INTEGER NOT NULL, is_secure INTEGER NOT NULL, is_httponly INTEGER NOT NULL, samesite INTEGER NOT NULL DEFAULT -1);
"""

private func chromiumTime(_ unix: TimeInterval) -> Int64 { (Int64(unix) + 11_644_473_600) * 1_000_000 }

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let future = chromiumTime(1_900_000_000)

private struct CountingKeyProvider: ChromiumKeyProvider {
    let password: String?
    let calls = CallCounter()
    func password(service: String, account: String) throws -> String {
        calls.increment()
        #expect(service == "Chrome Safe Storage" && account == "Chrome")
        guard let password else { throw BrowserCookieImportError.keyUnavailable(service: service, status: -25300) }
        return password
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

private func chromeRow(_ host: String, _ name: String, value: String = "", encrypted: Data = Data(),
                       expires: Int64 = future, secure: Int64 = 0, httpOnly: Int64 = 0,
                       sameSite: Int64 = -1) -> [String: CookieFixtureValue] {
    ["host_key": .text(host), "name": .text(name), "value": .text(value), "encrypted_value": .blob(encrypted),
     "path": .text("/"), "expires_utc": .int(expires), "is_secure": .int(secure), "is_httponly": .int(httpOnly),
     "samesite": .int(sameSite)]
}

@Test func chromeImportDecryptsFiltersAndCounts() throws {
    let fixture = try CookieFixtureDirectory()
    defer { fixture.cleanup() }
    let key = try #require(ChromiumCookieCrypto.deriveKey(password: "fixture-secret"))
    func enc(_ s: String, hash host: String? = nil) throws -> Data {
        try #require(ChromiumCookieCrypto.encrypt(Data(s.utf8), key: key, hostKeyHashPrefix: host))
    }
    var appBound = try enc("x")
    appBound.replaceSubrange(0..<3, with: Data("v20".utf8))
    let db = try fixture.database("Chrome/Default/Network/Cookies", schema: chromeSchema, table: "cookies", rows: [
        chromeRow(".example.com", "plain", value: "p1", secure: 1, sameSite: 1),
        chromeRow(".example.com", "old", encrypted: try enc("legacy-v10"), httpOnly: 1, sameSite: 2),
        chromeRow("app.example.com", "new", encrypted: try enc("hashed", hash: "app.example.com"), sameSite: 0),
        chromeRow("session.test", "sess", value: "s", expires: 0),
        chromeRow(".google.com", "SID", encrypted: try enc("g")),
        chromeRow("accounts.google.com", "LSID", value: "g2"),
        chromeRow(".expired.test", "gone", value: "e", expires: chromiumTime(1_700_000_000)),
        chromeRow(".bound.test", "ab", encrypted: appBound),
        chromeRow("com", "suffix", value: "bad")
    ])
    let provider = CountingKeyProvider(password: "fixture-secret")
    let result = try BrowserCookieImportChrome.importCookies(from: db, browser: ChromiumBrowser.all[0],
                                                             keyProvider: provider, now: now)
    #expect(provider.calls.count == 1)
    #expect(result.source == .chrome)
    #expect(result.totalCookies == 9)
    #expect(result.googleCookiesSkipped == 2)
    #expect(result.expiredSkipped == 1)
    #expect(result.decryptFailed == 1 && result.appBoundFailed == 1)
    #expect(result.skippedCookies == 5)
    #expect(!result.keyUnavailable)
    let byName = Dictionary(uniqueKeysWithValues: result.cookies.map { ($0.name, $0) })
    #expect(byName.keys.sorted() == ["new", "old", "plain", "sess"])
    #expect(byName["plain"]?.value == "p1" && byName["plain"]?.secure == true && byName["plain"]?.sameSite == .lax)
    #expect(byName["old"]?.value == "legacy-v10" && byName["old"]?.httpOnly == true && byName["old"]?.sameSite == .strict)
    #expect(byName["new"]?.value == "hashed" && byName["new"]?.sameSite == .noRestriction)
    #expect(byName["new"]?.expires == Date(timeIntervalSince1970: 1_900_000_000))
    #expect(byName["sess"]?.expires == nil)
    #expect(result.domains == ["app.example.com", "example.com", "session.test"])
    #expect(result.httpCookies.count == 4)
}

@Test func databaseSnapshotCopiesSidecarsAndCleansUp() throws {
    let fixture = try CookieFixtureDirectory()
    defer { fixture.cleanup() }
    let db = try fixture.database("Cookies", schema: chromeSchema, table: "cookies", rows: [chromeRow("a.test", "n")])
    var snapshot: BrowserCookieDatabaseSnapshot? = try BrowserCookieDatabaseSnapshot(copying: db, fileName: "Cookies")
    let directory = try #require(snapshot?.directory)
    #expect(directory.path != db.deletingLastPathComponent().path)
    #expect(try snapshot?.rows("SELECT name FROM cookies").first?["name"] == .text("n"))
    snapshot = nil
    #expect(!FileManager.default.fileExists(atPath: directory.path))
    #expect(FileManager.default.fileExists(atPath: db.path))
}

@Test func chromeImportWithoutKeyCountsEncryptedRowsAsFailed() throws {
    let fixture = try CookieFixtureDirectory()
    defer { fixture.cleanup() }
    let key = try #require(ChromiumCookieCrypto.deriveKey(password: "fixture-secret"))
    let blob = try #require(ChromiumCookieCrypto.encrypt(Data("v".utf8), key: key))
    let db = try fixture.database("Cookies", schema: chromeSchema, table: "cookies", rows: [
        chromeRow("a.test", "enc", encrypted: blob), chromeRow("b.test", "plain", value: "ok")
    ])
    let result = try BrowserCookieImportChrome.importCookies(from: db, browser: ChromiumBrowser.all[0],
                                                             keyProvider: CountingKeyProvider(password: nil), now: now)
    #expect(result.keyUnavailable)
    #expect(result.decryptFailed == 1 && result.appBoundFailed == 0)
    #expect(result.cookies.map(\.name) == ["plain"])
}

@Test func chromeImportSkipsKeychainWhenNothingIsEncrypted() throws {
    let fixture = try CookieFixtureDirectory()
    defer { fixture.cleanup() }
    let db = try fixture.database("Cookies", schema: chromeSchema, table: "cookies",
                                  rows: [chromeRow("a.test", "plain", value: "1")])
    let provider = CountingKeyProvider(password: "unused")
    _ = try BrowserCookieImportChrome.importCookies(from: db, browser: ChromiumBrowser.all[0], keyProvider: provider, now: now)
    #expect(provider.calls.count == 0)
}

@Test func chromeImportReadsOlderSchemaWithoutSameSite() throws {
    let fixture = try CookieFixtureDirectory()
    defer { fixture.cleanup() }
    let schema = "CREATE TABLE cookies (host_key TEXT, name TEXT, value TEXT, path TEXT, expires_utc INTEGER, secure INTEGER);"
    let db = try fixture.database("Cookies", schema: schema, table: "cookies", rows: [
        ["host_key": .text("old.test"), "name": .text("n"), "value": .text("v"), "path": .text("/x"), "expires_utc": .int(0)]
    ])
    let result = try BrowserCookieImportChrome.importCookies(from: db, browser: ChromiumBrowser.all[1],
                                                             keyProvider: FixedChromiumKeyProvider("x"), now: now)
    #expect(result.source == .edge)
    #expect(result.cookies == [BrowserImportedCookie(name: "n", value: "v", domain: "old.test", path: "/x")])
}

@Test func chromeImportErrorsForMissingOrEmptyDatabases() throws {
    let fixture = try CookieFixtureDirectory()
    defer { fixture.cleanup() }
    #expect(throws: BrowserCookieImportError.notFound(path: fixture.url.appendingPathComponent("nope").path)) {
        try BrowserCookieImportChrome.importCookies(from: fixture.url.appendingPathComponent("nope"),
                                                    browser: ChromiumBrowser.all[0], keyProvider: FixedChromiumKeyProvider(""))
    }
    let empty = try fixture.database("Empty", schema: chromeSchema, table: "cookies", rows: [])
    #expect(throws: BrowserCookieImportError.noCookies) {
        try BrowserCookieImportChrome.importCookies(from: empty, browser: ChromiumBrowser.all[0],
                                                    keyProvider: FixedChromiumKeyProvider(""))
    }
}

@Test func chromeProfileDiscoveryUsesLocalStateAndRejectsUnsafeDirectories() throws {
    let fixture = try CookieFixtureDirectory()
    defer { fixture.cleanup() }
    let chrome = ChromiumBrowser.all[0]
    let root = chrome.root(home: fixture.url)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let localState: [String: Any] = ["profile": ["info_cache": [
        "Default": ["name": "Personal"], "Profile 1": ["name": "Work"], "Profile 2": ["name": "No DB"],
        "../escape": ["name": "Evil"]
    ]]]
    try JSONSerialization.data(withJSONObject: localState).write(to: root.appendingPathComponent("Local State"))
    _ = try fixture.database("Library/Application Support/Google/Chrome/Default/Network/Cookies",
                             schema: chromeSchema, table: "cookies", rows: [])
    _ = try fixture.database("Library/Application Support/Google/Chrome/Profile 1/Cookies",
                             schema: chromeSchema, table: "cookies", rows: [])
    let profiles = BrowserCookieImportChrome.discoverProfiles(chrome, home: fixture.url)
    #expect(profiles.map(\.name) == ["Personal", "Work"])
    #expect(profiles[0].cookiesPath.hasSuffix("Default/Network/Cookies"))
    #expect(profiles[1].cookiesPath.hasSuffix("Profile 1/Cookies"))
    #expect(!BrowserCookieImportChrome.isSafeProfileDirectory("../escape"))
    #expect(BrowserCookieImportChrome.profileEntries(root: fixture.url.appendingPathComponent("none")).map(\.directory) == ["Default"])
}

@Test func importedCookieBuildsHTTPCookie() throws {
    // Foundation clamps expiry to 400 days (RFC 6265bis), so use a date inside that window.
    let expires = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + 30 * 86_400).rounded())
    let cookie = BrowserImportedCookie(name: "id", value: "v", domain: ".example.com", path: "/app", secure: true,
                                       httpOnly: true, sameSite: .strict, expires: expires)
    let http = try #require(cookie.httpCookie)
    #expect(http.name == "id" && http.value == "v" && http.domain == ".example.com" && http.path == "/app")
    #expect(http.isSecure && http.isHTTPOnly && !http.isSessionOnly)
    #expect(http.sameSitePolicy == .sameSiteStrict)
    #expect(http.expiresDate.map { abs($0.timeIntervalSince(expires)) < 1 } == true)
    let session = try #require(BrowserImportedCookie(name: "s", value: "1", domain: "host.test").httpCookie)
    #expect(session.isSessionOnly && session.sameSitePolicy == nil)
}

@Test func googleExclusionCoversSubdomainsOnly() {
    #expect(BrowserCookieImportPolicy.isNonTransplantable(domain: ".google.com"))
    #expect(BrowserCookieImportPolicy.isNonTransplantable(domain: "Mail.Google.com"))
    #expect(!BrowserCookieImportPolicy.isNonTransplantable(domain: "notgoogle.com"))
    #expect(!BrowserCookieImportPolicy.isNonTransplantable(domain: ".youtube.com"))
    #expect(BrowserCookieImportPolicy.normalizeDomain(" .Example.COM ") == "example.com")
    #expect(BrowserCookieImportPolicy.normalizeDomain("localhost") == "localhost")
    #expect(BrowserCookieImportPolicy.normalizeDomain("com") == nil)
    #expect(BrowserCookieImportPolicy.normalizeDomain("a b.test") == nil)
}

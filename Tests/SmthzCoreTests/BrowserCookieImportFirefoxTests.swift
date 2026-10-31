import Foundation
import Testing
@testable import SmthzCore

private let firefoxSchema = """
CREATE TABLE moz_cookies (id INTEGER PRIMARY KEY, originAttributes TEXT NOT NULL DEFAULT '', name TEXT, value TEXT,
 host TEXT, path TEXT, expiry INTEGER, lastAccessed INTEGER, creationTime INTEGER, isSecure INTEGER, isHttpOnly INTEGER,
 inBrowserElement INTEGER DEFAULT 0, sameSite INTEGER DEFAULT 0, schemeMap INTEGER DEFAULT 0);
"""

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func firefoxRow(_ host: String, _ name: String, value: String = "v", path: String = "/", expiry: Int64 = 1_900_000_000,
                        secure: Int64 = 0, httpOnly: Int64 = 0, sameSite: Int64 = 256) -> [String: CookieFixtureValue] {
    ["host": .text(host), "name": .text(name), "value": .text(value), "path": .text(path), "expiry": .int(expiry),
     "isSecure": .int(secure), "isHttpOnly": .int(httpOnly), "sameSite": .int(sameSite)]
}

@Test func firefoxImportMapsColumnsAndFilters() throws {
    let fixture = try CookieFixtureDirectory()
    defer { fixture.cleanup() }
    let db = try fixture.database("cookies.sqlite", schema: firefoxSchema, table: "moz_cookies", rows: [
        firefoxRow(".example.com", "a", secure: 1, httpOnly: 1, sameSite: 1),
        firefoxRow("host.example.com", "ms", path: "", expiry: 1_900_000_000_000, sameSite: 2),
        firefoxRow("none.test", "n", sameSite: 0),
        firefoxRow(".google.com", "SID"),
        firefoxRow("old.test", "expired", expiry: 1_700_000_000),
        firefoxRow("old.test", "", value: "noname")
    ])
    let result = try BrowserCookieImportFirefox.importCookies(from: db, now: now)
    #expect(result.source == .firefox)
    #expect(result.totalCookies == 6)
    #expect(result.googleCookiesSkipped == 1 && result.expiredSkipped == 1 && result.skippedCookies == 3)
    #expect(result.cookies == [
        BrowserImportedCookie(name: "a", value: "v", domain: ".example.com", secure: true, httpOnly: true,
                              sameSite: .lax, expires: Date(timeIntervalSince1970: 1_900_000_000)),
        BrowserImportedCookie(name: "ms", value: "v", domain: "host.example.com", sameSite: .strict,
                              expires: Date(timeIntervalSince1970: 1_900_000_000)),
        BrowserImportedCookie(name: "n", value: "v", domain: "none.test", sameSite: .noRestriction,
                              expires: Date(timeIntervalSince1970: 1_900_000_000))
    ])
}

@Test func firefoxUnsetSameSiteIsUnspecified() {
    #expect(BrowserCookieSameSite.fromDatabase(256) == .unspecified)
    #expect(BrowserCookieSameSite.fromDatabase(nil) == .unspecified)
    #expect(BrowserCookieSameSite.fromDatabase(-1) == .unspecified)
}

@Test func firefoxImportToleratesMinimalSchema() throws {
    let fixture = try CookieFixtureDirectory()
    defer { fixture.cleanup() }
    let db = try fixture.database("cookies.sqlite", schema: "CREATE TABLE moz_cookies (name TEXT, value TEXT, host TEXT);",
                                  table: "moz_cookies", rows: [["name": .text("x"), "value": .text("1"), "host": .text("a.test")]])
    let result = try BrowserCookieImportFirefox.importCookies(from: db, now: now)
    #expect(result.cookies == [BrowserImportedCookie(name: "x", value: "1", domain: "a.test")])
}

@Test func firefoxImportRejectsForeignSchema() throws {
    let fixture = try CookieFixtureDirectory()
    defer { fixture.cleanup() }
    let db = try fixture.database("cookies.sqlite", schema: "CREATE TABLE moz_cookies (foo TEXT);", table: "moz_cookies", rows: [])
    #expect(throws: BrowserCookieImportError.unreadable("moz_cookies lacks name")) {
        try BrowserCookieImportFirefox.importCookies(from: db, now: now)
    }
}

@Test func firefoxProfileDiscoveryPrefersDefaultRelease() throws {
    let fixture = try CookieFixtureDirectory()
    defer { fixture.cleanup() }
    let base = "Library/Application Support/Firefox/Profiles"
    for directory in ["abc.other", "def.default", "ghi.default-release"] {
        _ = try fixture.database("\(base)/\(directory)/cookies.sqlite", schema: firefoxSchema, table: "moz_cookies", rows: [])
    }
    try FileManager.default.createDirectory(at: fixture.url.appendingPathComponent("\(base)/jkl.nodb"),
                                            withIntermediateDirectories: true)
    let profiles = BrowserCookieImportFirefox.discoverProfiles(home: fixture.url)
    #expect(profiles.map(\.directory) == ["ghi.default-release", "def.default", "abc.other"])
    #expect(profiles.map(\.name) == ["default-release", "default", "other"])
    #expect(BrowserCookieImportFirefox.discoverProfiles(home: fixture.url.appendingPathComponent("none")).isEmpty)
}

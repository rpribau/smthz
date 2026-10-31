import Foundation
import Testing
@testable import SmthzCore

/// Writes the Cookies.binarycookies layout (header "cook", big-endian page table, little-endian pages).
private enum BinaryCookies {
    struct Entry { var domain, name, path, value: String; var flags: UInt32 = 0; var expires: Double = 0 }

    static func le32(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }
    static func be32(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.bigEndian, Array.init) }
    static func le64(_ v: Double) -> [UInt8] { withUnsafeBytes(of: v.bitPattern.littleEndian, Array.init) }

    static func cookie(_ e: Entry) -> [UInt8] {
        let strings = [e.domain, e.name, e.path, e.value].map { Array($0.utf8) + [0] }
        var offsets: [UInt32] = []
        var cursor: UInt32 = 56
        for s in strings { offsets.append(cursor); cursor += UInt32(s.count) }
        var out = le32(cursor) + le32(0) + le32(e.flags) + le32(0)
        out += offsets.flatMap(le32) + [UInt8](repeating: 0, count: 8) + le64(e.expires) + le64(0)
        return out + strings.flatMap { $0 }
    }

    static func page(_ entries: [Entry]) -> [UInt8] {
        let cookies = entries.map(cookie)
        var offset = UInt32(8 + 4 * cookies.count + 4)
        var header = be32(0x0000_0100) + le32(UInt32(cookies.count))
        for c in cookies { header += le32(offset); offset += UInt32(c.count) }
        return header + le32(0) + cookies.flatMap { $0 }
    }

    static func file(_ pages: [[Entry]]) -> Data {
        let encoded = pages.map(page)
        return Data(Array("cook".utf8) + be32(UInt32(encoded.count)) + encoded.flatMap { be32(UInt32($0.count)) }
                    + encoded.flatMap { $0 } + [UInt8](repeating: 0, count: 8))
    }
}

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let macFuture = 1_900_000_000 - 978_307_200.0

@Test func safariDecoderReadsPagesFlagsAndDates() {
    let data = BinaryCookies.file([
        [.init(domain: ".example.com", name: "a", path: "/", value: "1", flags: 5, expires: macFuture),
         .init(domain: "host.test", name: "b", path: "/p", value: "", flags: 0, expires: 0)],
        [.init(domain: ".other.test", name: "c", path: "/", value: "3", flags: 4, expires: macFuture)]
    ])
    let cookies = BrowserCookieImportSafari.decode(data)
    #expect(cookies == [
        BrowserImportedCookie(name: "a", value: "1", domain: ".example.com", secure: true, httpOnly: true,
                              expires: Date(timeIntervalSince1970: 1_900_000_000)),
        BrowserImportedCookie(name: "b", value: "", domain: "host.test", path: "/p"),
        BrowserImportedCookie(name: "c", value: "3", domain: ".other.test", httpOnly: true,
                              expires: Date(timeIntervalSince1970: 1_900_000_000))
    ])
}

@Test func safariDecoderRejectsMalformedInputWithoutTrapping() {
    #expect(BrowserCookieSafariFuzz.allDecodeSafely())
    #expect(BrowserCookieImportSafari.decode(Data("nope".utf8)).isEmpty)
    var bogusCount = Array("cook".utf8) + BinaryCookies.be32(0xFFFF_FFFF)
    bogusCount += [0, 0, 0, 0]
    #expect(BrowserCookieImportSafari.decode(Data(bogusCount)).isEmpty)
}

private enum BrowserCookieSafariFuzz {
    /// Every truncation and a byte flip at every position of a valid file must decode without crashing.
    static func allDecodeSafely() -> Bool {
        let valid = [UInt8](BinaryCookies.file([[.init(domain: ".x.test", name: "n", path: "/", value: "v", expires: macFuture)]]))
        for length in 0..<valid.count { _ = BrowserCookieImportSafari.decode(Data(valid.prefix(length))) }
        for index in valid.indices {
            var copy = valid
            copy[index] = 0xFF
            _ = BrowserCookieImportSafari.decode(Data(copy))
        }
        return true
    }
}

@Test func safariImportFiltersGoogleAndExpired() throws {
    let fixture = try CookieFixtureDirectory()
    defer { fixture.cleanup() }
    let file = fixture.url.appendingPathComponent("Cookies.binarycookies")
    try BinaryCookies.file([[
        .init(domain: ".keep.test", name: "k", path: "/", value: "1", expires: macFuture),
        .init(domain: ".google.com", name: "SID", path: "/", value: "g", expires: macFuture),
        .init(domain: ".old.test", name: "o", path: "/", value: "x", expires: 1_000)
    ]]).write(to: file)
    let result = try BrowserCookieImportSafari.importCookies(from: file, now: now)
    #expect(result.source == .safari)
    #expect(result.totalCookies == 3 && result.googleCookiesSkipped == 1 && result.expiredSkipped == 1)
    #expect(result.cookies.map(\.name) == ["k"])
}

@Test func safariImportReportsMissingUnreadableAndEmpty() throws {
    let fixture = try CookieFixtureDirectory()
    defer { fixture.cleanup() }
    let missing = fixture.url.appendingPathComponent("missing.binarycookies")
    #expect(throws: BrowserCookieImportError.notFound(path: missing.path)) {
        try BrowserCookieImportSafari.importCookies(from: missing)
    }
    let locked = fixture.url.appendingPathComponent("locked.binarycookies")
    try BinaryCookies.file([]).write(to: locked)
    chmod(locked.path, 0o000)
    defer { chmod(locked.path, 0o600) }
    #expect(throws: BrowserCookieImportError.permissionDenied(path: locked.path)) {
        try BrowserCookieImportSafari.importCookies(from: locked)
    }
    let empty = fixture.url.appendingPathComponent("empty.binarycookies")
    try BinaryCookies.file([]).write(to: empty)
    #expect(throws: BrowserCookieImportError.noCookies) { try BrowserCookieImportSafari.importCookies(from: empty) }
}

@Test func safariDiscoveryChecksCandidatesWithoutReading() throws {
    let fixture = try CookieFixtureDirectory()
    defer { fixture.cleanup() }
    #expect(BrowserCookieImportSafari.discoverProfiles(home: fixture.url).isEmpty)
    let path = BrowserCookieImportSafari.candidatePaths(home: fixture.url)[1]
    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: path)
    #expect(BrowserCookieImportSafari.discoverProfiles(home: fixture.url).map(\.cookiesPath) == [path.path])
}

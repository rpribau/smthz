import Foundation

/// Safari's `Cookies.binarycookies` (Orca `browser-cookie-safari-parser.ts`). The container copy
/// needs Full Disk Access; without it the read fails with `permissionDenied`.
public enum BrowserCookieImportSafari {
    /// Seconds between 1970-01-01 and Mac absolute time 2001-01-01.
    static let macEpochDelta: TimeInterval = 978_307_200

    public static func candidatePaths(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [home.appendingPathComponent("Library/Cookies/Cookies.binarycookies"),
         home.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies")]
    }

    /// The first existing candidate; existence is checked without reading (no TCC prompt).
    public static func discoverProfiles(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [BrowserSourceProfile] {
        candidatePaths(home: home).first { FileManager.default.fileExists(atPath: $0.path) }.map {
            [BrowserSourceProfile(source: .safari, name: "Default", directory: "Default", cookiesPath: $0.path)]
        } ?? []
    }

    public static func importCookies(from file: URL, now: Date = Date()) throws -> BrowserCookieImportResult {
        let data: Data
        do { data = try Data(contentsOf: file) } catch {
            if isPermissionError(error) { throw BrowserCookieImportError.permissionDenied(path: file.path) }
            if !FileManager.default.fileExists(atPath: file.path) { throw BrowserCookieImportError.notFound(path: file.path) }
            throw BrowserCookieImportError.unreadable(file.path)
        }
        let decoded = decode(data)
        guard !decoded.isEmpty else { throw BrowserCookieImportError.noCookies }
        var accumulator = BrowserCookieImportAccumulator(source: .safari, now: now)
        for cookie in decoded where accumulator.admit(name: cookie.name, domain: cookie.domain) {
            accumulator.append(cookie)
        }
        return accumulator.result
    }

    /// Lenient decoder: malformed pages or cookies are dropped, never trapped on. Offsets and sizes
    /// come from the file, so every read is bounds-checked against its page or cookie.
    public static func decode(_ data: Data) -> [BrowserImportedCookie] {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, bytes[0..<4].elementsEqual("cook".utf8),
              let pageCount = bytes.uint32BE(at: 4) else { return [] }
        var cursor = 8
        guard pageCount <= (bytes.count - 8) / 4 else { return [] }
        var sizes: [Int] = []
        for _ in 0..<pageCount {
            guard let size = bytes.uint32BE(at: cursor) else { return [] }
            sizes.append(Int(size))
            cursor += 4
        }
        var cookies: [BrowserImportedCookie] = []
        for size in sizes {
            guard cursor + size <= bytes.count else { break }
            cookies += decodePage(Array(bytes[cursor..<cursor + size]))
            cursor += size
        }
        return cookies
    }

    static func decodePage(_ page: [UInt8]) -> [BrowserImportedCookie] {
        guard page.count >= 16, page.uint32BE(at: 0) == 0x0000_0100,
              let count = page.uint32LE(at: 4), count <= (page.count - 8) / 4 else { return [] }
        return (0..<Int(count)).compactMap { index in
            guard let offset = page.uint32LE(at: 8 + index * 4), Int(offset) < page.count else { return nil }
            return decodeCookie(Array(page[Int(offset)...]))
        }
    }

    static func decodeCookie(_ buffer: [UInt8]) -> BrowserImportedCookie? {
        guard buffer.count >= 48, let declared = buffer.uint32LE(at: 0) else { return nil }
        let size = min(Int(declared), buffer.count)
        guard size >= 48, let flags = buffer.uint32LE(at: 8),
              let urlOffset = buffer.uint32LE(at: 16), let nameOffset = buffer.uint32LE(at: 20),
              let pathOffset = buffer.uint32LE(at: 24), let valueOffset = buffer.uint32LE(at: 28),
              let expiration = buffer.float64LE(at: 40) else { return nil }
        guard let name = buffer.cString(at: Int(nameOffset), end: size), !name.isEmpty,
              let domain = buffer.cString(at: Int(urlOffset), end: size), !domain.isEmpty else { return nil }
        return BrowserImportedCookie(
            name: name, value: buffer.cString(at: Int(valueOffset), end: size) ?? "", domain: domain,
            path: buffer.cString(at: Int(pathOffset), end: size) ?? "/",
            secure: flags & 1 != 0, httpOnly: flags & 4 != 0, sameSite: .unspecified,
            expires: expiration > 0 ? Date(timeIntervalSince1970: (expiration + macEpochDelta).rounded()) : nil)
    }
}

private extension Array where Element == UInt8 {
    func uint32BE(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return self[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    func uint32LE(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return self[offset..<offset + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) }
    }

    func float64LE(at offset: Int) -> Double? {
        guard offset >= 0, offset + 8 <= count else { return nil }
        let bits = self[offset..<offset + 8].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return Double(bitPattern: bits)
    }

    /// NUL-terminated UTF-8 string that must end before `end`.
    func cString(at offset: Int, end: Int) -> String? {
        guard offset >= 0, offset < end, end <= count,
              let terminator = self[offset..<end].firstIndex(of: 0) else { return nil }
        return String(decoding: self[offset..<terminator], as: UTF8.self)
    }
}

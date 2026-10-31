import Foundation

/// Firefox keeps plaintext cookies in `<profile>/cookies.sqlite` (`moz_cookies`), Orca
/// `browser-cookie-firefox-import.ts`.
public enum BrowserCookieImportFirefox {
    public static func profilesRoot(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Firefox/Profiles")
    }

    /// Profiles with a cookie DB, "default-release" first (Firefox dirs are `<random>.<name>`).
    public static func discoverProfiles(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [BrowserSourceProfile] {
        let root = profilesRoot(home: home)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        func rank(_ name: String) -> Int {
            name.contains("default-release") ? 0 : name.contains("default") ? 1 : 2
        }
        return entries.sorted { (rank($0), $0) < (rank($1), $1) }.compactMap { directory in
            guard BrowserCookieImportChrome.isSafeProfileDirectory(directory) else { return nil }
            let path = root.appendingPathComponent(directory).appendingPathComponent("cookies.sqlite")
            guard FileManager.default.fileExists(atPath: path.path) else { return nil }
            let label = directory.split(separator: ".", maxSplits: 1).dropFirst().first.map(String.init) ?? directory
            return BrowserSourceProfile(source: .firefox, name: label, directory: directory, cookiesPath: path.path)
        }
    }

    /// Firefox 2025+ stores `expiry` in milliseconds, older schemas in seconds. A seconds value
    /// above 10^11 would be past the year 5000, so larger values are milliseconds.
    static func expiryDate(_ raw: Int64) -> Date? {
        guard raw > 0 else { return nil }
        let seconds = raw > 100_000_000_000 ? TimeInterval(raw) / 1000 : TimeInterval(raw)
        return Date(timeIntervalSince1970: seconds)
    }

    public static func importCookies(from database: URL, now: Date = Date()) throws -> BrowserCookieImportResult {
        let snapshot = try BrowserCookieDatabaseSnapshot(copying: database, fileName: "cookies.sqlite")
        let columns = try snapshot.columns(of: "moz_cookies")
        for required in ["name", "host"] where !columns.contains(required) {
            throw BrowserCookieImportError.unreadable("moz_cookies lacks \(required)")
        }
        // Why (Orca): selecting a column an older schema lacks fails the whole import.
        let optional = ["value", "path", "expiry", "isSecure", "isHttpOnly", "sameSite"].filter(columns.contains)
        let rows = try snapshot.rows("SELECT name, host" + optional.map { ", \($0)" }.joined() + " FROM moz_cookies")
        var accumulator = BrowserCookieImportAccumulator(source: .firefox, now: now)
        for row in rows {
            let name = row["name"]?.string ?? ""
            let domain = row["host"]?.string ?? ""
            guard accumulator.admit(name: name, domain: domain) else { continue }
            let path = row["path"]?.string ?? ""
            accumulator.append(BrowserImportedCookie(
                name: name, value: row["value"]?.string ?? "", domain: domain, path: path.isEmpty ? "/" : path,
                secure: row["isSecure"]?.int == 1, httpOnly: row["isHttpOnly"]?.int == 1,
                sameSite: .fromDatabase(row["sameSite"]?.int), expires: expiryDate(row["expiry"]?.int ?? 0)))
        }
        guard accumulator.result.totalCookies > 0 else { throw BrowserCookieImportError.noCookies }
        return accumulator.result
    }
}

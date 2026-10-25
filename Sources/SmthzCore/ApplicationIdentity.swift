import Foundation

public enum ApplicationIdentity {
    public static let name = "smthz"
    public static let bundleIdentifier = "dev.smthz.app"
    public static let urlScheme = "smthz"
    public static let version = "0.1.0"

    public static func applicationSupportDirectory(home: URL) -> URL {
        return home
            .appending(path: "Library/Application Support", directoryHint: .isDirectory)
            .appending(path: name, directoryHint: .isDirectory)
    }

    public static func cacheDirectory(home: URL) -> URL {
        return home
            .appending(path: "Library/Caches", directoryHint: .isDirectory)
            .appending(path: name, directoryHint: .isDirectory)
    }

    public static func logDirectory(home: URL) -> URL {
        return home
            .appending(path: "Library/Logs", directoryHint: .isDirectory)
            .appending(path: name, directoryHint: .isDirectory)
    }
}

import Darwin
import Foundation

/// Builds the environment a host session's child process starts with. The host's own
/// environment is a base, but terminal-identity variables are never taken from it blindly:
/// a host launched by Xcode or launchd often has `TERM=dumb` (where `clear` prints nothing),
/// no `LANG`, or a toolchain-first `PATH`.
public enum SessionEnvironment {
    public static let defaultTerm = "xterm-256color"
    public static let defaultColorTerm = "truecolor"
    public static let defaultLang = "en_US.UTF-8"
    public static let standardPathEntries = ["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    /// - Parameters:
    ///   - base: the host environment (other variables are kept as they are).
    ///   - override: variables the caller asked for explicitly; they win over everything.
    ///   - account: fallbacks for HOME/USER/SHELL when the host lacks them.
    public static func build(base: [String: String], override: [String: String]? = nil,
                             account: Account = .current()) -> [String: String] {
        var env = base
        env["TERM"] = defaultTerm
        env["COLORTERM"] = defaultColorTerm
        if !isUTF8(base["LANG"]) { env["LANG"] = defaultLang }
        // A non-UTF-8 LC_ALL / LC_CTYPE would override LANG; drop them rather than guess a replacement.
        for key in ["LC_ALL", "LC_CTYPE"] where env[key] != nil && !isUTF8(env[key]) { env[key] = nil }
        env["PATH"] = sanePath(base["PATH"])
        env["HOME"] = nonEmpty(base["HOME"]) ?? account.home
        env["USER"] = nonEmpty(base["USER"]) ?? account.name
        env["LOGNAME"] = nonEmpty(base["LOGNAME"]) ?? env["USER"]
        env["SHELL"] = nonEmpty(base["SHELL"]) ?? account.shell
        // Session-specific leftovers from the host's own terminal must not describe the new pty.
        for key in ["TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID", "COLUMNS", "LINES", "TERMCAP"] { env[key] = nil }
        for (key, value) in override ?? [:] { env[key] = value }
        return env
    }

    static func isUTF8(_ value: String?) -> Bool {
        guard let value = value?.uppercased() else { return false }
        return value.contains("UTF-8") || value.contains("UTF8")
    }

    /// Standard directories first, then the host's own entries, minus anything inside an Xcode
    /// toolchain and duplicates.
    static func sanePath(_ hostPath: String?) -> String {
        var seen = Set<String>()
        var result: [String] = []
        let extra = (hostPath ?? "").split(separator: ":").map(String.init).filter {
            !$0.isEmpty && !$0.contains(".app/Contents/Developer")
        }
        for entry in standardPathEntries + extra where seen.insert(entry).inserted { result.append(entry) }
        return result.joined(separator: ":")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    public struct Account: Sendable {
        public var name: String
        public var home: String
        public var shell: String

        public init(name: String, home: String, shell: String) {
            self.name = name; self.home = home; self.shell = shell
        }

        public static func current() -> Account {
            if let entry = getpwuid(getuid()) {
                return Account(name: String(cString: entry.pointee.pw_name),
                               home: String(cString: entry.pointee.pw_dir),
                               shell: String(cString: entry.pointee.pw_shell))
            }
            return Account(name: NSUserName(), home: NSHomeDirectory(), shell: "/bin/zsh")
        }
    }
}

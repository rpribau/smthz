import Foundation

/// A local path in terminal text. Ranges use UTF-16, like NSRegularExpression.
public struct TerminalFileLink: Equatable, Sendable {
    public let range: NSRange
    public let path: String
    public let line: Int?
    public let column: Int?

    public func resolvedURL(cwd: String?, home: String) -> URL? {
        let expanded = path == "~" ? home : path.hasPrefix("~/") ? home + path.dropFirst() : path
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL }
        guard let cwd, cwd.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: cwd, isDirectory: true).appendingPathComponent(expanded).standardizedFileURL
    }

    public static func detect(in text: String) -> [TerminalFileLink] {
        // Exclude URI schemes and shell punctuation; quoted paths may contain spaces.
        let pattern = #"(?<![\w/:~.-])(?:"([^"\n]+)"|'([^'\n]+)'|((?:~/|/|\.{1,2}/)?[\w@+.-]+(?:/[\w@+.-]+)*))(?::([1-9][0-9]*)(?::([1-9][0-9]*))?)?(?![\w/:.-])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let source = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).compactMap { match in
            let capture = (1...3).first { match.range(at: $0).location != NSNotFound }!
            let path = source.substring(with: match.range(at: capture))
            guard path.contains("/") || (path.contains(".") && path != "." && path != "..") else { return nil }
            let line = match.range(at: 4).location == NSNotFound ? nil : Int(source.substring(with: match.range(at: 4)))
            let column = match.range(at: 5).location == NSNotFound ? nil : Int(source.substring(with: match.range(at: 5)))
            return TerminalFileLink(range: match.range, path: path, line: line, column: column)
        }
    }
}

public enum TerminalContext {
    /// Orca Copy Context: plain emulator text, newest 800 scrollback rows plus screen,
    /// at most 36,000 UTF-16 units, with its exact omission marker (no fork framing).
    public static func format(rows: [String]) -> String? {
        var text = rows.joined(separator: "\n")
            .replacingOccurrences(of: #"[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\n{4,}"#, with: "\n\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let length = text.utf16.count
        if length > 36_000 {
            let marker = "\n\n[Earlier terminal output omitted: \(length - 36_000) characters]\n\n"
            text = marker + String(decoding: text.utf16.suffix(36_000 - marker.utf16.count), as: UTF16.self)
        }
        return text
    }
}

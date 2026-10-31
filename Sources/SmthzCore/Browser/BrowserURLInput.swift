import Foundation

/// Search providers offered by the address bar (Orca `src/shared/browser-url.ts`).
public enum BrowserSearchEngine: String, Codable, Sendable, CaseIterable {
    case google, duckduckgo, bing, kagi

    public var label: String {
        switch self {
        case .google: "Google"
        case .duckduckgo: "DuckDuckGo"
        case .bing: "Bing"
        case .kagi: "Kagi"
        }
    }

    var queryPrefix: String {
        switch self {
        case .google: "https://www.google.com/search?q="
        case .duckduckgo: "https://duckduckgo.com/?q="
        case .bing: "https://www.bing.com/search?q="
        case .kagi: "https://kagi.com/search?q="
        }
    }
}

/// Address bar normalisation, ported from Orca's `normalizeBrowserNavigationUrl`.
/// Only http, https and file URLs are navigable in-app; external opens refuse file.
public enum BrowserURLInput {
    /// WebKit's blank page (Orca uses `data:text/html,` for Chromium).
    public static let blankURL = "about:blank"
    public static let defaultSearchEngine = BrowserSearchEngine.google

    /// Returns a navigable URL string, or nil when the input is rejected.
    /// `search` nil disables the search fallback (validation callers);
    /// the address bar passes an engine so plain words become a search.
    public static func normalize(_ raw: String, search: BrowserSearchEngine? = nil) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == blankURL || trimmed == "data:text/html," { return blankURL }
        if let local = localDevAddress(trimmed) { return local }
        if matches(trimmed, uncPath) { return uncPathToFileURL(trimmed) }
        if matches(trimmed, unixPath) || matches(trimmed, windowsPath) { return absolutePathToFileURL(trimmed) }
        if let domainPort = domainPortAddress(trimmed) { return domainPort }
        if matches(trimmed, schemePrefix) {
            guard let scheme = trimmed.split(separator: ":", maxSplits: 1).first?.lowercased(),
                  ["http", "https", "file"].contains(scheme) else { return nil }
            return canonical(trimmed)
        }
        let withScheme = trimmed.contains(where: \.isWhitespace) ? nil : canonical("https://" + trimmed)
        if let withScheme, search == nil || !looksLikeSearchQuery(trimmed) { return withScheme }
        guard let search else { return nil }
        return searchURL(trimmed, engine: search)
    }

    /// http(s) only: what may be handed to the system browser.
    public static func normalizeExternal(_ raw: String) -> String? {
        guard let url = normalize(raw), url != blankURL, !url.hasPrefix("file:") else { return nil }
        return url
    }

    public static func searchURL(_ query: String, engine: BrowserSearchEngine = defaultSearchEngine) -> String {
        engine.queryPrefix + encodeComponent(query)
    }

    /// Bare words and anything with a space search; dotted or colon input navigates.
    public static func looksLikeSearchQuery(_ input: String) -> Bool {
        if input.contains(" ") { return true }
        if matches(input, looksLikeURL) { return false }
        return !(input.contains(".") || input.contains(":"))
    }

    public static func isAbsoluteFilesystemPath(_ input: String) -> Bool {
        matches(input, unixPath) || matches(input, windowsPath) || matches(input, uncPath)
    }

    /// Text shown in the address bar for a committed URL.
    public static func displayText(_ url: String?) -> String {
        guard let url, url != blankURL else { return "" }
        return url
    }

    // MARK: - Classifiers

    private static let localAddress = #"^(?:localhost|127(?:\.\d{1,3}){3}|0\.0\.0\.0|\[[0-9a-f:]+\])(?::\d+)?(?:[/?#].*)?$"#
    private static let looksLikeURL = #"^[^\s]+\.[a-z]{2,}(\/.*)?$"#
    private static let windowsPath = #"^[A-Za-z]:[\\/].*$"#
    private static let uncPath = #"^\\\\[^\s\\/]+[\\/][^\\/]+(?:[\\/].*)?$"#
    private static let unixPath = #"^/.*$"#
    private static let domainPort = #"^([^\s/\\:@?#]+):\d+(?:[/?#].*)?$"#
    private static let schemePrefix = #"^[A-Za-z][A-Za-z0-9+.\-]*:"#

    private static func matches(_ input: String, _ pattern: String) -> Bool {
        input.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func localDevAddress(_ input: String) -> String? {
        matches(input, localAddress) ? canonical("http://" + input) : nil
    }

    private static func domainPortAddress(_ input: String) -> String? {
        guard matches(input, domainPort),
              let host = input.split(separator: ":", maxSplits: 1).first, host.contains("."),
              let url = canonical("https://" + input),
              let parsedHost = URLComponents(string: url)?.host else { return nil }
        let name = normalizedHostname(parsedHost)
        guard isValidDNSName(name) else { return nil }
        return name.hasSuffix(".localhost") ? canonical("http://" + input) : url
    }

    private static func normalizedHostname(_ host: String) -> String {
        var lower = host.lowercased()
        if lower.hasPrefix("["), lower.hasSuffix("]") { lower = String(lower.dropFirst().dropLast()) }
        return lower.hasSuffix(".") ? String(lower.dropLast()) : lower
    }

    private static func isValidDNSName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 253 else { return false }
        return name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            label.count <= 63 && String(label).range(of: #"^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$"#, options: .regularExpression) != nil
        }
    }

    // MARK: - Serialisation

    /// WHATWG-like canonical form: lowercase scheme/host, "/" path for empty http(s) paths.
    private static func canonical(_ string: String) -> String? {
        guard var parts = URLComponents(string: string), let scheme = parts.scheme?.lowercased() else { return nil }
        parts.scheme = scheme
        if scheme == "http" || scheme == "https" {
            guard let host = parts.host, !host.isEmpty else { return nil }
            parts.host = host.lowercased()
            if parts.percentEncodedPath.isEmpty { parts.percentEncodedPath = "/" }
        }
        return parts.string
    }

    /// JavaScript `encodeURIComponent`.
    static func encodeComponent(_ value: String) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-_.!~*'()")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func absolutePathToFileURL(_ path: String) -> String {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let segments = normalized.split(separator: "/", omittingEmptySubsequences: false).enumerated().map { index, segment in
            index == 0 && String(segment).range(of: #"^[A-Za-z]:$"#, options: .regularExpression) != nil
                ? String(segment) : encodeComponent(String(segment))
        }
        let joined = segments.joined(separator: "/")
        return normalized.hasPrefix("/") ? "file://" + joined : "file:///" + joined
    }

    private static func uncPathToFileURL(_ path: String) -> String {
        var normalized = Substring(path.replacingOccurrences(of: "\\", with: "/"))
        while normalized.hasPrefix("/") { normalized = normalized.dropFirst() }
        let parts = normalized.split(separator: "/", omittingEmptySubsequences: false)
        let host = parts.first.map(String.init) ?? ""
        return "file://\(host)/" + parts.dropFirst().map { encodeComponent(String($0)) }.joined(separator: "/")
    }
}

/// Chrome-style page zoom presets (Orca `browser-page-zoom.ts`), expressed as
/// WKWebView `pageZoom` factors.
public enum BrowserPageZoom {
    public enum Direction: Sendable { case zoomIn, zoomOut, reset }

    public static let percents: [Int] = [25, 33, 50, 67, 75, 80, 90, 100, 110, 125, 150, 175, 200, 250, 300, 400, 500]

    /// Nearest preset in log space; non-finite or non-positive factors count as 100%.
    public static func nearestIndex(_ factor: Double) -> Int {
        guard factor.isFinite, factor > 0 else { return percents.firstIndex(of: 100)! }
        let target = log(factor)
        return percents.indices.min { abs(log(Double(percents[$0]) / 100) - target) < abs(log(Double(percents[$1]) / 100) - target) }!
    }

    public static func percent(_ factor: Double) -> Int { percents[nearestIndex(factor)] }

    public static func next(_ factor: Double, _ direction: Direction) -> Double {
        let index: Int
        switch direction {
        case .reset: return 1
        case .zoomIn: index = min(percents.count - 1, nearestIndex(factor) + 1)
        case .zoomOut: index = max(0, nearestIndex(factor) - 1)
        }
        return Double(percents[index]) / 100
    }
}

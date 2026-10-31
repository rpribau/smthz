import Foundation

public enum WorktreeNamingError: Error, Equatable, Sendable {
    case invalidName
    case invalidBranchPrefix(String)
    case invalidBranchName(String)
    case pathOutsideRoot
}

/// Worktree names, branches, collision candidates and paths (M4-PLAN §8.2). Ports of Orca
/// `worktree-logic.ts`, `branch-prefix.ts`, `worktree-branch-name.ts`, `worktree-create-candidates.ts`.
public enum WorktreeNaming {
    public static let maxSuffixAttempts = 100

    // MARK: Sanitize

    private static let unsafeRun = try! NSRegularExpression(pattern: "[^\\p{L}\\p{N}._-]+")
    private static let emojiPattern = try! NSRegularExpression(
        pattern: "[\\p{Emoji_Presentation}\\p{Extended_Pictographic}\\p{Regional_Indicator}\\u20e3]")

    /// Directory and branch leaf for a typed name: known emoji become shortcodes (🚀 → `rocket`),
    /// unsafe runs become `-`, `..` collapses, leading/trailing `.`/`-` are stripped.
    public static func sanitize(_ input: String, replacingEmoji: Bool = true) throws(WorktreeNamingError) -> String {
        var value = replacingEmoji ? EmojiShortcodes.replaceKnownEmoji(in: input) : input
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        value = replace(unsafeRun, in: value, with: "-")
        value = value.replacing(/-+/, with: "-")
            .replacing(/\.{2,}/, with: ".")
            .replacing(/^[.-]+|[.-]+$/, with: "")
        if value.isEmpty && containsEmoji(input) { return "workspace" }
        guard !value.isEmpty, value != ".", value != ".." else { throw .invalidName }
        return value
    }

    public static func containsEmoji(_ input: String) -> Bool {
        emojiPattern.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)) != nil
    }

    private static func replace(_ regex: NSRegularExpression, in value: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: template)
    }

    // MARK: Branch prefix

    public enum PrefixStrategy: String, Equatable, Sendable {
        case gitUsername = "git-username"
        case custom
        case none
    }

    /// Strips surrounding whitespace and `/`, collapses `//` (`team//x/` → `team/x`).
    public static func normalizeBranchPrefix(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacing(/^\/+|\/+$/, with: "")
            .replacing(/\/{2,}/, with: "/")
    }

    /// Mirror of the `git check-ref-format` rules that matter for a prefix; git stays authoritative.
    public static func isValidBranchPrefix(_ raw: String) -> Bool {
        let prefix = normalizeBranchPrefix(raw)
        if prefix.isEmpty { return true }
        if prefix.unicodeScalars.contains(where: { $0.value <= 0x20 || $0.value == 0x7F }) { return false }
        if prefix.contains(where: { "~^:?*[\\".contains($0) }) { return false }
        if prefix.contains("..") || prefix.contains("@{") || prefix.hasPrefix("-") || prefix.hasSuffix(".") { return false }
        return !prefix.split(separator: "/").contains { $0.hasPrefix(".") || $0.hasSuffix(".lock") }
    }

    /// `prefix/sanitized`, or `sanitized` when no prefix applies. An invalid git-username prefix
    /// is dropped silently; an invalid custom prefix fails.
    public static func branchName(for sanitized: String, strategy: PrefixStrategy, customPrefix: String? = nil,
                                  gitUsername: String? = nil) throws(WorktreeNamingError) -> String {
        let raw: String? = switch strategy {
        case .gitUsername: gitUsername
        case .custom: customPrefix
        case .none: nil
        }
        guard let raw else { return sanitized }
        let prefix = normalizeBranchPrefix(raw)
        guard !prefix.isEmpty else { return sanitized }
        guard isValidBranchPrefix(prefix) else {
            if strategy == .gitUsername { return sanitized }
            throw .invalidBranchPrefix(raw)
        }
        return "\(prefix)/\(sanitized)"
    }

    /// Cheap pre-check for an explicit branch name; the host still runs `git check-ref-format --branch`.
    public static func validateExplicitBranchName(_ name: String) throws(WorktreeNamingError) {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.hasPrefix("/"), !name.hasSuffix("/"),
              !name.contains("//"), isValidBranchPrefix(name) else { throw .invalidBranchName(name) }
    }

    // MARK: Collision candidates

    /// Attempt 1 is the value itself, attempt N is `value-N`.
    public static func candidate(_ value: String, attempt: Int) -> String {
        attempt <= 1 ? value : "\(value)-\(attempt)"
    }

    /// For generated creature names a collision moves up a tier (`nautilus` → `nautilus-2`)
    /// instead of stacking suffixes; anything else falls back to `candidate`.
    public static func generatedCandidate(_ value: String, attempt: Int, exhaustedTiers: Int = 0) -> String {
        guard let identity = generatedIdentity(value) else { return candidate(value, attempt: attempt) }
        let tier = max(identity.tier, exhaustedTiers + 1) + max(attempt, 1) - 1
        return CreatureNames.name(identity.poolName, tier: tier)
    }

    /// Also recognizes stacked collision variants (`nautilus-2-3`) left by older clients.
    public static func isGeneratedName(_ value: String) -> Bool { generatedIdentity(value) != nil }

    static func generatedIdentity(_ value: String) -> (poolName: String, tier: Int)? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let tier = CreatureNames.tier(of: normalized) {
            let pool = tier == 1 ? normalized : String(normalized[..<normalized.lastIndex(of: "-")!])
            return (pool, tier)
        }
        var pool = normalized
        var tier = 1
        var suffixes = 0
        while let match = pool.firstMatch(of: /-(\d{1,6})$/) {
            guard let suffix = Int(match.1), suffix >= 2, tier + suffix - 1 <= CreatureNames.maxTier else { return nil }
            tier += suffix - 1
            suffixes += 1
            pool = String(pool[..<match.range.lowerBound])
        }
        return suffixes > 1 && CreatureNames.pool.contains(pool) ? (pool, tier) : nil
    }

    // MARK: Paths

    /// `<root>/<repo basename without .git>/<sanitized>` when nested, else `<root>/<sanitized>`.
    /// The result must stay inside `workspaceRoot`.
    public static func worktreePath(sanitized: String, repoPath: String, workspaceRoot: String,
                                    nestWorkspaces: Bool) throws(WorktreeNamingError) -> String {
        let root = (workspaceRoot as NSString).standardizingPath
        var path = root
        if nestWorkspaces {
            var repoName = ((repoPath as NSString).standardizingPath as NSString).lastPathComponent
            if repoName.hasSuffix(".git") { repoName.removeLast(4) }
            path = (path as NSString).appendingPathComponent(repoName)
        }
        path = ((path as NSString).appendingPathComponent(sanitized) as NSString).standardizingPath
        guard isPath(path, inside: root) else { throw .pathOutsideRoot }
        return path
    }

    /// Lexical containment (after standardizing `..`); the root itself does not count.
    public static func isPath(_ path: String, inside root: String) -> Bool {
        let path = (path as NSString).standardizingPath
        var root = (root as NSString).standardizingPath
        if !root.hasSuffix("/") { root += "/" }
        return path.hasPrefix(root) && path.count > root.count
    }
}

// MARK: - Generated names

/// Marine-creature names for empty workspace names, with tiers `name`, `name-2`, …
/// (Orca `retired-name-registry.ts`, `worktree-name-suggestion.ts`).
public enum CreatureNames {
    public static let pool: Set<String> = Set(MarineCreatureNames.all.map { $0.lowercased() })
    static let orderedPool: [String] = MarineCreatureNames.all.map { $0.lowercased() }
    public static let maxTier = 999_999

    public static func name(_ poolName: String, tier: Int) -> String {
        tier == 1 ? poolName : "\(poolName)-\(tier)"
    }

    /// Tier of a name the suggester could emit; nil for user-typed names like `fix-login-2`
    /// and for `nautilus-1` (tier 1 is the bare name).
    public static func tier(of name: String) -> Int? {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if pool.contains(normalized) { return 1 }
        guard let match = normalized.wholeMatch(of: /(.+)-([1-9]\d{0,5})/), pool.contains(String(match.1)),
              let tier = Int(match.2), tier >= 2 else { return nil }
        return tier
    }

    /// A random free name: the lowest tier above `exhaustedTiers` that still has one.
    /// `used` must include retired names as well as live directory basenames.
    public static func suggest<G: RandomNumberGenerator>(used: some Sequence<String>, exhaustedTiers: Int = 0,
                                                         using generator: inout G) -> String {
        let taken = Set(used.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        var tier = RetiredNames.clamp(exhaustedTiers) + 1
        while true {
            let available = orderedPool.map { name($0, tier: tier) }.filter { !taken.contains($0) }
            if let pick = available.randomElement(using: &generator) { return pick }
            tier += 1
        }
    }

    public static func suggest(used: some Sequence<String>, exhaustedTiers: Int = 0) -> String {
        var generator = SystemRandomNumberGenerator()
        return suggest(used: used, exhaustedTiers: exhaustedTiers, using: &generator)
    }
}

/// Per-repo retired generated names. Retirement is permanent; completed tiers fold into
/// `exhaustedTiers` so the list stays about one pool long.
public struct RetiredNames: Equatable, Sendable, Codable {
    public var exhaustedTiers: Int
    public var names: [String]

    public init(exhaustedTiers: Int = 0, names: [String] = []) {
        self.exhaustedTiers = exhaustedTiers
        self.names = names
    }

    static func clamp(_ value: Int) -> Int { value > 0 ? min(value, CreatureNames.maxTier) : 0 }

    public func contains(_ name: String) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if names.contains(normalized) { return true }
        guard let tier = CreatureNames.tier(of: normalized) else { return false }
        return tier <= Self.clamp(exhaustedTiers)
    }

    public func compacted() -> RetiredNames {
        var exhausted = Self.clamp(exhaustedTiers)
        var set = Set(names)
        while exhausted < CreatureNames.maxTier,
              CreatureNames.orderedPool.allSatisfy({ set.contains(CreatureNames.name($0, tier: exhausted + 1)) }) {
            exhausted += 1
        }
        set = set.filter { name in CreatureNames.tier(of: name).map { $0 > exhausted } ?? true }
        return RetiredNames(exhaustedTiers: exhausted, names: names.filter { set.contains($0) }.uniqued())
    }

    /// Nil when nothing new was retired, so callers can skip the write.
    public func adding(_ incoming: some Sequence<String>) -> RetiredNames? {
        let added = incoming.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !contains($0) }.uniqued()
        guard !added.isEmpty else { return nil }
        return RetiredNames(exhaustedTiers: exhaustedTiers, names: names + added).compacted()
    }

    public func merged(with other: RetiredNames) -> RetiredNames {
        RetiredNames(exhaustedTiers: max(exhaustedTiers, other.exhaustedTiers), names: (names + other.names).uniqued())
            .compacted()
    }
}

private extension Array where Element == String {
    func uniqued() -> [String] {
        var seen: Set<String> = []
        return filter { seen.insert($0).inserted }
    }
}

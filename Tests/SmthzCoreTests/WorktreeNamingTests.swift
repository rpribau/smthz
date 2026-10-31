import Foundation
import Testing
@testable import SmthzCore

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

@Test func namingSanitizeTable() throws {
    let table: [(String, String)] = [
        ("../../foo", "foo"),
        ("Fix login", "Fix-login"),
        ("  feature/new  thing ", "feature-new-thing"),
        ("a...b", "a.b"),
        ("--x--", "x"),
        ("a@#$b", "a-b"),
        ("v1.2_rc-3", "v1.2_rc-3"),
        ("日本語 テスト", "日本語-テスト"),
        ("Café niño", "Café-niño"),
        ("🚀", "rocket"),
        ("🚀 fix login", "rocket-fix-login"),
        ("fix🚀login", "fix-rocket-login"),
        ("👍", "thumbsup"),
        ("👎", "thumbsdown"),
        ("✌️", "victory"),
        ("😀", "grinning"),
        ("🇩🇪", "germany"),
        ("👋🏽 hi", "wave-hi"),
    ]
    for (input, expected) in table {
        #expect(try WorktreeNaming.sanitize(input) == expected, "\(input)")
    }
}

@Test func namingSanitizeFallbacksAndErrors() throws {
    // Without a shortcode dataset an emoji-only name still yields a usable directory.
    #expect(try WorktreeNaming.sanitize("🚀🚀", replacingEmoji: false) == "workspace")
    #expect(try WorktreeNaming.sanitize("🚀🚀") == "rocket-rocket")
    for bad in ["", "   ", ".", "..", "...", "///", "-.-"] {
        #expect(throws: WorktreeNamingError.invalidName) { try WorktreeNaming.sanitize(bad) }
    }
    #expect(WorktreeNaming.containsEmoji("a🚀"))
    #expect(!WorktreeNaming.containsEmoji("plain"))
}

@Test func namingEmojiCatalog() {
    #expect(EmojiShortcodes.shortcode(for: "🚀") == "rocket")
    #expect(EmojiShortcodes.shortcode(for: "❤") == EmojiShortcodes.shortcode(for: "❤️"))
    #expect(EmojiShortcodes.shortcode(for: "a") == nil)
    #expect(EmojiShortcodes.entries.count > 2_500)
    #expect(!EmojiShortcodes.entries.contains { $0.shortcode.contains("_tone") })
    #expect(EmojiShortcodes.entries.contains { $0.emoji == "😀" && $0.shortcode == "grinning_face" })
}

@Test func namingBranchPrefixStrategies() throws {
    #expect(WorktreeNaming.normalizeBranchPrefix("team//x/") == "team/x")
    #expect(WorktreeNaming.normalizeBranchPrefix(" /a///b/ ") == "a/b")
    #expect(try WorktreeNaming.branchName(for: "fix", strategy: .gitUsername, gitUsername: "robs") == "robs/fix")
    #expect(try WorktreeNaming.branchName(for: "fix", strategy: .gitUsername, gitUsername: nil) == "fix")
    #expect(try WorktreeNaming.branchName(for: "fix", strategy: .custom, customPrefix: "team//x/") == "team/x/fix")
    #expect(try WorktreeNaming.branchName(for: "fix", strategy: .custom, customPrefix: " / ") == "fix")
    #expect(try WorktreeNaming.branchName(for: "fix", strategy: .none, customPrefix: "ignored", gitUsername: "u") == "fix")
    // An invalid git-username prefix is dropped; an invalid custom prefix fails.
    #expect(try WorktreeNaming.branchName(for: "fix", strategy: .gitUsername, gitUsername: "John Doe") == "fix")
    #expect(throws: WorktreeNamingError.invalidBranchPrefix("bad~prefix")) {
        try WorktreeNaming.branchName(for: "fix", strategy: .custom, customPrefix: "bad~prefix")
    }
    for bad in ["a b", "a~b", "a^b", "a:b", "a?b", "a*b", "a[b", "a\\b", "a..b", "a@{b", "-a", "a.", "a/.b", "a.lock/b", "a\u{7}"] {
        #expect(!WorktreeNaming.isValidBranchPrefix(bad), "\(bad)")
    }
    for good in ["team", "team/frontend", "team./x", "a-b", "a.b", "user_1", ""] {
        #expect(WorktreeNaming.isValidBranchPrefix(good), "\(good)")
    }
}

@Test func namingExplicitBranchName() throws {
    try WorktreeNaming.validateExplicitBranchName("feature/login")
    for bad in ["", "-rf", "/a", "a/", "a//b", "a b", "a..b"] {
        #expect(throws: WorktreeNamingError.invalidBranchName(bad)) { try WorktreeNaming.validateExplicitBranchName(bad) }
    }
}

@Test func namingCollisionCandidates() {
    #expect(WorktreeNaming.maxSuffixAttempts == 100)
    #expect(WorktreeNaming.candidate("fix", attempt: 1) == "fix")
    #expect(WorktreeNaming.candidate("fix", attempt: 2) == "fix-2")
    #expect(WorktreeNaming.candidate("fix", attempt: 100) == "fix-100")
    // Generated names move up tiers instead of stacking suffixes.
    #expect(WorktreeNaming.generatedCandidate("nautilus", attempt: 1) == "nautilus")
    #expect(WorktreeNaming.generatedCandidate("nautilus", attempt: 2) == "nautilus-2")
    #expect(WorktreeNaming.generatedCandidate("nautilus-2", attempt: 2) == "nautilus-3")
    #expect(WorktreeNaming.generatedCandidate("nautilus", attempt: 1, exhaustedTiers: 2) == "nautilus-3")
    #expect(WorktreeNaming.generatedCandidate("nautilus-2-3", attempt: 1) == "nautilus-4")
    #expect(WorktreeNaming.generatedCandidate("fix-login", attempt: 2) == "fix-login-2")
    #expect(WorktreeNaming.isGeneratedName("Nautilus"))
    #expect(WorktreeNaming.isGeneratedName("nautilus-2-3"))
    #expect(!WorktreeNaming.isGeneratedName("fix-login-2"))
    #expect(!WorktreeNaming.isGeneratedName("nautilus-1-1"))
}

@Test func namingCreaturePoolAndTiers() {
    #expect(MarineCreatureNames.all.count == 552)
    #expect(CreatureNames.pool.count == 552)
    #expect(MarineCreatureNames.all.first == "Nautilus")
    #expect(CreatureNames.tier(of: "Nautilus") == 1)
    #expect(CreatureNames.tier(of: "nautilus-2") == 2)
    #expect(CreatureNames.tier(of: "nautilus-1") == nil)
    #expect(CreatureNames.tier(of: "nautilus-0") == nil)
    #expect(CreatureNames.tier(of: "fix-login-2") == nil)
    #expect(CreatureNames.name("coral", tier: 1) == "coral")
    #expect(CreatureNames.name("coral", tier: 3) == "coral-3")
}

@Test func namingSuggestSkipsUsedAndExhaustedTiers() {
    var generator = SeededGenerator(state: 7)
    let first = CreatureNames.suggest(used: [], using: &generator)
    #expect(CreatureNames.tier(of: first) == 1)
    let allButOne = CreatureNames.orderedPool.filter { $0 != "coral" } + ["NAUTILUS"]
    #expect(CreatureNames.suggest(used: allButOne, using: &generator) == "coral")
    let tierTwo = CreatureNames.suggest(used: CreatureNames.orderedPool, using: &generator)
    #expect(CreatureNames.tier(of: tierTwo) == 2)
    #expect(CreatureNames.tier(of: CreatureNames.suggest(used: [], exhaustedTiers: 4, using: &generator)) == 5)
}

@Test func namingRetiredRegistryCompacts() throws {
    let empty = RetiredNames()
    #expect(empty.adding([]) == nil)
    let one = try #require(empty.adding(["Nautilus", "fix-login"]))
    #expect(one.names == ["nautilus", "fix-login"] && one.exhaustedTiers == 0)
    #expect(one.contains("nautilus") && !one.contains("coral"))
    #expect(one.adding(["nautilus"]) == nil)
    // Completing tier 1 folds it into the watermark; higher-tier names wait.
    let full = try #require(one.adding(CreatureNames.orderedPool + ["coral-2"]))
    #expect(full.exhaustedTiers == 1)
    #expect(full.names == ["fix-login", "coral-2"])
    #expect(full.contains("Octopus") && full.contains("coral-2") && !full.contains("octopus-2"))
    let merged = RetiredNames(names: ["octopus-2"]).merged(with: full)
    #expect(merged.exhaustedTiers == 1 && Set(merged.names) == ["fix-login", "coral-2", "octopus-2"])
    let decoded = try JSONDecoder().decode(RetiredNames.self, from: JSONEncoder().encode(full))
    #expect(decoded == full)
}

@Test func namingWorktreePaths() throws {
    #expect(try WorktreeNaming.worktreePath(sanitized: "fix", repoPath: "/src/app.git", workspaceRoot: "/ws",
                                            nestWorkspaces: true) == "/ws/app/fix")
    #expect(try WorktreeNaming.worktreePath(sanitized: "fix", repoPath: "/src/app/", workspaceRoot: "/ws/",
                                            nestWorkspaces: false) == "/ws/fix")
    #expect(throws: WorktreeNamingError.pathOutsideRoot) {
        try WorktreeNaming.worktreePath(sanitized: "../escape", repoPath: "/src/app", workspaceRoot: "/ws", nestWorkspaces: false)
    }
    #expect(throws: WorktreeNamingError.pathOutsideRoot) {
        try WorktreeNaming.worktreePath(sanitized: "..", repoPath: "/src/app", workspaceRoot: "/ws", nestWorkspaces: false)
    }
    #expect(WorktreeNaming.isPath("/ws/a/b", inside: "/ws"))
    #expect(!WorktreeNaming.isPath("/ws", inside: "/ws"))
    #expect(!WorktreeNaming.isPath("/wsx/a", inside: "/ws"))
}

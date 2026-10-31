import Foundation
import Testing
@testable import SmthzCore

private func parse(_ text: String) throws -> SmthzConfig { try SmthzConfigParser.parse(text) }

private func rejection(_ text: String) -> SmthzConfigError? {
    do { _ = try SmthzConfigParser.parse(text); return nil } catch { return error }
}

private struct ConfigRepo {
    let root: String
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("smthz-config-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }
    func write(_ relative: String, _ text: String) throws {
        let path = (root as NSString).appendingPathComponent(relative)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }
    func cleanup() { try? FileManager.default.removeItem(atPath: root) }
}

@Test func configParsesDocumentedExample() throws {
    let config = try parse("""
    scripts:
      setup: |
        pnpm install
      archive: |
        echo Workspace archived
    setupAgentStartupPolicy: wait-for-setup
    issueCommand: |
      echo "Linked item: {{artifact_url}}"
    defaultTabs:
      - title: Agent
      - title: Git status
        command: git status --short
        color: "#3b82f6"
    worktree:
      sharedDirectories:
        - .cache
    """)
    #expect(config.setupScript == "pnpm install")
    #expect(config.archiveScript == "echo Workspace archived")
    #expect(config.setupAgentStartupPolicy == .waitForSetup)
    #expect(config.issueCommand == "echo \"Linked item: {{artifact_url}}\"")
    #expect(config.defaultTabs == [.init(title: "Agent"),
                                   .init(title: "Git status", command: "git status --short", color: "#3b82f6")])
    #expect(config.sharedDirectories == [".cache"])
    #expect(config.diagnostics.isEmpty)
}

@Test func configKeysAreOptionalAndUnknownKeysIgnored() throws {
    #expect(try parse("{}").isEmpty)
    let config = try parse("setupRunPolicy: ask\nfoo: 1\nissueCommand: run {{issue}}\n")
    #expect(config.issueCommand == "run {{issue}}")
    #expect(config.diagnostics.contains("Unknown key \"setupRunPolicy\" ignored"))
    #expect(config.diagnostics.contains("Unknown key \"foo\" ignored"))
}

@Test func configInvalidFieldsDropValidSiblingsApply() throws {
    let config = try parse("""
    scripts:
      setup: 42
      archive: "  "
    setupAgentStartupPolicy: later
    issueCommand: [a]
    defaultTabs:
      - title: Ok
      - plain string
      - command: ""
    worktree:
      sharedDirectories: [node_modules]
    """)
    #expect(config.setupScript == nil)
    #expect(config.archiveScript == nil)
    #expect(config.setupAgentStartupPolicy == nil)
    #expect(config.issueCommand == nil)
    #expect(config.defaultTabs == [.init(title: "Ok")])
    #expect(config.sharedDirectories == ["node_modules"])
    #expect(config.diagnostics.contains("scripts.setup must be a string"))
    #expect(config.diagnostics.contains("defaultTabs[1] must be a mapping"))
    #expect(config.diagnostics.contains("defaultTabs[2] has no valid field"))
}

@Test func configContainerTypesAreEnforced() throws {
    let config = try parse("""
    scripts: echo hi
    defaultTabs: {title: x}
    worktree: [a]
    environmentRecipes: nope
    """)
    #expect(config.isEmpty)
    #expect(config.diagnostics.contains("scripts must be a mapping"))
    #expect(config.diagnostics.contains("defaultTabs must be a list"))
    #expect(config.diagnostics.contains("worktree must be a mapping"))
    #expect(config.diagnostics.contains("environmentRecipes must be a list"))
    let shared = try parse("worktree:\n  sharedDirectories: node_modules\n")
    #expect(shared.sharedDirectories.isEmpty)
    #expect(shared.diagnostics.contains("worktree.sharedDirectories must be a list"))
}

@Test func configRejectsInvalidYAMLAndNonMappingRoot() {
    #expect(rejection("scripts:\n  setup: [unclosed\n").map { if case .invalidYAML = $0 { true } else { false } } == true)
    #expect(rejection("- a\n- b\n") == .rootNotMapping)
    #expect(rejection("just text") == .rootNotMapping)
    #expect(rejection("") == .rootNotMapping)
    #expect(rejection("a: 1\n---\nb: 2\n").map { if case .invalidYAML = $0 { true } else { false } } == true)
    #expect(throws: SmthzConfigError.invalidEncoding) { try SmthzConfigParser.parse(data: Data([0x61, 0x3A, 0x20, 0xFF])) }
}

/// Yams 6.2.2 itself throws `duplicatedKeysInMapping` while composing (verified here, M4-D2).
@Test func configRejectsDuplicateKeysAnywhere() {
    #expect(rejection("issueCommand: a\nissueCommand: b\n") == .duplicateKey("issueCommand"))
    #expect(rejection("scripts:\n  setup: a\n  setup: b\n") == .duplicateKey("setup"))
    #expect(rejection("defaultTabs:\n  - title: a\n    title: b\n") == .duplicateKey("title"))
    #expect(rejection("unknown:\n  x: 1\n  x: 2\n") == .duplicateKey("x"))
    #expect(rejection("{a: 1, a: 2}") == .duplicateKey("a"))
}

@Test func configFileSizeLimit() throws {
    let base = "issueCommand: x\n#"
    let fits = base + String(repeating: "a", count: SmthzConfigParser.maxFileBytes - base.utf8.count)
    #expect(fits.utf8.count == 262_144)
    #expect(try parse(fits).issueCommand == "x")
    #expect(rejection(fits + "a") == .fileTooLarge)
    #expect(throws: SmthzConfigError.fileTooLarge) { try SmthzConfigParser.parse(data: Data((fits + "a").utf8)) }
    // Multi-byte text counts UTF-8 bytes, not characters.
    let wide = "a: x\n#" + String(repeating: "é", count: 131_070)
    #expect(wide.count < 262_144 && wide.utf8.count > 262_144)
    #expect(rejection(wide) == .fileTooLarge)
}

@Test func configFieldSizeLimit() throws {
    let big = String(repeating: "a", count: 65_536)
    #expect(try parse("issueCommand: \(big)\n").issueCommand == big)
    let config = try parse("issueCommand: \(big)a\nscripts:\n  setup: ok\n")
    #expect(config.issueCommand == nil)
    #expect(config.setupScript == "ok")
    // Measured before trimming: padding that pushes the raw value over the limit drops it.
    #expect(try parse("issueCommand: \"\(big) \"\n").issueCommand == nil)
}

@Test func configAliasesAndMerges() throws {
    let config = try parse("""
    base: &tab {title: Shared, color: "#fff"}
    defaultTabs:
      - *tab
      - <<: *tab
        title: Override
      - <<: [*tab]
        command: ls
    """)
    #expect(config.defaultTabs == [.init(title: "Shared", color: "#fff"),
                                   .init(title: "Override", color: "#fff"),
                                   .init(title: "Shared", command: "ls", color: "#fff")])
    #expect(rejection("a: &a 1\nb:\n  <<: *a\n") == .invalidMerge)
    #expect(rejection("a: *missing\n").map { if case .invalidYAML = $0 { true } else { false } } == true)
}

@Test func configRejectsAliasBomb() {
    var bomb = "a0: &a0 [x, x, x, x, x, x, x, x, x]\n"
    for level in 1...9 {
        let refs = Array(repeating: "*a\(level - 1)", count: 9).joined(separator: ", ")
        bomb += "a\(level): &a\(level) [\(refs)]\n"
    }
    #expect(rejection(bomb) == .aliasLimitExceeded)
    // Ordinary reuse stays within the budget: 100 expansions pass, 101 do not.
    let reuse = "x: &x hi\nl: [" + Array(repeating: "*x", count: 100).joined(separator: ", ") + "]\n"
    #expect(rejection(reuse) == nil)
    #expect(rejection("x: &x hi\nl: [" + Array(repeating: "*x", count: 101).joined(separator: ", ") + "]\n")
            == .aliasLimitExceeded)
}

@Test func configDefaultTabColorsAndLimits() throws {
    let config = try parse("""
    defaultTabs:
      - {title: a, color: "#abc"}
      - {title: b, color: "#A1B2C3"}
      - {title: c, color: red}
      - {title: d, color: "#abcd"}
      - {color: "#12"}
      - {color: "#0f0"}
    """)
    #expect(config.defaultTabs == [.init(title: "a", color: "#abc"), .init(title: "b", color: "#A1B2C3"),
                                   .init(title: "c"), .init(title: "d"), .init(color: "#0f0")])
    #expect(config.diagnostics.contains("defaultTabs[2].color \"red\" is not #RGB or #RRGGBB"))
    #expect(config.diagnostics.contains("defaultTabs[4] has no valid field"))
    let entries = { (n: Int) in "defaultTabs:\n" + String(repeating: "  - title: t\n", count: n) }
    #expect(try parse(entries(256)).defaultTabs.count == 256)
    #expect(try parse(entries(257)).defaultTabs.isEmpty)
}

@Test func configSharedDirectoryNormalization() throws {
    let config = try parse(#"""
    worktree:
      sharedDirectories:
        - ./node_modules/
        - node_modules
        - 'apps\web\.cache'
        - ../x
        - .git/x
        - a/.git
        - /abs
        - C:/x
        - a//b
        - a/./b
        - .
        - ""
        - 7
    """#)
    #expect(config.sharedDirectories == ["node_modules", "apps/web/.cache"])
    for raw in ["../x", ".git/x", "x/..", "a/.git/b", "/tmp", "c:\\x", "a//b", "a/./b", ".", "  "] {
        #expect(SmthzConfigParser.normalizeSharedDirectory(raw) == nil, "\(raw)")
    }
    #expect(SmthzConfigParser.normalizeSharedDirectory(" .cache// ") == ".cache")
    let many = "worktree:\n  sharedDirectories:\n" + (0..<120).map { "    - d\($0)\n" }.joined()
    let limited = try parse(many).sharedDirectories
    #expect(limited.count == 100 && limited.last == "d99")
}

@Test func configUsesYAML12CoreScalars() throws {
    let config = try parse("""
    defaultTabs:
      - title: yes
      - title: on
      - title: true
      - title: 12
      - title: "12"
      - title: ~
    """)
    #expect(config.defaultTabs.map(\.title) == ["yes", "on", "12"])
}

@Test func configEnvironmentRecipesAreParsedAndIgnored() throws {
    let config = try parse("environmentRecipes:\n  - id: vm\n    name: VM\n    create: make vm\n")
    #expect(config.environmentRecipeCount == 1)
    #expect(!config.isEmpty)
    #expect(config.diagnostics == ["environmentRecipes (1) ignored: not supported yet"])
}

@Test func configParsesOrcaRepositoryFile() throws {
    let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("reference/orca-1.4.238").path
    let file = try #require(SmthzConfigLoader.load(repoRoot: repoRoot))
    #expect(file.source == .orca)
    let setup = try #require(file.config?.setupScript)
    #expect(setup.contains("pnpm install"))
}

@Test func configLoaderPrefersSmthzYAMLWithoutMerging() throws {
    let repo = try ConfigRepo()
    defer { repo.cleanup() }
    #expect(SmthzConfigLoader.load(repoRoot: repo.root) == nil)
    try repo.write("orca.yaml", "scripts:\n  setup: orca-setup\n")
    let orca = try #require(SmthzConfigLoader.load(repoRoot: repo.root))
    #expect(orca.source == .orca && orca.config?.setupScript == "orca-setup")
    try repo.write("smthz.yaml", "issueCommand: smthz\n")
    let smthz = try #require(SmthzConfigLoader.load(repoRoot: repo.root))
    #expect(smthz.source == .smthz && smthz.config?.setupScript == nil && smthz.config?.issueCommand == "smthz")
    // An invalid smthz.yaml still wins: nothing falls back to orca.yaml.
    try repo.write("smthz.yaml", "a: 1\na: 2\n")
    let broken = try #require(SmthzConfigLoader.load(repoRoot: repo.root))
    #expect(broken.source == .smthz && broken.config == nil)
    #expect(broken.result == .failure(.duplicateKey("a")))
    try repo.write("smthz.yaml", "#" + String(repeating: "x", count: 262_144))
    #expect(SmthzConfigLoader.load(repoRoot: repo.root)?.result == .failure(.fileTooLarge))
}

@Test func configIssueCommandOverrideAndSetupEnvironment() throws {
    let repo = try ConfigRepo()
    defer { repo.cleanup() }
    #expect(SmthzConfigLoader.issueCommandOverride(repoRoot: repo.root) == nil)
    try repo.write(".orca/issue-command", " orca {{artifact_url}}\n")
    #expect(SmthzConfigLoader.issueCommandOverride(repoRoot: repo.root) == "orca {{artifact_url}}")
    try repo.write(".smthz/issue-command", "  \n")
    #expect(SmthzConfigLoader.issueCommandOverride(repoRoot: repo.root) == "orca {{artifact_url}}")
    try repo.write(".smthz/issue-command", "smthz\n")
    #expect(SmthzConfigLoader.issueCommandOverride(repoRoot: repo.root) == "smthz")

    let own = SmthzConfigLoader.setupEnvironment(rootPath: "/r", worktreePath: "/w/fix", source: .smthz)
    #expect(own == ["SMTHZ_ROOT_PATH": "/r", "SMTHZ_WORKTREE_PATH": "/w/fix", "SMTHZ_WORKSPACE_NAME": "fix"])
    let orca = SmthzConfigLoader.setupEnvironment(rootPath: "/r", worktreePath: "/w/fix", source: .orca)
    #expect(orca["ORCA_ROOT_PATH"] == "/r" && orca["ORCA_WORKTREE_PATH"] == "/w/fix" && orca["ORCA_WORKSPACE_NAME"] == "fix")
    #expect(orca["CONDUCTOR_ROOT_PATH"] == "/r" && orca["GHOSTX_ROOT_PATH"] == "/r" && orca.count == 8)
}

@Test func configTrustHashIsSHA256() {
    #expect(SmthzConfigTrust.contentHash("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
}

// MARK: - .worktreeinclude

@Test func worktreeIncludeParsesLiteralPaths() {
    let parsed = WorktreeInclude.parse("""
    # secrets
    .env

    ./.env.local
    .vscode/settings.json # not a comment
    config\\local\\
    .env
    *.pem
    src/?.txt
    !keep
    ../outside
    .git/config
    sub/.git/x
    a//b
    /abs
    """)
    #expect(parsed.candidates == [".env", ".env.local", ".vscode/settings.json # not a comment", "config/local"])
    #expect(parsed.warnings.filter { $0.contains("unsupported") }.count == 3)
    #expect(parsed.warnings.filter { $0.contains("unsafe") }.count == 5)
    #expect(WorktreeInclude.parse("a\r\nb\r\n").candidates == ["a", "b"])
}

@Test func worktreeIncludeCandidateLimit() {
    let text = (0..<1_005).map { "f\($0)" }.joined(separator: "\n")
    let parsed = WorktreeInclude.parse(text)
    #expect(parsed.candidates.count == 1_000)
    #expect(parsed.warnings == [".worktreeinclude lists more than 1000 entries; ignoring the rest"])
}

@Test func worktreeIncludeFileLimits() throws {
    let repo = try ConfigRepo()
    defer { repo.cleanup() }
    #expect(WorktreeInclude.load(repoRoot: repo.root) == nil)
    try repo.write("real-include", ".env\n")
    try FileManager.default.createSymbolicLink(atPath: (repo.root as NSString).appendingPathComponent(".worktreeinclude"),
                                               withDestinationPath: "real-include")
    #expect(WorktreeInclude.load(repoRoot: repo.root) == nil)
    try FileManager.default.removeItem(atPath: (repo.root as NSString).appendingPathComponent(".worktreeinclude"))
    try repo.write(".worktreeinclude", ".env\n#" + String(repeating: "x", count: 256 * 1024 - 6))
    #expect(WorktreeInclude.load(repoRoot: repo.root)?.candidates == [".env"])
    try repo.write(".worktreeinclude", ".env\n#" + String(repeating: "x", count: 256 * 1024 - 5))
    #expect(WorktreeInclude.load(repoRoot: repo.root) == nil)
}

import CryptoKit
import Foundation
import Yams

/// Per-repo project defaults read from `smthz.yaml` (or, when absent, Orca's `orca.yaml`).
/// Same keys and rules as Orca 1.4.238 `src/shared/orca-yaml.ts` (M4-PLAN §7.2).
public struct SmthzConfig: Equatable, Sendable {
    public enum SetupAgentStartupPolicy: String, Equatable, Sendable {
        case startImmediately = "start-immediately"
        case waitForSetup = "wait-for-setup"
    }

    public struct DefaultTab: Equatable, Sendable {
        public var title: String?
        public var command: String?
        /// `#RGB` or `#RRGGBB`, as written in the file.
        public var color: String?
        public init(title: String? = nil, command: String? = nil, color: String? = nil) {
            self.title = title
            self.command = command
            self.color = color
        }
    }

    public var setupScript: String?
    public var archiveScript: String?
    public var setupAgentStartupPolicy: SetupAgentStartupPolicy?
    public var issueCommand: String?
    public var defaultTabs: [DefaultTab]
    /// Normalized, deduped repo-relative directories (first 100 input entries).
    public var sharedDirectories: [String]
    /// `environmentRecipes` entries seen; recipes are parsed and ignored until M8-VM.
    public var environmentRecipeCount: Int
    /// Non-fatal notes: dropped fields, ignored keys. A rejected file throws instead.
    public var diagnostics: [String]

    public init(setupScript: String? = nil, archiveScript: String? = nil,
                setupAgentStartupPolicy: SetupAgentStartupPolicy? = nil, issueCommand: String? = nil,
                defaultTabs: [DefaultTab] = [], sharedDirectories: [String] = [],
                environmentRecipeCount: Int = 0, diagnostics: [String] = []) {
        self.setupScript = setupScript
        self.archiveScript = archiveScript
        self.setupAgentStartupPolicy = setupAgentStartupPolicy
        self.issueCommand = issueCommand
        self.defaultTabs = defaultTabs
        self.sharedDirectories = sharedDirectories
        self.environmentRecipeCount = environmentRecipeCount
        self.diagnostics = diagnostics
    }

    /// Orca treats a file that configures nothing as absent.
    public var isEmpty: Bool {
        setupScript == nil && archiveScript == nil && setupAgentStartupPolicy == nil && issueCommand == nil
            && defaultTabs.isEmpty && sharedDirectories.isEmpty && environmentRecipeCount == 0
    }
}

/// Reasons the whole file is rejected (no configuration applies).
public enum SmthzConfigError: Error, Equatable, Sendable {
    case fileTooLarge
    case invalidEncoding
    case invalidYAML(String)
    case duplicateKey(String)
    case rootNotMapping
    case aliasLimitExceeded
    case conversionBudgetExceeded
    case invalidMerge
}

public enum SmthzConfigParser {
    public static let maxFileBytes = 256 * 1024
    public static let maxFieldBytes = 64 * 1024
    public static let maxCollectionEntries = 256
    public static let maxSharedDirectories = 100
    /// Orca passes `maxAliasCount: 100` to `yaml`; here every alias dereference made while
    /// expanding the document counts, so nested alias bombs hit the limit long before they expand.
    public static let maxAliasExpansions = 100
    /// Mirrors Orca's merge-conversion budget (the source-text cap reused as a node budget).
    public static let maxConvertedNodes = 256 * 1024

    public static func parse(data: Data) throws(SmthzConfigError) -> SmthzConfig {
        guard data.count <= maxFileBytes else { throw .fileTooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw .invalidEncoding }
        return try parse(text)
    }

    public static func parse(_ text: String) throws(SmthzConfigError) -> SmthzConfig {
        // Orca caps both UTF-8 bytes and UTF-16 code units.
        guard text.utf8.count <= maxFileBytes, text.utf16.count <= maxFileBytes else { throw .fileTooLarge }
        let root: Value
        do {
            let parser = try Parser(yaml: text, resolver: coreSchema)
            root = try withExtendedLifetime(parser) {
                // Anchors are weak on Yams nodes; the parser keeps them alive while converting.
                guard let node = try parser.singleRoot() else { return Value.other }
                var converter = Converter()
                return try converter.convert(node)
            }
        } catch let error as SmthzConfigError {
            throw error
        } catch let YamlError.duplicatedKeysInMapping(duplicates, _) {
            throw .duplicateKey(duplicates.joined(separator: ", "))
        } catch {
            throw .invalidYAML(String(describing: error))
        }
        guard case .mapping(let pairs) = root else { throw .rootNotMapping }
        return build(from: pairs)
    }

    /// Normalizes one `worktree.sharedDirectories` entry, or nil when it must be dropped.
    /// Entries that would still need collapsing (`a/./b`) are dropped, as in Orca.
    public static func normalizeSharedDirectory(_ raw: String) -> String? {
        guard let trimmed = trimmedField(raw) else { return nil }
        var path = trimmed.replacingOccurrences(of: "\\", with: "/")
        if path.hasPrefix("./") { path.removeFirst(2) }
        while path.hasSuffix("/") { path.removeLast() }
        guard !path.isEmpty, !path.hasPrefix("/"), !hasDrivePrefix(path) else { return nil }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !segments.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0 == ".git" }) else { return nil }
        return path
    }

    static func hasDrivePrefix(_ path: String) -> Bool {
        let chars = Array(path.prefix(2))
        return chars.count == 2 && chars[1] == ":" && chars[0].isASCII && chars[0].isLetter
    }

    /// Fields over 64 KiB (measured before trimming) are dropped; blank values count as absent.
    static func trimmedField(_ value: String) -> String? {
        guard value.utf8.count <= maxFieldBytes, value.utf16.count <= maxFieldBytes else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Building

    private static func build(from pairs: [(String?, Value)]) -> SmthzConfig {
        var config = SmthzConfig()
        let root = Dictionary(pairs.compactMap { key, value in key.map { ($0, value) } }, uniquingKeysWith: { first, _ in first })
        let known: Set<String> = ["scripts", "setupAgentStartupPolicy", "issueCommand", "defaultTabs",
                                  "environmentRecipes", "worktree"]
        for key in root.keys.sorted() where !known.contains(key) {
            config.diagnostics.append("Unknown key \"\(key)\" ignored")
        }

        if let scripts = root["scripts"] {
            if case .mapping(let scriptPairs) = scripts {
                let map = dictionary(scriptPairs)
                config.setupScript = string(map["setup"], key: "scripts.setup", into: &config)
                config.archiveScript = string(map["archive"], key: "scripts.archive", into: &config)
            } else {
                config.diagnostics.append("scripts must be a mapping")
            }
        }
        if let policy = root["setupAgentStartupPolicy"] {
            if case .string(let raw) = policy, let value = SmthzConfig.SetupAgentStartupPolicy(rawValue: raw) {
                config.setupAgentStartupPolicy = value
            } else {
                config.diagnostics.append("setupAgentStartupPolicy must be start-immediately or wait-for-setup")
            }
        }
        config.issueCommand = string(root["issueCommand"], key: "issueCommand", into: &config)
        if let tabs = root["defaultTabs"] { config.defaultTabs = defaultTabs(tabs, into: &config) }
        if let recipes = root["environmentRecipes"] {
            if case .sequence(let items) = recipes {
                config.environmentRecipeCount = items.count
                if !items.isEmpty {
                    config.diagnostics.append("environmentRecipes (\(items.count)) ignored: not supported yet")
                }
            } else {
                config.diagnostics.append("environmentRecipes must be a list")
            }
        }
        if let worktree = root["worktree"] {
            if case .mapping(let worktreePairs) = worktree {
                if let shared = dictionary(worktreePairs)["sharedDirectories"] {
                    config.sharedDirectories = sharedDirectories(shared, into: &config)
                }
            } else {
                config.diagnostics.append("worktree must be a mapping")
            }
        }
        return config
    }

    private static func dictionary(_ pairs: [(String?, Value)]) -> [String: Value] {
        Dictionary(pairs.compactMap { key, value in key.map { ($0, value) } }, uniquingKeysWith: { first, _ in first })
    }

    private static func string(_ value: Value?, key: String, into config: inout SmthzConfig) -> String? {
        guard let value else { return nil }
        guard case .string(let raw) = value else {
            config.diagnostics.append("\(key) must be a string")
            return nil
        }
        guard let trimmed = trimmedField(raw) else {
            config.diagnostics.append("\(key) is empty or larger than 64 KiB")
            return nil
        }
        return trimmed
    }

    private static func defaultTabs(_ value: Value, into config: inout SmthzConfig) -> [SmthzConfig.DefaultTab] {
        guard case .sequence(let items) = value else {
            config.diagnostics.append("defaultTabs must be a list")
            return []
        }
        guard items.count <= maxCollectionEntries else {
            config.diagnostics.append("defaultTabs has more than \(maxCollectionEntries) entries; list dropped")
            return []
        }
        var tabs: [SmthzConfig.DefaultTab] = []
        for (index, item) in items.enumerated() {
            guard case .mapping(let pairs) = item else {
                config.diagnostics.append("defaultTabs[\(index)] must be a mapping")
                continue
            }
            let map = dictionary(pairs)
            let title = string(map["title"], key: "defaultTabs[\(index)].title", into: &config)
            let command = string(map["command"], key: "defaultTabs[\(index)].command", into: &config)
            var color = string(map["color"], key: "defaultTabs[\(index)].color", into: &config)
            if let candidate = color, !isValidTabColor(candidate) {
                config.diagnostics.append("defaultTabs[\(index)].color \"\(candidate)\" is not #RGB or #RRGGBB")
                color = nil
            }
            guard title != nil || command != nil || color != nil else {
                config.diagnostics.append("defaultTabs[\(index)] has no valid field")
                continue
            }
            tabs.append(.init(title: title, command: command, color: color))
        }
        return tabs
    }

    static func isValidTabColor(_ value: String) -> Bool {
        let hex = value.utf8.dropFirst()
        return value.hasPrefix("#") && (hex.count == 3 || hex.count == 6)
            && hex.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }

    private static func sharedDirectories(_ value: Value, into config: inout SmthzConfig) -> [String] {
        guard case .sequence(let items) = value else {
            config.diagnostics.append("worktree.sharedDirectories must be a list")
            return []
        }
        if items.count > maxSharedDirectories {
            config.diagnostics.append("worktree.sharedDirectories: entries after the first \(maxSharedDirectories) ignored")
        }
        var seen: Set<String> = []
        var result: [String] = []
        for (index, item) in items.prefix(maxSharedDirectories).enumerated() {
            guard case .string(let raw) = item, let path = normalizeSharedDirectory(raw) else {
                config.diagnostics.append("worktree.sharedDirectories[\(index)] rejected")
                continue
            }
            if seen.insert(path).inserted { result.append(path) }
        }
        return result
    }

    // MARK: - YAML conversion

    /// YAML 1.2 core schema (what Orca's `yaml` package uses): `yes`/`on` stay strings.
    // swiftlint:disable force_try
    static let coreSchema: Resolver = Resolver.basic
        .appending(try! Resolver.Rule(.null, "^(?:~|null|Null|NULL|)$"))
        .appending(try! Resolver.Rule(.bool, "^(?:true|True|TRUE|false|False|FALSE)$"))
        .appending(try! Resolver.Rule(.int, "^(?:[-+]?[0-9]+|0o[0-7]+|0x[0-9a-fA-F]+)$"))
        .appending(try! Resolver.Rule(.float, "^(?:[-+]?(?:\\.[0-9]+|[0-9]+(?:\\.[0-9]*)?)(?:[eE][-+]?[0-9]+)?|[-+]?\\.(?:inf|Inf|INF)|\\.(?:nan|NaN|NAN))$"))
        .appending(Resolver.Rule.merge)
    // swiftlint:enable force_try

    indirect enum Value {
        case string(String)
        /// Any non-string scalar (null, bool, number, timestamp, custom tag).
        case other
        case sequence([Value])
        /// Keys are nil when not strings; merges (`<<`) already applied.
        case mapping([(String?, Value)])
    }

    struct Converter {
        var seenAnchors: Set<ObjectIdentifier> = []
        var aliasExpansions = 0
        var nodes = 0

        mutating func convert(_ node: Node) throws(SmthzConfigError) -> Value {
            nodes += 1
            guard nodes <= SmthzConfigParser.maxConvertedNodes else { throw .conversionBudgetExceeded }
            // Yams hands back the anchored node itself for every alias: the first visit is the
            // definition, every later visit of the same anchor is an alias expansion.
            if let anchor = node.anchor, !seenAnchors.insert(ObjectIdentifier(anchor)).inserted {
                aliasExpansions += 1
                guard aliasExpansions <= SmthzConfigParser.maxAliasExpansions else { throw .aliasLimitExceeded }
            }
            switch node {
            case .scalar(let scalar):
                return node.tag.description == Tag.Name.str.rawValue ? .string(scalar.string) : .other
            case .sequence(let sequence):
                var items: [Value] = []
                for item in sequence { items.append(try convert(item)) }
                return .sequence(items)
            case .mapping(let mapping):
                return .mapping(try convertMapping(mapping))
            case .alias:
                throw .invalidYAML("unresolved alias")
            }
        }

        private mutating func convertMapping(_ mapping: Node.Mapping) throws(SmthzConfigError) -> [(String?, Value)] {
            var explicit: [(String?, Value)] = []
            var merged: [(String?, Value)] = []
            for (key, value) in mapping {
                if case .scalar(let scalar) = key, scalar.style == .plain, key.tag.description == Tag.Name.merge.rawValue {
                    nodes += 1
                    let sources: [Value]
                    switch value {
                    case .sequence(let sequence):
                        var items: [Value] = []
                        for item in sequence { items.append(try convert(item)) }
                        sources = items
                    default:
                        sources = [try convert(value)]
                    }
                    for source in sources {
                        guard case .mapping(let pairs) = source else { throw .invalidMerge }
                        merged.append(contentsOf: pairs)
                    }
                    continue
                }
                let convertedKey = try convert(key)
                let name: String? = if case .string(let text) = convertedKey { text } else { nil }
                explicit.append((name, try convert(value)))
            }
            guard !merged.isEmpty else { return explicit }
            // Explicit keys win over merged ones; among merge sources the first wins.
            var present = Set(explicit.compactMap(\.0))
            var result = explicit
            for (key, value) in merged {
                if let key, !present.insert(key).inserted { continue }
                result.append((key, value))
            }
            return result
        }
    }
}

// MARK: - File lookup

public struct SmthzConfigFile: Equatable, Sendable {
    public enum Source: String, Equatable, Sendable {
        case smthz = "smthz.yaml"
        case orca = "orca.yaml"
    }

    public var source: Source
    public var path: String
    /// Rejected files configure nothing; the error is kept for the UI.
    public var result: Result<SmthzConfig, SmthzConfigError>

    public var config: SmthzConfig? { try? result.get() }
}

extension SmthzConfigError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .fileTooLarge: "file is larger than 256 KiB"
        case .invalidEncoding: "file is not UTF-8"
        case .invalidYAML(let message): "invalid YAML: \(message)"
        case .duplicateKey(let key): "duplicate mapping key: \(key)"
        case .rootNotMapping: "top level must be a mapping"
        case .aliasLimitExceeded: "too many alias expansions"
        case .conversionBudgetExceeded: "document expands to too many nodes"
        case .invalidMerge: "merge key (<<) source must be a mapping"
        }
    }
}

public enum SmthzConfigLoader {
    public static let issueCommandOverridePaths = [".smthz/issue-command", ".orca/issue-command"]

    /// `smthz.yaml` wins entirely when present (even if invalid); `orca.yaml` is read only
    /// when it is absent (M4-D1 a). Returns nil when neither file exists.
    public static func load(repoRoot: String) -> SmthzConfigFile? {
        for source in [SmthzConfigFile.Source.smthz, .orca] {
            let path = (repoRoot as NSString).appendingPathComponent(source.rawValue)
            guard let size = regularFileSize(path) else { continue }
            guard size <= SmthzConfigParser.maxFileBytes else {
                return .init(source: source, path: path, result: .failure(.fileTooLarge))
            }
            guard let data = FileManager.default.contents(atPath: path) else {
                return .init(source: source, path: path, result: .failure(.invalidYAML("unreadable file")))
            }
            return .init(source: source, path: path, result: Result { () throws(SmthzConfigError) in
                try SmthzConfigParser.parse(data: data)
            })
        }
        return nil
    }

    /// Non-empty `.smthz/issue-command`, then `.orca/issue-command`; nil when neither applies.
    public static func issueCommandOverride(repoRoot: String) -> String? {
        for relative in issueCommandOverridePaths {
            let path = (repoRoot as NSString).appendingPathComponent(relative)
            guard let size = regularFileSize(path), size <= SmthzConfigParser.maxFieldBytes,
                  let data = FileManager.default.contents(atPath: path),
                  let text = String(data: data, encoding: .utf8),
                  let command = SmthzConfigParser.trimmedField(text) else { continue }
            return command
        }
        return nil
    }

    /// Environment for the setup runner. Orca's names are added only for `orca.yaml` repos
    /// so Orca-authored scripts keep working (`R/src/main/setup-hook-env-vars.ts`).
    public static func setupEnvironment(rootPath: String, worktreePath: String,
                                        source: SmthzConfigFile.Source) -> [String: String] {
        let name = (worktreePath as NSString).lastPathComponent
        var env = ["SMTHZ_ROOT_PATH": rootPath, "SMTHZ_WORKTREE_PATH": worktreePath, "SMTHZ_WORKSPACE_NAME": name]
        if source == .orca {
            env["ORCA_ROOT_PATH"] = rootPath
            env["ORCA_WORKTREE_PATH"] = worktreePath
            env["ORCA_WORKSPACE_NAME"] = name
            env["CONDUCTOR_ROOT_PATH"] = rootPath
            env["GHOSTX_ROOT_PATH"] = rootPath
        }
        return env
    }

    /// Size of a regular file; symlinks are followed (Orca reads these files with `readFileSync`).
    static func regularFileSize(_ path: String) -> Int? {
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return Int(info.st_size)
    }
}

/// Trust for shared (YAML) hook scripts is keyed by the SHA-256 of the script text.
public enum SmthzConfigTrust {
    public static func contentHash(_ script: String) -> String {
        SHA256.hash(data: Data(script.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

import Foundation

/// Pure logic behind the New Workspace composer, the sidebar creation progress row and the
/// worktree dialogs (WP-M4-WORKTREE-APP). No UI and no I/O, so it is unit tested here.
public enum WorkspaceComposerLogic {
    // MARK: :shortcode: suggestions

    /// The trailing `:partial` token being typed (at least one character after the colon).
    public static func shortcodeQuery(in text: String) -> (range: Range<String.Index>, partial: String)? {
        guard let colon = text.lastIndex(of: ":") else { return nil }
        let partial = text[text.index(after: colon)...]
        guard !partial.isEmpty, partial.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "+" || $0 == "-" }) else { return nil }
        // An opening colon follows whitespace or the start; "a:b" inside a word is not a query.
        if colon > text.startIndex, !text[text.index(before: colon)].isWhitespace { return nil }
        return (colon..<text.endIndex, partial.lowercased())
    }

    /// Prefix matches first (shorter codes earlier), then substring matches.
    public static func shortcodeSuggestions(for text: String, limit: Int = 8) -> [EmojiShortcodes.Entry] {
        guard let query = shortcodeQuery(in: text)?.partial else { return [] }
        var prefix: [EmojiShortcodes.Entry] = [], contains: [EmojiShortcodes.Entry] = []
        for entry in EmojiShortcodes.entries {
            if entry.shortcode.hasPrefix(query) { prefix.append(entry) }
            else if entry.shortcode.contains(query) { contains.append(entry) }
        }
        prefix.sort { ($0.shortcode.count, $0.shortcode) < ($1.shortcode.count, $1.shortcode) }
        contains.sort { ($0.shortcode.count, $0.shortcode) < ($1.shortcode.count, $1.shortcode) }
        return Array((prefix + contains).prefix(limit))
    }

    /// Replaces the trailing query with the complete `:shortcode: `.
    public static func applyShortcode(_ shortcode: String, to text: String) -> String {
        guard let query = shortcodeQuery(in: text) else { return text }
        return String(text[..<query.range.lowerBound]) + ":" + shortcode + ": "
    }

    // MARK: Sparse directories

    public enum SparseError: Error, Equatable { case empty, invalid(String) }

    /// One repo-relative directory per line or comma; `./` and trailing `/` are dropped, duplicates removed.
    public static func parseSparseDirectories(_ text: String) throws(SparseError) -> [String] {
        var result: [String] = []
        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "," }) {
            var item = raw.trimmingCharacters(in: .whitespaces)
            while item.hasPrefix("./") { item.removeFirst(2) }
            while item.hasSuffix("/") { item.removeLast() }
            guard !item.isEmpty else { continue }
            let parts = item.split(separator: "/", omittingEmptySubsequences: false)
            guard !item.hasPrefix("/"), !item.hasPrefix("-"), !item.contains("\0"),
                  !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0 == ".git" }) else { throw .invalid(item) }
            if !result.contains(item) { result.append(item) }
        }
        guard !result.isEmpty else { throw .empty }
        return result
    }

    // MARK: Create request

    public enum Source: String, CaseIterable, Sendable { case smart = "Smart", github = "GitHub", gitlab = "GitLab", linear = "Linear", jira = "Jira", branch = "Branch", name = "Name"
        /// Smart and the issue-tracker sources need M9 integrations.
        public var isAvailable: Bool { self == .name || self == .branch }
    }
    public enum SetupChoice: String, CaseIterable, Sendable { case inherit, run, skip }

    public struct Ref: Equatable, Sendable {
        public var name: String
        public var kind: String   // local | remote | tag
        public init(name: String, kind: String) { self.name = name; self.kind = kind }
        public init?(_ json: HostJSON) {
            guard let object = json.object, let name = object["name"]?.string else { return nil }
            self.init(name: name, kind: object["kind"]?.string ?? "local")
        }
    }

    public struct CreateForm: Equatable, Sendable {
        public var repoID: String
        public var source: Source = .name
        public var name = ""
        /// Generated creature name used when `name` is empty.
        public var suggestedName: String?
        /// Branch source: the branch to check out. Name source: optional start-from ref.
        public var ref: Ref?
        public var branchName = ""
        public var parentID: String?
        public var comment = ""
        public var setup: SetupChoice = .inherit
        public var sparseDirectories: [String]?
        public var sparsePresetID: String?
        public init(repoID: String) { self.repoID = repoID }
    }

    public enum FormError: Error, Equatable { case sourceUnavailable, missingName, missingBranch, invalidBranchName }

    /// `worktree.create` params (§8.1) for a desktop request.
    public static func createParams(_ form: CreateForm) throws(FormError) -> [String: HostJSON] {
        guard form.source.isAvailable else { throw .sourceUnavailable }
        var params: [String: HostJSON] = ["repoId": .string(form.repoID), "createdBy": .string("desktop")]
        let typed = form.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var explicitBranch = form.branchName.trimmingCharacters(in: .whitespaces)
        switch form.source {
        case .branch:
            guard let ref = form.ref, ref.kind != "tag" else { throw .missingBranch }
            if ref.kind == "remote" {
                params["startFrom"] = .object(["kind": .string("remote-branch"), "ref": .string(ref.name)])
                let local = ref.name.split(separator: "/", maxSplits: 1).dropFirst().first.map(String.init) ?? ref.name
                if explicitBranch.isEmpty { explicitBranch = local }
            } else {
                params["startFrom"] = .object(["kind": .string("branch"), "ref": .string(ref.name)])
                // Same commit as the base and not checked out elsewhere: the host checks it out as-is.
                if explicitBranch.isEmpty { explicitBranch = ref.name }
            }
            let leaf = String(ref.name.split(separator: "/").last ?? Substring(ref.name))
            params["name"] = .string(typed.isEmpty ? leaf : typed)
        default:
            if typed.isEmpty {
                guard let generated = form.suggestedName, !generated.isEmpty else { throw .missingName }
                params["name"] = .string(generated); params["nameWasGenerated"] = .bool(true)
            } else { params["name"] = .string(typed) }
            if let ref = form.ref {
                params["startFrom"] = .object(["kind": .string(ref.kind == "tag" ? "commit" : "base"), "ref": .string(ref.name)])
            }
        }
        if !explicitBranch.isEmpty {
            guard !explicitBranch.hasPrefix("-"), !explicitBranch.contains(where: \.isWhitespace) else { throw .invalidBranchName }
            params["branchName"] = .string(explicitBranch)
        }
        if let parent = form.parentID { params["parentId"] = .string(parent) } else { params["noParent"] = .bool(true) }
        let comment = form.comment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !comment.isEmpty { params["comment"] = .string(comment) }
        params["setup"] = .string(form.setup.rawValue)
        if let dirs = form.sparseDirectories, !dirs.isEmpty {
            var sparse: [String: HostJSON] = ["directories": .array(dirs.map(HostJSON.string))]
            sparse["presetId"] = form.sparsePresetID.map(HostJSON.string)
            params["sparse"] = .object(sparse)
        }
        return params
    }

    /// Same request with an explicit setup decision (after `setupDecisionRequired`).
    public static func withSetup(_ params: [String: HostJSON], _ choice: SetupChoice) -> [String: HostJSON] {
        var copy = params; copy["setup"] = .string(choice.rawValue); return copy
    }

    // MARK: Job progress (§8.3)

    public static let phases = ["resolveBase", "resolveName", "add", "sparse", "materialize", "persist", "setup", "defaultTabs"]

    public static func phaseLabel(_ phase: String) -> String {
        switch phase {
        case "resolveBase": "Resolving base"
        case "resolveName": "Choosing name"
        case "add": "Checking out files"
        case "sparse": "Sparse checkout"
        case "materialize": "Copying shared files"
        case "persist": "Saving workspace"
        case "setup": "Starting setup"
        case "defaultTabs": "Opening tabs"
        case "fetch": "Fetching"
        case "archive": "Running archive script"
        case "closeSessions": "Closing terminals"
        case "remove": "Removing worktree"
        case "branch": "Cleaning up branch"
        default: phase.isEmpty ? "Starting" : phase
        }
    }

    /// 0...1 over the creation phases; Git's own counter subdivides the checkout phase.
    public static func progressFraction(phase: String, git: (done: Int, total: Int)?) -> Double {
        guard let index = phases.firstIndex(of: phase) else { return 0 }
        let step = 1.0 / Double(phases.count)
        var within = 0.0
        if phase == "add", let git, git.total > 0 { within = min(1, max(0, Double(git.done) / Double(git.total))) }
        return min(1, Double(index) * step + within * step)
    }

    // MARK: Host errors

    public enum CreateBlock: Equatable, Sendable {
        case setupDecision
        case untrusted(kind: String, hash: String)
    }

    /// Errors the composer answers with the Setup approval dialog instead of a message.
    public static func createBlock(code: String, detail: String?) -> CreateBlock? {
        switch code {
        case "setupDecisionRequired": return .setupDecision
        case "untrustedCommand":
            let parts = (detail ?? "").split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[1].count == 64, parts[1].allSatisfy(\.isHexDigit) else { return nil }
            return .untrusted(kind: parts[0], hash: parts[1])
        default: return nil
        }
    }

    public static func message(code: String, detail: String?) -> String {
        let text: String
        switch code {
        case "invalidName": text = "That name cannot be used for a workspace."
        case "invalidRef": text = "The selected branch or ref does not exist."
        case "branchExists": text = "A branch or folder with that name already exists."
        case "invalidPath": text = "The workspace folder would be outside the workspace root."
        case "notRepository": text = "This project is not a Git repository."
        case "notFound": text = "The project or workspace no longer exists."
        case "worktreeDirty": text = "The workspace has uncommitted or untracked changes."
        case "worktreeLocked": text = "The worktree is locked by Git."
        case "archiveHookFailed": text = "The archive script failed."
        case "hostRestarted": text = "The host stopped while this workspace was being created."
        case "authenticationRequired": text = "Git needs credentials to fetch."
        case "cancelled": text = "Cancelled."
        case "gitFailed": text = "Git failed."
        default: text = code
        }
        guard let detail, !detail.isEmpty, detail != code else { return text }
        return text + " " + detail
    }

    // MARK: Removal

    public struct RemoveOptions: Equatable, Sendable {
        public var force = false
        public var deleteBranch = true
        public var runHooks = true
        public var allowFailedArchiveHook = false
        public var closeSessions = true
        public init() {}
    }

    /// Clearing a failed create: no hooks, and a branch that may predate the job is kept (preserved for review).
    public static var discardFailedOptions: RemoveOptions {
        var options = RemoveOptions(); options.force = true; options.runHooks = false; options.deleteBranch = false
        return options
    }

    public static func removeParams(id: String, _ options: RemoveOptions) -> [String: HostJSON] {
        ["id": .string(id), "force": .bool(options.force), "deleteBranch": .bool(options.deleteBranch),
         "runHooks": .bool(options.runHooks), "allowFailedArchiveHook": .bool(options.allowFailedArchiveHook),
         "closeSessions": .bool(options.closeSessions)]
    }
}

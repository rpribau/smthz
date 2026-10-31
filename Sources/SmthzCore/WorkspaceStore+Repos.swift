import Foundation

/// Repository, project group, folder workspace and host setting rows (WP-M4-REGISTRY).
/// Callers pass canonical paths; every multi-statement change runs in one transaction.
public extension WorkspaceStore {
    static let repoColors = ["#737373", "#ef4444", "#f97316", "#eab308", "#22c55e", "#14b8a6", "#8b5cf6", "#ec4899"]

    // MARK: Repos

    func repoRows() throws -> [[String: WorkspaceSQLValue]] {
        try query("""
            SELECT r.*, (SELECT w.id FROM worktrees w WHERE w.repo_id=r.id AND w.is_main=1 LIMIT 1) AS main_worktree_id
            FROM repos r ORDER BY r.project_group_id IS NOT NULL, r.project_group_id, r.project_group_order, r.sort_order, r.added_at
            """)
    }
    func repoRow(_ id: String) throws -> [String: WorkspaceSQLValue] {
        guard let row = try query("SELECT r.*, (SELECT w.id FROM worktrees w WHERE w.repo_id=r.id AND w.is_main=1 LIMIT 1) AS main_worktree_id FROM repos r WHERE r.id=?",
                                  [.text(id.lowercased())]).first else { throw HostRPCError("notFound") }
        return row
    }
    func repoRow(path: String) throws -> [String: WorkspaceSQLValue]? {
        guard let id = try query("SELECT id FROM repos WHERE host_id='local' AND path=?", [.text(path)]).first?["id"]?.string else { return nil }
        return try repoRow(id)
    }

    /// Inserts the repository and its main-checkout workspace row. Returns the existing row for a known path.
    func insertRepo(path: String, kind: String, displayName: String, branch: String?,
                    projectGroupID: String?) throws -> (row: [String: WorkspaceSQLValue], alreadyKnown: Bool) {
        try transaction {
            if let existing = try repoRow(path: path) { return (existing, true) }
            if !(try query("SELECT id FROM worktrees WHERE path=?", [.text(path)]).isEmpty) {
                throw HostRPCError("alreadyExists", detail: "path is already a workspace of another project")
            }
            if let projectGroupID, try query("SELECT id FROM project_groups WHERE id=?", [.text(projectGroupID)]).isEmpty {
                throw HostRPCError("notFound", detail: "project group")
            }
            let id = Self.newID(), now = Date().timeIntervalSince1970
            let order = try query("SELECT COALESCE(MAX(sort_order),-1)+1 AS n FROM repos").first?["n"]?.integer ?? 0
            let groupOrder = try projectGroupID.map {
                try query("SELECT COALESCE(MAX(project_group_order),-1)+1 AS n FROM repos WHERE project_group_id=?", [.text($0)]).first?["n"]?.integer ?? 0
            } ?? 0
            try execute("INSERT INTO repos (id,kind,path,display_name,badge_color,project_group_id,project_group_order,sort_order,added_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?,?)", [
                .text(id), .text(kind), .text(path), .text(displayName), .text(Self.repoColors[0]),
                projectGroupID.map(WorkspaceSQLValue.text) ?? .null, .integer(groupOrder), .integer(order), .real(now), .real(now)])
            try execute("INSERT INTO worktrees (id,instance_id,repo_id,path,is_main,origin,branch,display_name,created_by,state,created_at,last_activity_at,updated_at) VALUES (?,?,?,?,1,'smthz',?,?,'import','ready',?,?,?)", [
                .text(Self.newID()), .text(Self.newID()), .text(id), .text(path), branch.map(WorkspaceSQLValue.text) ?? .null,
                .text(displayName), .real(now), .real(now), .real(now)])
            return (try repoRow(id), false)
        }
    }

    /// Paths that belong to the repository: its checkout and every recorded worktree.
    func repoRoots(_ id: String) throws -> [String] {
        let row = try repoRow(id)
        let worktrees = try query("SELECT path FROM worktrees WHERE repo_id=?", [.text(row["id"]!.string!)]).compactMap { $0["path"]?.string }
        return [row["path"]?.string].compactMap { $0 } + worktrees
    }

    /// Never touches files: rows only. Worktree checkouts on disk stay where they are.
    func deleteRepo(_ id: String) throws {
        try transaction {
            let id = try repoRow(id)["id"]!.string!
            let keys = try query("SELECT id FROM worktrees WHERE repo_id=?", [.text(id)]).compactMap { $0["id"]?.string }.map { "worktree:" + $0 }
            for key in keys { try execute("DELETE FROM lineage WHERE child_key=? OR parent_key=?", [.text(key), .text(key)]) }
            try execute("DELETE FROM cleanup_dismissals WHERE worktree_id IN (SELECT id FROM worktrees WHERE repo_id=?)", [.text(id)])
            try execute("DELETE FROM worktrees WHERE repo_id=?", [.text(id)])
            try execute("DELETE FROM repos WHERE id=?", [.text(id)])
        }
    }

    /// Updates named columns; `values` keys are column names validated by the caller.
    func updateRow(table: String, id: String, values: [String: WorkspaceSQLValue]) throws {
        guard !values.isEmpty else { return }
        let columns = values.keys.sorted()
        let assignments = (columns.map { "\($0)=?" } + ["updated_at=?"]).joined(separator: ",")
        try transaction {
            guard !(try query("SELECT id FROM \(table) WHERE id=?", [.text(id)]).isEmpty) else { throw HostRPCError("notFound") }
            try execute("UPDATE \(table) SET \(assignments) WHERE id=?",
                        columns.map { values[$0]! } + [.real(Date().timeIntervalSince1970), .text(id)])
        }
    }

    func reorderRepos(_ ids: [String], projectGroupID: String?) throws {
        try transaction { try applyRepoOrder(ids, projectGroupID: projectGroupID) }
    }
    /// SQLite has no nested BEGIN: callers already inside a transaction use this directly.
    fileprivate func applyRepoOrder(_ ids: [String], projectGroupID: String?) throws {
        do {
            for (index, id) in ids.enumerated() {
                guard !(try query("SELECT id FROM repos WHERE id=?", [.text(id)]).isEmpty) else { throw HostRPCError("notFound") }
                if let projectGroupID {
                    try execute("UPDATE repos SET project_group_id=?, project_group_order=?, updated_at=? WHERE id=?",
                                [.text(projectGroupID), .integer(Int64(index)), .real(Date().timeIntervalSince1970), .text(id)])
                } else {
                    try execute("UPDATE repos SET sort_order=?, updated_at=? WHERE id=?",
                                [.integer(Int64(index)), .real(Date().timeIntervalSince1970), .text(id)])
                }
            }
        }
    }

    func moveRepo(_ id: String, toGroup groupID: String?, index: Int) throws {
        try transaction {
            _ = try repoRow(id)
            if let groupID, try query("SELECT id FROM project_groups WHERE id=?", [.text(groupID)]).isEmpty { throw HostRPCError("notFound") }
            let siblings = try query(groupID == nil
                ? "SELECT id FROM repos WHERE project_group_id IS NULL AND id<>? ORDER BY sort_order, added_at"
                : "SELECT id FROM repos WHERE project_group_id=? AND id<>? ORDER BY project_group_order, added_at",
                (groupID.map { [WorkspaceSQLValue.text($0)] } ?? []) + [.text(id)]).compactMap { $0["id"]?.string }
            var order = siblings
            order.insert(id, at: max(0, min(index, order.count)))
            try execute("UPDATE repos SET project_group_id=?, updated_at=? WHERE id=?",
                        [groupID.map(WorkspaceSQLValue.text) ?? .null, .real(Date().timeIntervalSince1970), .text(id)])
            try applyRepoOrder(order, projectGroupID: groupID)
        }
    }

    // MARK: Project groups

    func groupRows() throws -> [[String: WorkspaceSQLValue]] {
        try query("SELECT * FROM project_groups ORDER BY tab_order, created_at")
    }
    func groupRow(_ id: String) throws -> [String: WorkspaceSQLValue] {
        guard let row = try query("SELECT * FROM project_groups WHERE id=?", [.text(id.lowercased())]).first else { throw HostRPCError("notFound") }
        return row
    }
    func insertGroup(name: String, color: String?, parentPath: String?, parentGroupID: String?,
                     createdFrom: String) throws -> [String: WorkspaceSQLValue] {
        try transaction {
            if let parentGroupID { _ = try groupRow(parentGroupID) }
            let id = Self.newID(), now = Date().timeIntervalSince1970
            let order = try query("SELECT COALESCE(MAX(tab_order),-1)+1 AS n FROM project_groups").first?["n"]?.integer ?? 0
            try execute("INSERT INTO project_groups (id,name,parent_path,parent_group_id,created_from,tab_order,color,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?)", [
                .text(id), .text(name), parentPath.map(WorkspaceSQLValue.text) ?? .null,
                parentGroupID.map(WorkspaceSQLValue.text) ?? .null, .text(createdFrom), .integer(order),
                color.map(WorkspaceSQLValue.text) ?? .null, .real(now), .real(now)])
            return try groupRow(id)
        }
    }
    /// Folder workspaces of the group cascade; repositories fall back to ungrouped unless removed by the caller first.
    func deleteGroup(_ id: String) throws {
        try transaction {
            _ = try groupRow(id)
            let folders = try query("SELECT id FROM folder_workspaces WHERE project_group_id=?", [.text(id)]).compactMap { $0["id"]?.string }
            for folder in folders { try execute("DELETE FROM lineage WHERE child_key=? OR parent_key=?", [.text("folder:" + folder), .text("folder:" + folder)]) }
            try execute("DELETE FROM project_groups WHERE id=?", [.text(id)])
        }
    }

    // MARK: Folder workspaces

    func folderRows(projectGroupID: String?) throws -> [[String: WorkspaceSQLValue]] {
        if let projectGroupID {
            return try query("SELECT * FROM folder_workspaces WHERE project_group_id=? ORDER BY sort_order, created_at", [.text(projectGroupID)])
        }
        return try query("SELECT * FROM folder_workspaces ORDER BY project_group_id, sort_order, created_at")
    }
    func folderRow(_ id: String) throws -> [String: WorkspaceSQLValue] {
        guard let row = try query("SELECT * FROM folder_workspaces WHERE id=?", [.text(id.lowercased())]).first else { throw HostRPCError("notFound") }
        return row
    }
    func insertFolder(groupID: String, name: String, folderPath: String, sourceRepoID: String?,
                      comment: String) throws -> [String: WorkspaceSQLValue] {
        try transaction {
            _ = try groupRow(groupID)
            if let sourceRepoID { _ = try repoRow(sourceRepoID) }
            let id = Self.newID(), now = Date().timeIntervalSince1970
            let order = try query("SELECT COALESCE(MAX(sort_order),-1)+1 AS n FROM folder_workspaces WHERE project_group_id=?", [.text(groupID)]).first?["n"]?.integer ?? 0
            try execute("INSERT INTO folder_workspaces (id,project_group_id,name,folder_path,source_repo_id,comment,sort_order,created_at,last_activity_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?,?)", [
                .text(id), .text(groupID), .text(name), .text(folderPath), sourceRepoID.map(WorkspaceSQLValue.text) ?? .null,
                .text(comment), .integer(order), .real(now), .real(now), .real(now)])
            return try folderRow(id)
        }
    }
    func deleteFolder(_ id: String) throws {
        try transaction {
            _ = try folderRow(id)
            try execute("DELETE FROM lineage WHERE child_key=? OR parent_key=?", [.text("folder:" + id), .text("folder:" + id)])
            try execute("DELETE FROM folder_workspaces WHERE id=?", [.text(id)])
        }
    }

    // MARK: Main-checkout workspace rows (full worktree lifecycle belongs to WP-M4-WORKTREE-HOST)

    func worktreeRows(repoID: String? = nil) throws -> [[String: WorkspaceSQLValue]] {
        if let repoID {
            return try query("SELECT * FROM worktrees WHERE repo_id=? ORDER BY is_main DESC, sort_order, created_at", [.text(repoID)])
        }
        return try query("SELECT * FROM worktrees ORDER BY repo_id, is_main DESC, sort_order, created_at")
    }

    // MARK: Host settings

    static let hostSettingDefaults: [String: HostJSON] = [
        "workspaceDir": .string(NSString(string: "~/smthz/workspaces").expandingTildeInPath),
        "nestWorkspaces": .bool(true),
        "branchPrefix": .string("git-username"),
        "branchPrefixCustom": .string(""),
        "refreshLocalBaseRefOnCreate": .bool(false),
        "defaultSetupRunPolicy": .string("run-by-default"),
    ]
    func hostSettings(keys: [String]? = nil) throws -> [String: HostJSON] {
        var values = Self.hostSettingDefaults
        for row in try query("SELECT key, value_json FROM host_settings") {
            guard let key = row["key"]?.string, values[key] != nil, let json = row["value_json"]?.string,
                  let value = try? JSONDecoder().decode(HostJSON.self, from: Data(json.utf8)) else { continue }
            values[key] = value
        }
        guard let keys else { return values }
        return values.filter { keys.contains($0.key) }
    }
    func setHostSettings(_ values: [String: HostJSON]) throws {
        try transaction {
            for (key, value) in values {
                let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
                try execute("INSERT INTO host_settings (key,value_json,updated_at) VALUES (?,?,?) ON CONFLICT(key) DO UPDATE SET value_json=excluded.value_json, updated_at=excluded.updated_at",
                            [.text(key), .text(json), .real(Date().timeIntervalSince1970)])
            }
        }
    }
}

/// Row → wire JSON. Column names become lower camel case; `is_*` flags become booleans.
public enum WorkspaceRowJSON {
    public static func object(_ row: [String: WorkspaceSQLValue], booleans: Set<String> = [],
                              jsonColumns: Set<String> = []) -> HostJSON {
        var result: [String: HostJSON] = [:]
        for (column, value) in row {
            let key = camel(column)
            switch value {
            case .null: continue
            case .text(let text):
                if jsonColumns.contains(column), let decoded = try? JSONDecoder().decode(HostJSON.self, from: Data(text.utf8)) {
                    result[key] = decoded
                } else { result[key] = .string(text) }
            case .integer(let number):
                result[key] = column.hasPrefix("is_") || booleans.contains(column) ? .bool(number != 0) : .number(Double(number))
            case .real(let number): result[key] = .number(number)
            case .blob: continue
            }
        }
        return .object(result)
    }
    public static func repo(_ row: [String: WorkspaceSQLValue]) -> HostJSON {
        guard case .object(var value) = object(row, jsonColumns: ["shared_paths_json"]) else { return .null }
        value["sharedPaths"] = value.removeValue(forKey: "sharedPathsJson") ?? .array([])
        if let path = row["path"]?.string { value["pathMissing"] = .bool(!FileManager.default.fileExists(atPath: path)) }
        return .object(value)
    }
    public static func group(_ row: [String: WorkspaceSQLValue]) -> HostJSON { object(row) }
    public static func folder(_ row: [String: WorkspaceSQLValue]) -> HostJSON {
        guard case .object(var value) = object(row, jsonColumns: ["linked_items_json"]) else { return .null }
        value["linkedItems"] = value.removeValue(forKey: "linkedItemsJson") ?? .array([])
        return .object(value)
    }
    public static func worktree(_ row: [String: WorkspaceSQLValue]) -> HostJSON {
        guard case .object(var value) = object(row, booleans: ["checkout_existing_branch", "preserve_branch_on_delete",
                                                              "display_name_pinned", "name_was_generated"],
                                               jsonColumns: ["linked_items_json", "sparse_dirs_json"]) else { return .null }
        value["linkedItems"] = value.removeValue(forKey: "linkedItemsJson") ?? .array([])
        value["sparseDirs"] = value.removeValue(forKey: "sparseDirsJson")
        return .object(value)
    }
    static func camel(_ column: String) -> String {
        let parts = column.split(separator: "_")
        guard let first = parts.first else { return column }
        return String(first) + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }
}

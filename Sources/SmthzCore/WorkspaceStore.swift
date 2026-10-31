import Foundation
import SQLite3

public enum WorkspaceStoreError: Error, Sendable { case sqlite(String), unsupportedVersion(Int) }
public enum WorkspaceSQLValue: Sendable, Equatable {
    case null, text(String), integer(Int64), real(Double), blob(Data)
    public var string: String? { if case .text(let v) = self { return v }; return nil }
    public var integer: Int64? { if case .integer(let v) = self { return v }; return nil }
}

/// Domain state is separate from the request journal. A recursive lock allows
/// helpers to compose statements into a single transaction without sharing SQLite.
public final class WorkspaceStore: @unchecked Sendable {
    public let path: String
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    public init(path: String) throws {
        self.path = path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let error = String(cString: sqlite3_errmsg(db)); sqlite3_close(db); db = nil
            throw WorkspaceStoreError.sqlite(error)
        }
        do {
            sqlite3_busy_timeout(db, 5_000)
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA foreign_keys=ON")
            let version = Int(try query("PRAGMA user_version").first?["user_version"]?.integer ?? 0)
            guard version <= 1 else { throw WorkspaceStoreError.unsupportedVersion(version) }
            if version == 0 {
                try transaction {
                    try execute(Self.schemaV1)
                    try execute("PRAGMA user_version=1")
                }
            }
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { sqlite3_close(db) }
    public static func canonicalPath(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.utf8.contains(0), let resolved = realpath(path, nil) else {
            throw HostRPCError("invalidPath")
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }
    public static func newID() -> String { UUID().uuidString.lowercased() }
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do { let result = try body(); try execute("COMMIT"); return result }
        catch { try? execute("ROLLBACK"); throw error }
    }
    /// Executes a SQL script when no bindings are supplied; otherwise one bound statement.
    public func execute(_ sql: String, _ bindings: [WorkspaceSQLValue] = []) throws {
        lock.lock(); defer { lock.unlock() }
        if bindings.isEmpty {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
        } else {
            let statement = try prepare(sql, bindings); defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
        }
    }
    public func query(_ sql: String, _ bindings: [WorkspaceSQLValue] = []) throws -> [[String: WorkspaceSQLValue]] {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare(sql, bindings); defer { sqlite3_finalize(statement) }
        var rows: [[String: WorkspaceSQLValue]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return rows }
            guard status == SQLITE_ROW else { throw failure() }
            var row: [String: WorkspaceSQLValue] = [:]
            for i in 0..<sqlite3_column_count(statement) {
                let value: WorkspaceSQLValue
                switch sqlite3_column_type(statement, i) {
                case SQLITE_INTEGER: value = .integer(sqlite3_column_int64(statement, i))
                case SQLITE_FLOAT: value = .real(sqlite3_column_double(statement, i))
                case SQLITE_TEXT: value = .text(String(cString: sqlite3_column_text(statement, i)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, i))
                    value = .blob(count == 0 ? Data() : Data(bytes: sqlite3_column_blob(statement, i), count: count))
                default: value = .null
                }
                row[String(cString: sqlite3_column_name(statement, i))] = value
            }
            rows.append(row)
        }
    }
    private func failure() -> WorkspaceStoreError { .sqlite(String(cString: sqlite3_errmsg(db))) }
    private func prepare(_ sql: String, _ bindings: [WorkspaceSQLValue]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .null: result = sqlite3_bind_null(statement, index)
            case .text(let v): result = sqlite3_bind_text(statement, index, v, -1, transient)
            case .integer(let v): result = sqlite3_bind_int64(statement, index, v)
            case .real(let v): result = sqlite3_bind_double(statement, index, v)
            case .blob(let v): result = v.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(v.count), transient) }
            }
            if result != SQLITE_OK { sqlite3_finalize(statement); throw failure() }
        }
        return statement
    }
    /// All lineage mutations go through this helper so polymorphic workspace
    /// keys retain their cycle, repository, and stale-instance guards.
    public func setLineage(child: String, parent: String, origin: String,
                           captureSource: String, confidence: String) throws {
        try transaction {
            func identity(_ key: String) throws -> (String?, String?) {
                let parts = key.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { throw HostRPCError("badRequest") }
                let rows: [[String: WorkspaceSQLValue]]
                if parts[0] == "worktree" {
                    rows = try query("SELECT repo_id, instance_id FROM worktrees WHERE id=?", [.text(String(parts[1]))])
                } else if parts[0] == "folder" {
                    rows = try query("SELECT source_repo_id AS repo_id FROM folder_workspaces WHERE id=?", [.text(String(parts[1]))])
                } else { throw HostRPCError("badRequest") }
                guard let row = rows.first else { throw HostRPCError("notFound") }
                return (row["repo_id"]?.string, row["instance_id"]?.string)
            }
            let c = try identity(child), p = try identity(parent)
            guard c.0 == p.0 else { throw HostRPCError("badRequest", detail: "lineage crosses repositories") }
            var cursor: String? = parent
            var seen: Set<String> = [child]
            while let key = cursor {
                guard seen.insert(key).inserted else { throw HostRPCError("badRequest", detail: "lineage cycle") }
                cursor = try query("SELECT parent_key FROM lineage WHERE child_key=?", [.text(key)]).first?["parent_key"]?.string
            }
            try execute("INSERT INTO lineage (child_key,child_instance_id,parent_key,parent_instance_id,origin,capture_source,capture_confidence,created_at) VALUES (?,?,?,?,?,?,?,?) ON CONFLICT(child_key) DO UPDATE SET child_instance_id=excluded.child_instance_id,parent_key=excluded.parent_key,parent_instance_id=excluded.parent_instance_id,origin=excluded.origin,capture_source=excluded.capture_source,capture_confidence=excluded.capture_confidence,created_at=excluded.created_at", [
                .text(child), c.1.map(WorkspaceSQLValue.text) ?? .null, .text(parent), p.1.map(WorkspaceSQLValue.text) ?? .null,
                .text(origin), .text(captureSource), .text(confidence), .real(Date().timeIntervalSince1970)])
        }
    }

    /// Interrupted operations cannot be resumed safely after a host restart.
    public func reconcileAfterRestart() throws {
        try execute("UPDATE worktrees SET state=CASE state WHEN 'removing' THEN 'remove_failed' ELSE 'failed' END, last_error='hostRestarted', updated_at=strftime('%s','now') WHERE state IN ('creating','removing')")
    }
    private static let schemaV1 = """
CREATE TABLE host_settings (key TEXT PRIMARY KEY, value_json TEXT NOT NULL, updated_at REAL NOT NULL);
-- keys: workspaceDir (string), nestWorkspaces (bool, default true), branchPrefix ("git-username"|"custom"|"none"),
--       branchPrefixCustom (string), refreshLocalBaseRefOnCreate (bool, default false), defaultSetupRunPolicy

CREATE TABLE project_groups (
  id TEXT PRIMARY KEY, name TEXT NOT NULL, parent_path TEXT,
  parent_group_id TEXT REFERENCES project_groups(id) ON DELETE SET NULL,
  created_from TEXT NOT NULL CHECK (created_from IN ('manual','folder-scan')),
  tab_order INTEGER NOT NULL DEFAULT 0, is_collapsed INTEGER NOT NULL DEFAULT 0, color TEXT,
  created_at REAL NOT NULL, updated_at REAL NOT NULL);

CREATE TABLE repos (
  id TEXT PRIMARY KEY, host_id TEXT NOT NULL DEFAULT 'local',          -- M7 reserves ssh:/runtime: ids
  kind TEXT NOT NULL CHECK (kind IN ('git','folder')),
  path TEXT NOT NULL, display_name TEXT NOT NULL, badge_color TEXT NOT NULL,
  worktree_base_ref TEXT, worktree_base_path TEXT, git_username TEXT,
  project_group_id TEXT REFERENCES project_groups(id) ON DELETE SET NULL, project_group_order INTEGER NOT NULL DEFAULT 0,
  sort_order INTEGER NOT NULL DEFAULT 0,
  external_worktree_visibility TEXT CHECK (external_worktree_visibility IN ('show','hide')),   -- NULL = inherit
  setup_run_policy TEXT NOT NULL DEFAULT 'run-by-default' CHECK (setup_run_policy IN ('ask','run-by-default','skip-by-default')),
  setup_agent_startup_policy TEXT CHECK (setup_agent_startup_policy IN ('start-immediately','wait-for-setup')),
  command_source_policy TEXT CHECK (command_source_policy IN ('shared-only','local-only','run-both')),   -- NULL = Orca default rule
  local_setup_script TEXT NOT NULL DEFAULT '', local_archive_script TEXT NOT NULL DEFAULT '',
  shared_paths_json TEXT NOT NULL DEFAULT '[]',                         -- Orca symlinkPaths
  added_at REAL NOT NULL, updated_at REAL NOT NULL,
  UNIQUE (host_id, path));

CREATE TABLE worktrees (
  id TEXT PRIMARY KEY, instance_id TEXT NOT NULL,                       -- new instance id on every create (stale lineage guard)
  repo_id TEXT NOT NULL REFERENCES repos(id) ON DELETE RESTRICT,
  path TEXT NOT NULL UNIQUE, is_main INTEGER NOT NULL DEFAULT 0,
  origin TEXT NOT NULL CHECK (origin IN ('smthz','external')),          -- external = found in `git worktree list`
  branch TEXT, base_ref TEXT, start_from_kind TEXT CHECK (start_from_kind IN ('base','branch','commit','remote-branch')),
  checkout_existing_branch INTEGER NOT NULL DEFAULT 0, preserve_branch_on_delete INTEGER NOT NULL DEFAULT 0,
  display_name TEXT NOT NULL, display_name_pinned INTEGER NOT NULL DEFAULT 0, name_was_generated INTEGER NOT NULL DEFAULT 0,
  comment TEXT NOT NULL DEFAULT '', workspace_status TEXT,
  is_archived INTEGER NOT NULL DEFAULT 0, is_unread INTEGER NOT NULL DEFAULT 0, is_pinned INTEGER NOT NULL DEFAULT 0,
  is_visible INTEGER NOT NULL DEFAULT 1,                                -- external worktrees shown/hidden
  sort_order INTEGER NOT NULL DEFAULT 0, manual_order INTEGER,
  sparse_dirs_json TEXT, sparse_base_ref TEXT, sparse_preset_id TEXT,
  created_by TEXT NOT NULL CHECK (created_by IN ('desktop','cli','import')),
  state TEXT NOT NULL CHECK (state IN ('creating','ready','failed','removing','remove_failed')),
  job_id TEXT, last_error TEXT, last_error_detail TEXT,
  linked_items_json TEXT NOT NULL DEFAULT '[]',                         -- M9 fills it
  created_at REAL NOT NULL, last_activity_at REAL NOT NULL, updated_at REAL NOT NULL);
CREATE INDEX worktrees_repo ON worktrees(repo_id);

CREATE TABLE folder_workspaces (
  id TEXT PRIMARY KEY, project_group_id TEXT NOT NULL REFERENCES project_groups(id) ON DELETE CASCADE,
  name TEXT NOT NULL, folder_path TEXT NOT NULL, source_repo_id TEXT REFERENCES repos(id) ON DELETE SET NULL,
  comment TEXT NOT NULL DEFAULT '', workspace_status TEXT,
  is_archived INTEGER NOT NULL DEFAULT 0, is_unread INTEGER NOT NULL DEFAULT 0, is_pinned INTEGER NOT NULL DEFAULT 0,
  sort_order INTEGER NOT NULL DEFAULT 0, manual_order INTEGER, linked_items_json TEXT NOT NULL DEFAULT '[]',
  created_at REAL NOT NULL, last_activity_at REAL NOT NULL, updated_at REAL NOT NULL);

CREATE TABLE lineage (
  child_key TEXT PRIMARY KEY,                    -- 'worktree:<id>' | 'folder:<id>'
  child_instance_id TEXT, parent_key TEXT NOT NULL, parent_instance_id TEXT,
  origin TEXT NOT NULL CHECK (origin IN ('manual','cli','orchestration')),
  capture_source TEXT NOT NULL, capture_confidence TEXT NOT NULL CHECK (capture_confidence IN ('explicit','inferred')),
  created_at REAL NOT NULL);

CREATE TABLE retired_names (repo_id TEXT NOT NULL REFERENCES repos(id) ON DELETE CASCADE, name TEXT NOT NULL,
  retired_at REAL NOT NULL, PRIMARY KEY (repo_id, name));          -- generated creature names never reused per repo
CREATE TABLE sparse_presets (id TEXT PRIMARY KEY, repo_id TEXT NOT NULL REFERENCES repos(id) ON DELETE CASCADE,
  name TEXT NOT NULL, directories_json TEXT NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL);
CREATE TABLE preserved_branches (repo_id TEXT NOT NULL REFERENCES repos(id) ON DELETE CASCADE, branch TEXT NOT NULL,
  head TEXT NOT NULL, former_path TEXT NOT NULL, preserved_at REAL NOT NULL, PRIMARY KEY (repo_id, branch));
CREATE TABLE hook_trust (repo_id TEXT NOT NULL REFERENCES repos(id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK (kind IN ('setup','archive','defaultTabs','issueCommand')),
  content_hash TEXT NOT NULL, approved_at REAL NOT NULL, PRIMARY KEY (repo_id, kind));
CREATE TABLE cleanup_dismissals (worktree_id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL,
  classifier_version INTEGER NOT NULL, dismissed_at REAL NOT NULL);
"""
}

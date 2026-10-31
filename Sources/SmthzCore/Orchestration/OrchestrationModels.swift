import Foundation

/// Orchestration vocabulary and storage (WP-M8-ORCH-1), mirroring Orca 1.4.238
/// `src/main/runtime/orchestration/db/schema` and `src/cli/specs/orchestration.ts`.
public enum Orchestration {
    public static let messageTypes: Set<String> = ["status", "dispatch", "worker_done", "merge_ready", "escalation",
                                                   "handoff", "decision_gate", "question", "heartbeat"]
    public static let priorities: Set<String> = ["normal", "high", "urgent"]
    public static let taskStatuses: Set<String> = ["pending", "ready", "dispatched", "completed", "failed", "blocked"]
    /// Orca `DISPATCH_CIRCUIT_BREAK_FAILURES`: the third failed attempt fails the task instead of reopening it.
    public static let circuitBreakFailures = 3

    /// Orca `generateId`: `<prefix>_` plus 12 lowercase hex digits.
    static func newID(_ prefix: String) -> String {
        prefix + "_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(12)
    }

    /// Schema v2: added to the v1 workspace store by `WorkspaceStore.init`.
    static let schemaV2 = """
CREATE TABLE orch_runs (id TEXT PRIMARY KEY, objective TEXT NOT NULL, coordinator_handle TEXT,
  created_at REAL NOT NULL, updated_at REAL NOT NULL);
CREATE TABLE orch_tasks (
  id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES orch_runs(id) ON DELETE CASCADE, parent_id TEXT,
  created_by TEXT, task_title TEXT, display_name TEXT, spec TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('pending','ready','dispatched','completed','failed','blocked')),
  deps TEXT NOT NULL DEFAULT '[]', result TEXT, created_at REAL NOT NULL, completed_at REAL);
CREATE INDEX orch_tasks_run ON orch_tasks(run_id, status);
CREATE TABLE orch_dispatches (
  id TEXT PRIMARY KEY, run_id TEXT NOT NULL, task_id TEXT NOT NULL REFERENCES orch_tasks(id) ON DELETE CASCADE,
  assignee_handle TEXT NOT NULL, creator_handle TEXT,
  status TEXT NOT NULL CHECK (status IN ('dispatched','completed','failed','circuit_broken')),
  failure_count INTEGER NOT NULL DEFAULT 0, last_failure TEXT,
  created_at REAL NOT NULL, completed_at REAL, last_heartbeat_at REAL);
CREATE INDEX orch_dispatches_task ON orch_dispatches(task_id);
CREATE INDEX orch_dispatches_assignee ON orch_dispatches(assignee_handle, status);
CREATE TABLE orch_messages (
  sequence INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE, run_id TEXT,
  from_handle TEXT NOT NULL, to_handle TEXT NOT NULL, subject TEXT NOT NULL, body TEXT NOT NULL DEFAULT '',
  type TEXT NOT NULL CHECK (type IN ('status','dispatch','worker_done','merge_ready','escalation','handoff','decision_gate','question','heartbeat')),
  priority TEXT NOT NULL DEFAULT 'normal' CHECK (priority IN ('normal','high','urgent')),
  thread_id TEXT, payload TEXT, read INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL);
CREATE INDEX orch_inbox ON orch_messages(to_handle, read);
CREATE INDEX orch_thread ON orch_messages(thread_id);
CREATE TABLE orch_deliveries (
  id TEXT PRIMARY KEY, consumer TEXT NOT NULL, message_ids TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('outstanding','acknowledged')), created_at REAL NOT NULL, acknowledged_at REAL);
CREATE INDEX orch_deliveries_consumer ON orch_deliveries(consumer, status);
CREATE TABLE orch_gates (
  id TEXT PRIMARY KEY, run_id TEXT NOT NULL, task_id TEXT NOT NULL REFERENCES orch_tasks(id) ON DELETE CASCADE,
  question TEXT NOT NULL, options TEXT NOT NULL DEFAULT '[]',
  status TEXT NOT NULL CHECK (status IN ('pending','resolved')), resolution TEXT,
  created_at REAL NOT NULL, resolved_at REAL);
"""

    static func json(_ row: [String: WorkspaceSQLValue]) -> HostJSON {
        WorkspaceRowJSON.object(row, booleans: ["read"], jsonColumns: ["deps", "options", "message_ids", "payload"])
    }
}

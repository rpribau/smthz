# M4-PLAN — local developer loop (projects, worktrees, Source Control writes, files, search)

Date: 2026-10-31. Author: worker `task_ef166d12b55d` (Opus 5.5, research/design only: no product code, no build of the repo, no app launch). Scope: PARITY-AUDIT work packages **6 (M4-REGISTRY), 7 (M4-WORKTREE), 9 (M4-SCWRITE), 11 (M4-FILES)** turned into worker-ready packages. `R/` = `reference/orca-1.4.238` (read-only). Sizes are in worker-days (wd) for one Codex worker, tests and self-verification included.

smthz line numbers refer to the working tree read on 2026-10-31 (commit `ab92c83` plus edits by workers running in parallel: `HostService.swift`, `HostClient.swift`, `ShellController.swift`, `ShellView.swift`, a new `SessionStreamTests.swift` and `ShellKeybindings.swift` were modified or added during this task). They may shift, so re-check them before quoting.

Evidence tags: **[measured]** = run by this worker on 2026-10-31 (scratch dir `/tmp/smthz-exp-opus`, deleted afterwards), **[cited]** = file path given, **[unverified]** = inference, to be confirmed by the implementing worker.

---

## 1. Summary

- The host (`smthzd`) becomes the owner of projects, worktrees, file and Git operations. The app and the CLI are thin clients. This matches Orca, where the runtime owns repos and worktrees (`R/src/main/runtime/runtime-local-worktree-create.ts`, RPC `worktree.create/rm/set/ps` in `R/src/main/runtime/rpc/methods`), and it keeps M7 (SSH/remote hosts) possible without rewriting M4.
- Today's host cannot carry this as is (§2.2): one global lock serializes every request, the timeout ceiling is 30 s, every response is journaled forever, and `GitService` deliberately disables user config and hooks. A foundation package (**WP-M4-0 HOSTCORE**) fixes this once: a method router, long-running **jobs** with progress, a separate domain database `workspace.sqlite`, and two Git run modes.
- Eight packages, at most two in parallel, about **38–45 wd** in total (§12). Critical path: HOSTCORE → REGISTRY → WORKTREE-HOST → WORKTREE-APP → CLEANUP.
- **Nine decisions need the user** (§13). The blocking ones: config file name/compatibility (M4-D1), YAML parser dependency (M4-D2), bundling `rg` (M4-D3), default worktree folder (M4-D4).
- Correction to PARITY-AUDIT: Orca's `orca search` CLI is **agent-session full-text search** (`R/src/cli/specs/search.ts`), not ripgrep. Ripgrep folder search exists only in the app (`R/src/main/ripgrep`, IPC `fs:search`). So `smthz search` belongs to M5-HISTORY, not M4.

## 2. What exists in smthz today (ground truth)

### 2.1 Reusable pieces

| Piece | Where | Relevance |
|---|---|---|
| Git wrapper: repo detection, status v2, branches, worktree list/add/remove, diff | `Sources/SmthzCore/GitService.swift` | Base for all Git work. Runs `/usr/bin/git` without a shell, with timeout/cancel, writes stdout/stderr to temp files (`:214`) |
| Host RPC with request-id idempotency (id + method + params hash), capability token, cancel, limits | `HostService.swift`, `EventJournal.swift`, `HostClient.swift` | New methods plug in here |
| Shell model with string `WorkspaceKey` (`home`, `floating`, `folder:<path>`) | `ShellModel.swift:15-21` | `worktree:<id>` and `folder:<id>` keys need **no model change** |
| `WorkspaceLayout.rootPath`, `ShellCommand.openWorkspace/closeWorkspace` | `ShellModel.swift` | Per-workspace tabs already modelled |
| App: Explorer (read-only), Source Control (read-only), Go to File (FileManager scan, 10,000 entries / 2 s cap), Add Project and New Workspace dialogs (VISUAL-ONLY), Delete Workspace dialog (VISUAL-ONLY) | `RightSidebar/ExplorerPanel.swift`, `RightSidebar/SourceControlPanel.swift`, `Palette/GoToFilePalette.swift:116`, `Dialogs/*` | UI to make real |
| CLI with `--socket` after the subcommand | `Sources/smthz/main.swift:155` | New subcommands follow the same convention |

### 2.2 Constraints that shape the design

| Constraint | Evidence | Consequence |
|---|---|---|
| Every request after authentication takes one host-wide `lock` and the session `journalLock` | `HostService.swift:224` onwards | A 5 s `git worktree add` would block every terminal write. M4 handlers must run **outside** this lock |
| Timeout default 5 s (client), ceiling 30 s (`maximumTimeoutMilliseconds`) | `HostService.swift:74`, `HostClient.call(... timeoutMilliseconds: Int = 5_000)` | Long work (checkout, clone, push, fetch, removal of big trees) must be a **job** that returns at once |
| Every non-foreground response is stored in `events` forever | `HostService.swift:280` (`appendResponse`) | Reads (file listings, status, search) must **not** be journaled, or the journal grows without bound |
| Frames ≤ 1 MiB, request payload ≤ 700,000 bytes | `RPCFrameCodec.swift:9`, `HostService.swift:73` | Listings, search results and file contents must be paged/capped |
| `GitService` sets `GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_NOSYSTEM=1`, `core.hooksPath=/dev/null` | `GitService.swift:224-227` | Good for reads. **Breaks writes**: with that isolation `git commit` fails with "Author identity unknown" although the user has a global `user.email` **[measured]**; credential helpers (system config) and pre-commit hooks (Orca runs them, `R/docs/site/content/docs/review/commit-push.mdx`) are also off. A second run mode is required |
| `GitService` reads stderr only after exit | `GitService.swift:214-247` | Checkout progress needs a streaming stderr reader. Git 2.54 writes `Updating files:  33% (13148/38768)` lines separated by `\r` to a non-TTY stderr during a long checkout **[measured: 71 progress lines for 38,768 files]** |
| App calls `GitService` and `FileManager` in-process | `SourceControlPanel.swift:13`, `ExplorerPanel.swift:53` | Move behind host RPC (needed for M7 remote hosts) |
| App has exactly one workspace (`.home`) | `ShellController.swift:78-88` | Workspace switching is part of M4 app work and conflicts with A4-WINDOWS (same file) |
| No system `rg`: `/opt/homebrew/bin/rg` and `/usr/local/bin/rg` absent; the `rg` in this shell is a Claude Code function **[measured]** | — | Folder search cannot assume ripgrep: bundle it (M4-D3) or fall back to `git grep` |

### 2.3 Measurements (Apple Silicon, APFS, git 2.54.0 Apple Git-157)

| Experiment | Result |
|---|---|
| `git worktree add --no-track -b` on the smthz repo (314 files) | 0.11 s |
| Same on a 38,768-file repo (copy of `R/`, committed) | **4.60 s** (exceeds today's 5 s default once a fetch is added; confirms jobs) |
| `--no-checkout` add + `sparse-checkout init --cone` + `set Sources/SmthzCore` + checkout (smthz repo) | 0.01 + 0.03 s; 28 files on disk instead of 314 |
| `cp -cR` (APFS clonefile) vs `cp -R` of the 39,082-file `R/` tree | 4.74 s vs 8.49 s |
| `git ls-files -z` / `ls-files --others --exclude-standard` / `status --porcelain=v2` on 38,768 files | 0.01 / 0.05 / 0.07 s |
| `git grep -n -I --untracked -F` on the same tree | 1.09 s (43 hits) |
| `CFStringTransform(…, "Any-Name")` on emoji | 🚀 → `\N{ROCKET}`, 😀 → `\N{GRINNING FACE}`, 🇲🇽 → two regional-indicator names. Usable as a dataset-free fallback, but names differ from Slack shortcodes (`grinning`) and flags are not shortcodes |
| `/tmp` paths resolve to `/private/tmp` in `git worktree list` | Paths must be canonicalized (realpath) before comparison or storage |

## 3. Orca model (what we mirror)

| Orca concept | Source | smthz M4 mapping |
|---|---|---|
| `Repo` (kind `git`/`folder`, path, displayName, badgeColor, `worktreeBaseRef`, `worktreeBasePath`, `gitUsername`, `hookSettings`, `symlinkPaths` (= Worktree Shared Paths), `projectGroupId/Order`, `externalWorktreeVisibility`, …) | `R/src/shared/repo-types.ts:53` | `repos` table (§4). Fork/GitHub/Jira/gh-account/issue-source fields deferred to M9 |
| `ProjectGroup` (name, parentPath, parentGroupId, createdFrom manual/folder-scan, tabOrder, isCollapsed, color) | `R/src/shared/project-group-types.ts` | `project_groups` |
| Nested repo scan + import as group or separately | `R/src/main/project-groups/nested-repo-*.ts`, IPC `projectGroups:scanNested/importNested` | `repo.scanNested` job + `projectGroup.importNested` |
| `FolderWorkspace` (bound to a project group, folderPath, comment, archived/unread/pinned, linked task) | `R/src/shared/folder-workspace-types.ts` | `folder_workspaces` |
| `WorktreeMeta` (displayName, pinned name, comment, archived/unread/pinned, sortOrder, workspaceStatus, sparse dirs/base/preset, `baseRef`, `preserveBranchOnDelete`, creation source, links, …) | `R/src/shared/worktree/meta-types.ts` | `worktrees` |
| Lineage (child/parent ids **and instance ids**, origin manual/cli/orchestration, capture source/confidence) | `R/src/shared/worktree/lineage-types.ts` | `lineage` |
| Project host setups (`project setup-*` CLI) | `R/src/cli/specs/project.ts` | Deferred to M7 (one host). `repos.host_id` reserved |
| Settings: `workspaceDir` default `~/orca/workspaces`, `nestWorkspaces: true`, `branchPrefix: git-username` | `R/src/shared/constants.ts:101-105`, `R/src/shared/default-global-settings.ts:35-42` | `host_settings` with smthz defaults (M4-D4) |

## 4. Data model (host SQLite `<state-dir>/workspace.sqlite`)

Separate file from `journal.sqlite`: the journal is a request log, this is domain state. WAL, `foreign_keys=ON`, `PRAGMA user_version` for migrations, all access serialized by one `WorkspaceStore` lock (the existing `EventJournal` pattern: one connection, `@unchecked Sendable`, caller-held lock). All paths stored **canonical** (`realpath`, no trailing slash). Ids are lowercase UUID strings (`RequestID` style). Times are `REAL` Unix seconds.

```sql
-- v1
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
```

Invariants (tests): a repo's main checkout is a `worktrees` row with `is_main=1` (Orca `getRepoMainWorktreeId`, `R/src/shared/worktree/id.ts:21`) so every workspace card is one row; deleting a repo never deletes files; `lineage` rejects cycles and parents in another repo (Orca excludes these, `R/docs/site/content/docs/model/worktrees.mdx` "Sleep/Delete with Descendants"); a row in `creating`/`removing` at host start is reconciled (§8.6).

App-side (unchanged storage): `shell-state.json` keeps layouts keyed by `WorkspaceKey`: `worktree:<worktreeId>` and `folder:<folderWorkspaceId>` (the existing `.folder(path)` constructor is path-based; M4 uses ids so a renamed folder keeps its tabs). `home` stays as the "no project" workspace.

## 5. Host RPC

### 5.1 Conventions (implemented by WP-M4-0)

- Methods are dotted, lower camel (`repo.add`, as today's `session.create`). Response payload is today's shape: top-level `ok`, `error` (code), plus a new optional `detail` (human text, e.g. Git stderr, ≤ 16 KiB) and the result fields. `HostClient` gains a call variant that surfaces `detail` (today `hostError(code:)` drops everything but the code).
- Each method declares a **class**:
  - `read`: not journaled, any number concurrent, never takes `HostService.lock`.
  - `mutation`: journaled through the existing request-id/params-hash mechanism (retries replay the stored answer, mismatches return `idempotencyConflict`), runs under a **per-repo gate** (one Git-writing operation per repository at a time; Orca serializes the same way: `worktreeCreateGit.run`, per-repo branch cleanup queue in `R/src/main/git/worktree-removal.ts`).
  - `job`: a journaled mutation that validates, registers a job and returns `{jobId, …ids}` within the 5 s default; the work continues on a host thread. Replaying the same request id returns the same `jobId`.
- `job.get {jobId, afterSeq}` → `{state: queued|running|succeeded|failed|cancelled, phase, progress: {done,total}?, events: [{seq, at, kind: phase|progress|log|warning, text}], result?, error?, detail?}`; `job.cancel {jobId}` (kills the running Git child via the existing `GitProcessControl`); `job.list {}`. Job logs bounded (1,000 events / 256 KiB, oldest dropped); finished jobs kept 15 min in memory; durable outcome lives in the domain row (`worktrees.state/last_error`). H5-STREAM may later push job events; polling at 250 ms is the M4 contract.
- Common errors: `badRequest`, `notFound`, `alreadyExists`, `invalidPath`, `pathOutsideRoot`, `notRepository`, `invalidName`, `invalidRef`, `branchExists`, `baseRefUnresolved`, `repoBusy`, `worktreeDirty`, `worktreeLocked`, `hasLiveSessions`, `setupDecisionRequired`, `untrustedCommand`, `archiveHookFailed`, `configInvalid`, `gitFailed` (+`detail`), `authenticationRequired` (Git asked for credentials with prompts disabled), `limitExceeded`, `jobNotFound`, `cancelled`, `hostStopping`.
- Every path parameter is either an id, or an absolute path that must canonicalize **inside** a registered root (repo path, worktree path, folder workspace path). Relative file paths are resolved against the root and rejected after `realpath` if they escape (`pathOutsideRoot`; Orca: `ensurePathWithinWorkspace`, `R/src/main/ipc/worktree-logic.ts`).

### 5.2 Methods

`R` read, `M` mutation, `J` job.

**Repos, groups, folder workspaces (WP-M4-REGISTRY)** — Orca IPC `repos:*`, `projectGroups:*`, `folderWorkspaces:*` (`R/src/main/ipc/repos/*`).

| Method | Cls | Params → result | Notes / errors |
|---|---|---|---|
| `repo.list` | R | `{}` → `{repos:[Repo]}` | |
| `repo.add` | M | `{path, kind?: auto\|git\|folder, displayName?, projectGroupId?}` → `{repo, alreadyKnown}` | `auto` uses `GitService.repository`; creates the main-worktree row. Same path again → `alreadyKnown:true` (not an error). `invalidPath` if missing/not a directory |
| `repo.show` | R | `{id}` → `{repo, mainWorktreeId}` | |
| `repo.update` | M | `{id, displayName?, badgeColor?, worktreeBaseRef?, worktreeBasePath?, setupRunPolicy?, setupAgentStartupPolicy?, commandSourcePolicy?, localSetupScript?, localArchiveScript?, sharedPaths?, externalWorktreeVisibility?}` → `{repo}` | `worktreeBaseRef` validated with `git rev-parse --verify` |
| `repo.remove` | M | `{id, force?}` → `{}` | Refuses `hasLiveSessions` (sessions whose cwd is inside the repo or its worktrees) unless `force`; never deletes files; worktree rows removed, worktrees on disk untouched |
| `repo.reorder` | M | `{ids:[…], projectGroupId?}` | |
| `repo.searchRefs` | R | `{id, query, limit≤50}` → `{refs:[{name, kind: local\|remote\|tag, commit, committedAt}]}` | `for-each-ref` over heads/remotes/tags, sorted by committer date |
| `repo.baseRefDefault` | R | `{id}` → `{ref?, remoteCount}` | `origin/HEAD` → `origin/main` → `main`/`master` (Orca `repo-default-base-ref.ts`) |
| `repo.gitUsername` | R | `{id}` → `{username?}` | `git config github.user`, `user.username`, then `user.name` only if branch-safe (Orca `R/src/main/git/git-username.ts:5,288`). The `gh` login probe is dropped until M9 (M4-D7) |
| `repo.scanNested` | J | `{path, maxDepth?, maxRepos?, timeoutMs?}` → result `{selectedPathKind, repos:[{path, displayName, depth}], truncated, timedOut}` | Limits copied from `R/src/main/project-groups/nested-repo-scan-rules.ts` |
| `repo.clone` | J | `{url, destinationParent, name?}` → result `{repo}` | `userContext` Git mode (§5.3); destination lock against concurrent clone (Orca `clone-path-lock.ts`) |
| `repo.create` | M | `{parentPath, name, initGit: bool}` → `{repo}` | "Create new project" row of Add Project |
| `projectGroup.list/create/update/delete` | R/M | `delete {id, removeProjects?}` | |
| `projectGroup.moveProject` | M | `{repoId, groupId?, index}` | |
| `projectGroup.importNested` | M | `{parentPath, mode: group\|separate, paths:[…]}` → `{group?, projects:[{path, repoId?, status: imported\|already-known\|failed, error?}]}` | Mirrors `ProjectGroupImportResult` |
| `folderWorkspace.list/create/update/delete` | R/M | `create {projectGroupId, name, sourceRepoId?, comment?}` | Never creates a Git checkout; `delete` never deletes the folder |
| `hostSettings.get/set` | R/M | `{keys?}` / `{values:{…}}` | Keys of `host_settings` only |

**Worktrees (WP-M4-WORKTREE-HOST)** — Orca IPC `worktrees:*` and RPC `worktree.*`.

| Method | Cls | Params → result | Notes / errors |
|---|---|---|---|
| `worktree.list` | R | `{repoId?, includeArchived?, includeHidden?, limit?}` → `{worktrees:[Worktree], folderWorkspaces:[…]}` | Merges DB rows with `git worktree list --porcelain -z`; unknown checkouts become `origin='external'` rows (visibility from repo setting); rows whose directory vanished are pruned (Orca: "If you `git worktree remove` from the CLI, Orca will notice") |
| `worktree.show` | R | `{id}` → `{worktree, lineage:{parent?, children[]}, git:{branch, head, ahead?, behind?, clean}}` | |
| `worktree.resolve` | R | `{selector, cwd?}` → `{worktree}` | Selector grammar §6.2 |
| `worktree.suggestName` | R | `{repoId}` → `{name}` | Next free marine-creature name (§8.2) |
| `worktree.prefetchBase` | J | `{repoId, ref}` | Optional `git fetch <remote> <branch>` while the composer is open (Orca `register-worktree-prefetch-handler.ts`) |
| `worktree.create` | J | §8.1 params → `{jobId, worktreeId}` immediately; result `{worktree, setup?: {sessionId}, warnings:[…], baseFallback?}` | Errors before the job starts: `setupDecisionRequired`, `invalidName`, `invalidRef`, `notFound`, `untrustedCommand` |
| `worktree.set` | M | `{id, displayName?, comment?, workspaceStatus?, unread?, pinned?, archived?, visible?, parentId?, noParent?, sortOrder?, manualOrder?}` | Lineage cycle → `badRequest` |
| `worktree.import` | M | `{path}` | Show an external worktree (Orca "Non-smthz worktrees") |
| `worktree.remove` | J | `{id, force?, runHooks?, allowFailedArchiveHook?, deleteBranch? = true, closeSessions? = true}` → result `{preservedBranch?, archiveHookOverride?}` | Main worktree → `badRequest`; dirty without `force` → `worktreeDirty`; locked → `worktreeLocked`; failed archive hook → `archiveHookFailed` (not waived by `force`, CLI semantics in `R/src/cli/specs/core.ts:134-152`) |
| `worktree.ps` | R | `{limit?}` → `{rows:[{worktreeId, displayName, branch, sessions, runningSessions, lastActivityAt, unread}]}` | Session counts from `SessionManager` by cwd prefix |
| `worktree.preservedBranches` | R | `{repoId?}` | |
| `worktree.deletePreservedBranch` | M | `{repoId, branch}` | `git branch -D` (explicit user choice) |
| `worktree.approveHooks` | M | `{repoId, kind, contentHash}` | Writes `hook_trust` |
| `worktree.cleanupScan` | J | `{worktreeIds?}` → candidates (§11) | WP-M4-CLEANUP |
| `worktree.cleanupDismiss` | M | `{worktreeId, fingerprint}` | |
| `sparsePreset.list/save/delete` | R/M | | Orca `repos:*sparsePreset*` (`R/src/main/ipc/repos/sparse-preset-handlers.ts`) |

**Source Control (WP-M4-SCWRITE)** — Orca IPC `git:*` list (grep of `R/src/main/ipc`). All take `worktreePath` (must be a registered root).

| Method | Cls | Notes |
|---|---|---|
| `git.status` | R | Existing parser; plus `operation: merge\|rebase\|cherryPick\|revert\|none` from `.git` markers |
| `git.upstreamStatus` | R | `{upstream?, ahead, behind}`; `rev-list --left-right --count @{u}...HEAD` |
| `git.branchCompare` | R | `{baseRef}` → merge base, ahead/behind, files `diff --name-status -z base...HEAD`, line totals `--numstat` |
| `git.diff` | R | Existing `GitService.diff` (+ `--cached`) |
| `git.history` | R | `{limit≤200}` `log --format` |
| `git.stage` / `git.unstage` | M | `add -- <paths>` / `reset -q -- <paths>`; many paths through `--pathspec-from-file=- --pathspec-file-nul` on stdin (Orca `staging.ts`) |
| `git.stageAll` / `git.unstageAll` | M | `add -A` / `reset -q` |
| `git.discard` | M | Tracked: `restore --worktree -- <paths>`; untracked only with `includeUntracked`: `clean -ffdx -- <paths>` (never path-less; Orca `discard-changes.ts`) |
| `git.commit` | M | `{message, amend?}`; `userContext` mode (hooks **on**); hook failure → `gitFailed` with hook output in `detail`; amend of a pushed commit needs `confirmPushedAmend: true` (Orca "won't amend commits that have already been pushed unless you confirm") |
| `git.push` | J | `push --set-upstream <remote> HEAD:<branch>` or `origin HEAD`; `forceWithLease` only as an explicit flag, never a fallback (Orca `remote.ts:26-60`) |
| `git.pull` / `git.fetch` / `git.sync` | J | `pull` (user's configured mode), `fetch --prune`, sync = pull then push |
| `git.abortMerge` / `git.abortRebase` / `git.continueOperation` | M | `merge --abort`, `rebase --abort`, `<op> --continue` with `GIT_EDITOR=true` |
| `git.checkIgnored` | R | `check-ignore -z --stdin` |
| `git.appendGitignore` | M | Append one line to `<root>/.gitignore` (Explorer "Add to .gitignore") |

**Files and search (WP-M4-FILES)** — Orca IPC `fs:*` (`R/src/main/ipc/filesystem*`).

| Method | Cls | Notes |
|---|---|---|
| `fs.list` | R | `{root, path}` → entries `{name, kind: file\|dir\|symlink, size, mtime}`, directories first, `localizedStandardCompare` natural order (Orca `file-explorer.mdx`); cap 5,000 entries per directory with `truncated` |
| `fs.stat` / `fs.exists` | R | |
| `fs.createFile` / `fs.createDir` | M | Fails `alreadyExists`; never overwrites |
| `fs.rename` | M | Same root only; refuses overwrite |
| `fs.copy` | M | `copyfile(…, COPYFILE_CLONE)` with fallback copy; used by duplicate and drag-drop import |
| `fs.trash` | M | `FileManager.trashItem`, returns `trashedURL` for undo (Orca `fs:deletePath` uses `shell.trashItem`, `R/src/main/ipc/filesystem-mutations.ts:36`) |
| `fs.restore` | M | Move `trashedURL` back (undo of trash) |
| `fs.importExternal` | M | `{root, destDir, sources:[absolute paths]}` drag-drop from Finder |
| `fs.changes` | R | `{root, cursor}` → `{cursor, changed:[relPath], overflow}`; host-side FSEvents watcher per root, ring buffer of 10,000 paths, idle watchers closed after 60 s without polling. Push via H5 later |
| `fs.listFiles` | J | Go to File: `rg --files --null --hidden` then an ignored-files second pass `--no-ignore-vcs` (Orca `R/src/shared/quick-open-filter.ts:207-231`); fallback `git ls-files -z --cached --others --exclude-standard` then `--ignored --exclude-standard`; plain folders fall back to the current FileManager walk. Results paged 5,000 paths per `job.get` |
| `fs.search` | J | §10.1; result pages of files with matches; `job.cancel` = Orca `fs:cancelSearch` |
| `fs.read` / `fs.write` | R/M | **Defined only; implemented by M4-EDITOR** (needs precondition mtime/hash, chunking above 512 KiB) |

### 5.3 Git run modes (WP-M4-0, `GitService.swift`)

| Mode | Config | Hooks | Prompts | Used by |
|---|---|---|---|---|
| `isolatedRead` (today) | `GIT_CONFIG_GLOBAL=/dev/null`, `NOSYSTEM` | off | off | status, list, diff, ls-files, check-ignore, rev-parse |
| `userContext` | user global + system config (identity, credential helpers, `pull.rebase`, `push.default`), repo config | **on** (pre-commit, commit-msg, pre-push) | `GIT_TERMINAL_PROMPT=0`, `GIT_ASKPASS` unset, `SSH_ASKPASS` unset, `GIT_SSH_COMMAND` = `ssh -o BatchMode=yes` only if the user has none | commit, push, pull, fetch, clone, worktree add/remove, branch delete, sparse-checkout |

Plus: streaming stderr (progress parser for `Updating files: N% (x/y)`, `Receiving objects`, `Resolving deltas`), optional stdin (pathspec files), per-call timeout `nil` for writes (Orca uses no timeout for removal: "prod p90 29 s", `R/src/main/git/worktree-removal.ts`), and `authenticationRequired` detection from stderr (`could not read Username`, `Permission denied (publickey)`, `terminal prompts disabled`).

## 6. CLI (`smthz`, mirrors `orca`)

### 6.1 Commands

All accept `--json` (prints `{"ok":true,"result":…}` or `{"ok":false,"error":{"code","message","detail"}}`, exit 1 on error) and `--socket <path>` after the subcommand. Job-backed commands wait for completion, printing phases to stderr, and exit 130 on Ctrl-C after sending `job.cancel`.

| smthz command | Orca source | M4 status |
|---|---|---|
| `smthz repo list` | `R/src/cli/specs/repo.ts` | M4 |
| `smthz repo add --path <path>` | idem | M4 |
| `smthz repo show --repo <sel>` | idem | M4 |
| `smthz repo set --repo <sel> --external-worktree-visibility show\|hide\|inherit` | idem | M4 |
| `smthz repo set-base-ref --repo <sel> --ref <ref>` | idem | M4 |
| `smthz repo search-refs --repo <sel> --query <text> [--limit n]` | idem | M4 |
| `smthz project list` | `R/src/cli/specs/project.ts` | M4 (repos + groups; one host) |
| `smthz project setups / setup-existing-folder / setup-clone / setup-create / setup-update / setup-delete` | idem | **M7** (multi-host) |
| `smthz worktree list [--repo <sel>] [--limit n]` | `R/src/cli/specs/core.ts:44` | M4 |
| `smthz worktree show --worktree <sel>` | `:51` | M4 |
| `smthz worktree current` | `:57` | M4 |
| `smthz worktree create --name <name> [--repo <sel>] [--base-branch <ref>] [--setup run\|skip\|inherit] [--parent-worktree <sel>\|--no-parent] [--comment <text>] [--activate] [--run-hooks]` | `:67-133` | M4. `--agent/--prompt/--model/--effort/--surface/--retry-launch` → M5; `--issue/--pr/--linear-issue/--gitlab-*/--reference*` → M9; `--project/--host/--project-host-setup` → M7 |
| `smthz worktree set --worktree <sel> [--display-name] [--comment] [--workspace-status <id>] [--unread\|--read] [--parent-worktree <sel>\|--no-parent]` | `R/src/cli/specs/worktree-set.ts` | M4 (link flags → M9) |
| `smthz worktree rm --worktree <sel> [--force] [--run-hooks] [--allow-failed-archive-hook]` (aliases `remove`, `delete`) | `core.ts:134-152` | M4 |
| `smthz worktree ps [--limit n]` | `core.ts:154` | M4 |
| `smthz file open / diff / open-changed` | `R/src/cli/specs/file.ts` | **M4-EDITOR/M4-DIFF** (need an app window, like Orca's `renderer_unavailable`) |
| `smthz search …` | `R/src/cli/specs/search.ts` | **M5-HISTORY** (agent-session search, not ripgrep) |
| `smthz reference …` | `R/src/cli/specs/reference.ts` | M9 |

`--activate` asks the app to reveal the worktree: M4 implements it as a host flag `revealRequested` that the app's `HostMonitor` poll picks up (no app↔CLI channel exists yet) **[design choice]**.

### 6.2 Selectors (`WorkspaceSelectors.swift`, WP-M4-0)

`id:<uuid>`, `path:<abs path>` (canonicalized; also matches any path *inside* a worktree), `branch:<name>`, `name:<display name>` (exact, case-insensitive; ambiguous → error listing candidates), `active` / `current` (the worktree containing the caller's cwd, longest-prefix match; Orca `R/docs/site/content/docs/cli/reference.mdx` "Selectors"). Repo selectors: `id:`, `path:`, `name:`. `issue:<n>` → M9.

Default parent for `worktree create` without `--parent-worktree`/`--no-parent`: the `current` worktree if the cwd is inside one, recorded with `capture_source='cwd-context'`, `confidence='inferred'` (Orca `core.ts` notes). Repo default when `--repo` is omitted: repo of the `current` worktree, else error `badRequest` "pass --repo".

## 7. Per-repo config file (`smthz.yaml` proposal)

### 7.1 Name and lookup (decision M4-D1)

Recommended: **`smthz.yaml`** at the repo root; **if absent, read `orca.yaml` read-only** for compatibility (a repo already set up for Orca, like `R/orca.yaml` itself, works unchanged). Never both: `smthz.yaml` wins entirely, no merge. Same for the issue-command override: `.smthz/issue-command`, then `.orca/issue-command`. **`.worktreeinclude` keeps its name** (it is not Orca-branded). Alternatives for the user: (b) `smthz.yaml` only; (c) `.smthz/config.yaml`; (d) read `orca.yaml` only (pure compatibility).

### 7.2 Keys (same semantics as `R/docs/site/content/docs/model/orca-yaml.mdx`)

| Key | Type | Semantics |
|---|---|---|
| `scripts.setup` | non-empty string (block scalar ok) | Runs in a **Setup** terminal in the new worktree when the setup decision is "run" |
| `scripts.archive` | non-empty string | Runs with the worktree as cwd before archive/removal when hooks are enabled; failure blocks removal unless waived |
| `setupAgentStartupPolicy` | `start-immediately` \| `wait-for-setup` | Stored; only affects agent start (M5). Default `start-immediately`; a local wait setting wins |
| `issueCommand` | non-empty string, `{{artifact_url}}`, legacy `{{issue}}` | Stored and trusted; used from M9 |
| `defaultTabs` | list (≤256) of `{title?, command?, color? (#RGB/#RRGGBB)}`, ≥1 valid field each | Terminal tabs created once for the new worktree; commands follow the setup run decision and are suppressed under `local-only`; do not wait for setup |
| `worktree.sharedDirectories` | list of repo-relative dirs (first 100 entries) | Existing **gitignored directories** of the primary checkout, **symlinked** into the new worktree; added to the repo's Shared Paths setting |
| `environmentRecipes` | list | **Parsed and ignored with a diagnostic** until M8-VM |

Rules copied from Orca: all keys optional; invalid fields dropped while valid siblings apply; unknown keys ignored; `scripts`/`worktree` must be mappings, lists must be lists. **Whole file rejected** on invalid YAML, duplicate mapping key anywhere, non-mapping root, file > 262,144 UTF-8 bytes, alias expansion over 100. Strings > 65,536 UTF-8 bytes dropped. `sharedDirectories` paths: normalize `\`→`/`, strip leading `./` and trailing `/`, dedupe; reject absolute, `..`, `.`, empty segments, any `.git` segment.

Which checkout supplies what (Orca table, kept): setup script, startup policy and `defaultTabs` from the **new worktree's** file; shared directories, `.worktreeinclude` and the archive script from the **primary checkout**; issue command from the primary checkout's override file, then its YAML.

Setup runner: `$(git rev-parse --git-path smthz/setup-runner.sh)` inside the new worktree, `#!/usr/bin/env bash` + `set -e` (a leading `#!` line's shell options replayed), mode 0755; environment `SMTHZ_ROOT_PATH`, `SMTHZ_WORKTREE_PATH`, `SMTHZ_WORKSPACE_NAME` (directory basename) plus, **when the file came from `orca.yaml`**, `ORCA_ROOT_PATH`, `ORCA_WORKTREE_PATH`, `ORCA_WORKSPACE_NAME`, `CONDUCTOR_ROOT_PATH`, `GHOSTX_ROOT_PATH` (Orca's names, `R/src/main/setup-hook-env-vars.ts`) so Orca-authored scripts keep working (part of M4-D1).

Command source policy (`shared-only` / `local-only` / `run-both`, local hooks stored in `repos.local_*_script`) and run policy (`ask` / `run-by-default` / `skip-by-default`, CLI `--setup run|skip|inherit`) as in Orca. **Trust**: a shared (YAML) script runs only if `hook_trust` holds its SHA-256 for that repo and kind; otherwise the app shows an approval dialog (script text, "Run once" / "Always trust this version" / "Skip") and the CLI fails with `untrustedCommand` unless `--setup run` is combined with a prior approval. Local scripts are user-authored and need no approval (Orca `orca-yaml.mdx` "Shared YAML commands use Orca's approval flow").

### 7.3 `.worktreeinclude`

One literal repo-relative path per line; blank lines and `#` lines ignored; no inline comments; globs (`*`, `?`) and negation (`!`) skipped with a warning; regular file ≤ 256 KiB; ≤ 1,000 candidates. Only existing **gitignored** entries are copied (`git check-ignore`), privately: APFS `clonefile`/`copyfile(COPYFILE_CLONE)` when possible, else a byte copy that must fit a budget of **2 GiB and 50,000 entries per worktree** (clones consume only the entry budget); over-budget entries skipped with a warning. Top-level symlink sources copy their target; nested symlinks stay links. Order: Settings shared paths (clone-copy on APFS, else symlink) → YAML shared dirs (always symlink) → include copies; an already-present destination is never overwritten.

## 8. Worktree creation flow

### 8.1 Request

`worktree.create {repoId, name, nameWasGenerated?, displayName?, startFrom?: {kind: base|branch|commit|remote-branch, ref}, branchName?, parentId?|noParent?, comment?, setup?: run|skip|inherit, sparse?: {directories:[…], presetId?}, defaultTabs?: bool = true, createdBy: desktop|cli}`.

### 8.2 Names (pure code, WP-M4-CONFIG `WorktreeNaming.swift`)

1. **Display name** = what the user typed (emoji kept). If empty, the composer fills a generated **marine-creature name** (`worktree.suggestName`): the 552-name pool of `R/src/shared/marine-creature-names-primary.ts` + `-secondary.ts` (276 entries each, grep count) **or a smthz-owned pool (M4-D6)**; retired per repo after use (`retired_names`), tiers `name`, `name-2`, … (`R/src/shared/worktree/retired-name-registry.ts`).
2. **Sanitized name** (directory and branch leaf), port of `sanitizeWorktreeName` (`R/src/main/ipc/worktree-logic.ts:28`): known emoji → shortcodes (🚀 → `rocket`), trim, runs of characters other than Unicode letters/numbers/`._-` → `-`, collapse `-`, collapse `..`+ → `.`, strip leading/trailing `.`/`-`; emoji-only input → `workspace`; empty/`.`/`..` → `invalidName`.
3. **Branch** = explicit `branchName` (must not start with `-`, must pass `git check-ref-format --branch`) or `prefix/sanitized`. Prefix strategy `git-username` (default), `custom`, `none`; normalization strips surrounding `/`, collapses `//`, rejects `~^:?*[\`, controls and spaces; an invalid **git-username** prefix is silently dropped, an invalid custom prefix fails (`R/src/shared/branch-prefix.ts`, `R/src/main/ipc/worktree-branch-name.ts:44-62`).
4. **Collisions**: up to 100 attempts with suffix `-2`, `-3`, … on both sanitized name and branch (`R/src/main/worktree-create-candidates.ts:8`); a candidate is rejected if the local branch exists (unless it can be checked out as-is: same commit as the base and not checked out elsewhere, `canCheckoutExistingLocalBranch`, `R/src/main/runtime/runtime-worktree-create-git.ts:43`), a remote branch of that name exists, or the path exists. Exhaustion → `branchExists` / `invalidName`.
5. **Path** = `<workspaceDir>/<repo basename without .git>/<sanitized>` when `nestWorkspaces`, else `<workspaceDir>/<sanitized>`; `repos.worktree_base_path` overrides `workspaceDir` (relative to the repo path); must stay inside the root (`computeWorktreePath`, `worktree-logic.ts:87`). Default `workspaceDir` per M4-D4.

### 8.3 Job phases (progress shown on the sidebar card and in the workspace's pending tab)

| # | Phase | Work | Rollback on failure/cancel |
|---|---|---|---|
| 0 | validate (synchronous, before `jobId`) | repo exists and is git; setup decision resolvable (`ask` + no explicit decision → `setupDecisionRequired`, **before** any Git work, as Orca does); trust of YAML hooks known | none |
| 1 | resolveBase | base = `startFrom.ref` ?? `repos.worktree_base_ref` ?? `repo.baseRefDefault`; for a remote-tracking base, `fetch <remote> <branch>` (`userContext`, skipped offline with a `baseFallback` warning to the local ref, Orca `allowLocalBaseFallback`); `remote-branch` start fetches and checks out that branch | none |
| 2 | resolveName | §8.2 | none |
| 3 | add | `worktree add --no-track -b <branch> <path> <base>` (or `<path> <branch>` for an existing branch; `--no-checkout` for sparse); progress parsed from stderr; then `config --local branch.<branch>.base <base>` and `push.autoSetupRemote=true` only if unset at any scope (`R/src/main/git/worktree-add.ts:85-140,225-290`) | `worktree remove --force <path>`; `branch -D <branch>` **only if this job created it** |
| 4 | sparse (optional) | `sparse-checkout init --cone`, `set -- <dirs>`, `checkout <branch>` (`R/src/main/git/worktree-sparse-add.ts`) | as 3 |
| 5 | materialize | shared paths, YAML shared dirs, `.worktreeinclude` (§7.3); warnings collected | as 3 (plus delete created links/copies) |
| 6 | persist | `worktrees` row `state='ready'`, lineage row, retire generated name | row → `failed` with error |
| 7 | setup (optional) | write runner, `session.create` (`/bin/bash <runner>`, cwd = worktree, env vars) → `setup.sessionId`; job **succeeds when the session starts**; setup exit status is shown by the Setup tab (Orca: setup runs in a terminal, it does not gate creation) | none (worktree kept) |
| 8 | defaultTabs | returned as data; the **app** creates the tabs (layout is app-owned, M3 D1) | none |

Cancellation is honoured in phases 1–5 (kill Git, roll back). A host stop during a job leaves `state='creating'` (handled in §8.6). The composer closes immediately; failure shows on the card with **Retry** (re-issues the same request with a new request id).

### 8.4 Removal and archive

`worktree.remove` job: (1) refuse main worktree; (2) if `runHooks` and an archive script applies: run it (a session in the worktree, wait for exit, 10 min cap); non-zero → `archiveHookFailed` unless `allowFailedArchiveHook` (result carries `archiveHookOverride`); (3) close the host sessions whose cwd is inside the worktree when `closeSessions` (default true; the app asks first, as Orca's delete confirmation does); (4) `worktree remove [--force] <path>` with no timeout; (5) branch: skip if `preserve_branch_on_delete`; else `branch -d -- <branch>`; if refused because not merged, test "no unmerged tree changes" (squash-merge case, `R/src/main/git/worktree-branch-removal.ts:124`) and delete if proven, otherwise record in `preserved_branches` and return `preservedBranch`; (6) delete the row and its lineage edges (children's parent cleared). Bulk deletes return the preserved list for the **Review N Branches** dialog.

**Archive** = `worktree.set {archived:true}` (hidden from the sidebar, files kept), running the archive hook first only when hooks are enabled. **[unverified]**: the Orca docs say the archive script runs "before archive/removal" but the exact archive UI path was not traced in code; the implementing worker confirms in `R/src/main/ipc/worktrees/removal/*` and `R/src/shared/worktree/archive-hook-removal-gate.ts`.

### 8.5 External worktrees

`git worktree list` entries not created by smthz become `origin='external'` rows; visible per `repos.external_worktree_visibility` (default **hide**, Orca default for new repos per `repo-types.ts` comments) or per-row `is_visible`. Built-in sources (Claude Code / GSD worktree roots) and custom roots → M4 stores only `show/hide`; the source classification is deferred (M4-D9).

### 8.6 Host restart reconciliation

On `smthzd` start: rows in `creating` → if `git worktree list` has the path and the branch exists → run phases 5–6 again is **not** attempted; mark `failed` with `hostRestarted` and offer Retry/Delete in the UI; rows in `removing` → if the path is gone and Git no longer lists it, finish (branch step + delete row), else `remove_failed`. Covered by a test that kills `smthzd` mid-job.

## 9. Source Control write operations (app behaviour)

Panel (`SourceControlPanel.swift`): staged / changes / untracked / conflicts lists (exist), row actions stage/unstage/discard (confirmation dialog for discard, irreversible for untracked), header stage-all/unstage-all, **commit box** (multi-line, ⌘↩ commits when focus is in the panel), primary button cycling **Stage Files → Commit → Push / Pull / Sync** by state (Orca `commit-push.mdx`), Amend as an explicit menu item, **Force push with lease** shown separately only when local history was rewritten (`ahead>0 && behind>0` and the upstream commits are ancestors of reflog entries — **[unverified]** heuristic; Orca's exact rule not traced), branch row `branch → base` with `+added −removed` chip from `git.branchCompare`, conflict banner with **Abort merge/rebase** and **Continue**. AI actions (Generate with AI, Fix with AI, Resolve with AI) stay disabled until M5. Status refresh: after every mutation plus `fs.changes` on `.git/index` and `HEAD` (no 1 s polling of `git status`).

## 10. Explorer, search, Go to File

### 10.1 Folder search (ripgrep)

Args (port of `buildRgArgs`, `R/src/shared/text-search.ts`): `--no-config --json --hidden --glob '!.git' --max-filesize 5M`, `--ignore-case` unless case-sensitive, `--word-regexp`, `--fixed-strings` unless regex, include/exclude globs (comma-separated), `-- <query> .` with cwd = root. Limits: **2,000 matches** (`DEFAULT_SEARCH_MAX_RESULTS`), **15 s** timeout, line text capped (`MAX_LINE_CONTENT_LENGTH`, value to copy from `R/src/shared/text-search-match-accumulator.ts`). Fallback when no bundled `rg` (M4-D3): `git grep -n -I --column --untracked [-i] [-w] [-F|-E] -- <query>` (1.09 s on 38,768 files **[measured]**), non-Git folders: in-process scan with the same caps. UI: a **Search** panel in the right sidebar (⌘⇧F, Orca `sidebar.search.toggle`), Explorer folder context menu **Find in Folder** pre-scopes it; results grouped by file, click = open (M4-EDITOR) — until the editor exists, click reveals in Finder / opens with the default app (`NSWorkspace`), flagged as interim.

### 10.2 Go to File (⌘P)

`fs.listFiles` (tracked first, then gitignored second pass, Orca `quick-open.mdx`), ranking by recency (app-local recent list per worktree) + fuzzy score; filename-first rows with truncated parent; open as in §10.1 until the editor lands. Replaces the FileManager walk in `GoToFilePalette.swift:116` for Git roots (no more 10,000-entry cap; `git ls-files` lists 38,768 paths in 0.01 s **[measured]**).

### 10.3 Explorer operations

New File / New Folder (inline name field), Rename (inline, Enter/Escape), Delete → Trash (with confirmation for folders), Duplicate (`fs.copy`, clone), Copy Path / Copy Relative Path (⌥⌘⇧C, Orca `fileExplorer.copyRelativePath`), Copy (file to pasteboard as file URL), Reveal in Finder, Open in Terminal (new tab with cwd), Find in Folder, Add to .gitignore, Stage / Discard (via `git.*`), drag-drop from Finder (copy in via `fs.importExternal`), drag within the tree (move = `fs.rename`), **undo/redo** of the last 50 operations (⌘Z / ⇧⌘Z in Explorer scope, Orca `fileExplorer.undo/redo` in `R/src/shared/keybindings/definitions-core-3.ts:153-171`; trash undone via `fs.restore`), Git status colours (untracked, modified, staged, ignored, conflict) from `git.status` + `git.checkIgnored` for visible rows, live refresh from `fs.changes`. Natural sort, directories first. Download (SSH/remote) → M7.

## 11. Workspace cleanup (Resource Manager → Clean up workspaces)

Port of the classifier in `R/src/shared/workspace-cleanup.ts`: idle threshold 30 days, archived idle 7 days (`:7-8`), reasons `archived`/`idle-clean`, blockers `main-worktree`, `folder-repo`, `pinned`, `active-workspace`, `running-terminal`, `dirty-files`, `unpushed-commits`, `unknown-base`, `git-status-error`, `dismissed` (agent/editor/SSH blockers return when those features exist). Queue blockers (never selectable): main-worktree, folder-repo; force-remove blockers (need explicit force): dirty-files, unpushed-commits, unknown-base. Candidate row: name, branch, path, size (`du`-equivalent, bounded walk), last activity, Git clean/ahead/behind, session counts, fingerprint (hash of the evidence; a dismissal holds until the fingerprint changes). UI: list with search/filter/sort and multi-select, bulk delete through `worktree.remove` jobs, then the preserved-branches review. Batch limit 500 (`WORKSPACE_CLEANUP_TARGET_BATCH_LIMIT`).

## 12. Work packages

### 12.1 Order and lanes

| Phase | Lane A | Lane B | Gate |
|---|---|---|---|
| 1 | **WP-M4-0 HOSTCORE** (3–4 wd) | **WP-M4-CONFIG** (2–3 wd) | M4-D2 for CONFIG (parser) |
| 2 | **WP-M4-REGISTRY** (5–6 wd) | **WP-M4-SCWRITE** (5 wd) | HOSTCORE done |
| 3 | **WP-M4-WORKTREE-HOST** (7–8 wd) | **WP-M4-FILES** (5–6 wd) | REGISTRY + CONFIG done; M4-D3 for FILES packaging; M4-D1/D4 for WORKTREE-HOST |
| 4 | **WP-M4-WORKTREE-APP** (4–5 wd) | free (e.g. PARITY WP 10 M1-EDITOR) | WORKTREE-HOST done |
| 5 | **WP-M4-CLEANUP** (3 wd) | free | WORKTREE-APP done |

Total 34–40 wd of M4 work (two lanes ≈ 22–26 calendar worker-days). Cross-milestone conflicts: **H5-STREAM** edits `HostService.swift`/`HostClient.swift` → run it before or after HOSTCORE, never together. **FIX-HOSTRECONNECT, A3-GROUPS, A4-WINDOWS** edit `ShellController.swift`/`ShellView.swift` → never in parallel with REGISTRY or WORKTREE-APP. **A5-KEYS** owns `Keybindings.swift`/`SmthzApp.swift`: M4 WPs add their shortcuts as view-local `.keyboardShortcut` and list them in `docs/UI-WIRING.md` for A5 to migrate.

### 12.2 File scope matrix (each file has exactly one owner WP)

| File | Owner |
|---|---|
| `Sources/SmthzCore/HostService.swift` (router hook, read/mutation/job classes), `HostClient.swift` (raw/detail call), `GitService.swift` (run modes, streaming stderr, stdin), `Sources/smthzd/main.swift` (open store, register handlers, reconcile), `Sources/smthz/main.swift` (dispatch hook, `--json`) | HOSTCORE |
| New `Sources/SmthzCore/HostRouter.swift`, `HostJobs.swift`, `WorkspaceStore.swift` (schema v1 + migrations + base helpers), `WorkspaceSelectors.swift`, stubs `RepoRPC.swift`, `WorktreeRPC.swift`, `GitWriteRPC.swift`, `FilesRPC.swift`, `CleanupRPC.swift`; new `Sources/smthz/CLICommon.swift` (flag parsing, JSON envelope, job wait) and stubs `RepoCommands.swift`, `WorktreeCommands.swift` | HOSTCORE (creates), later owners fill the stubs |
| New `Sources/SmthzCore/SmthzConfig.swift`, `WorktreeInclude.swift`, `WorktreeNaming.swift`, `MarineCreatureNames.swift`, `EmojiShortcodes.swift`; `Package.swift` + `THIRD-PARTY-NOTICES.md` **only if** M4-D2 = Yams / M4-D5 = emojibase | CONFIG |
| `RepoRPC.swift`, new `WorkspaceStore+Repos.swift`, `NestedRepoScan.swift`, `HostClient+Repos.swift`; `Sources/smthz/RepoCommands.swift`; app: `Dialogs/AddProjectDialog.swift`, `Sidebar/SidebarView.swift`, `Sidebar/ProjectHeaderRow.swift`, `Sidebar/ProjectActionsMenu.swift`, `Sidebar/WorkspaceCardView.swift`, `Sidebar/WorkspaceContextMenu.swift`, `Sidebar/WorkspaceOptionsMenu.swift`, `Palette/JumpPaletteModel.swift`, `Palette/JumpPalette.swift`, `ShellController.swift`, `ShellView.swift`; new `Sources/SmthzApp/Workspaces/WorkspaceCatalogModel.swift`, `Dialogs/NestedImportDialog.swift`, `Dialogs/ProjectGroupDialog.swift` | REGISTRY |
| `GitWriteRPC.swift`, new `GitSourceControl.swift` (GitService extension), `HostClient+Git.swift`; app: `RightSidebar/SourceControlPanel.swift`, new `RightSidebar/SourceControlCommitBox.swift`, `Dialogs/DiscardChangesDialog.swift` | SCWRITE |
| `WorktreeRPC.swift`, new `WorkspaceStore+Worktrees.swift`, `WorktreeCreator.swift`, `WorktreeRemover.swift`, `WorktreeMaterializer.swift`, `SetupRunner.swift`, `GitWorktreeOps.swift` (GitService extension), `HostClient+Worktrees.swift`; `Sources/smthz/WorktreeCommands.swift` | WORKTREE-HOST |
| `FilesRPC.swift`, new `FileOperations.swift`, `FileSearch.swift`, `FileListing.swift`, `FileWatcher.swift`, `HostClient+Files.swift`; app: `RightSidebar/ExplorerPanel.swift`, new `RightSidebar/SearchPanel.swift`, `RightSidebar/ExplorerUndoStack.swift`, `Slots/RightSidebarSlot.swift`, `RightSidebarView.swift`, `Palette/GoToFilePalette.swift`; `scripts/package-app.sh` (rg bundling, if M4-D3 = bundle) | FILES |
| app: `Dialogs/NewWorkspaceComposer.swift`, `Dialogs/DeleteWorkspaceDialog.swift`, new `Dialogs/EditWorkspaceDialog.swift`, `Dialogs/SetupApprovalDialog.swift`, `Dialogs/PreservedBranchesDialog.swift`, `Dialogs/RepositorySettingsSheet.swift`, `Sidebar/WorkspaceStatusSlot.swift`; second edit pass (sequential) of `Sidebar/WorkspaceCardView.swift`, `Sidebar/WorkspaceContextMenu.swift`, `ShellController.swift`, `ShellView.swift`, `Palette/JumpPalette*.swift` | WORKTREE-APP |
| `CleanupRPC.swift`, new `WorkspaceCleanup.swift`; app: `StatusBar/ResourceManagerPopover.swift`, new `Dialogs/WorkspaceCleanupView.swift` | CLEANUP |
| Tests: one new test file per WP (names below); no WP edits another WP's test file. Each WP updates only its rows in `docs/UI-WIRING.md` | each |

Parallel pairs are disjoint by construction: CONFIG ∥ HOSTCORE (CONFIG has only new files; `Package.swift` is touched by nobody else in M4), REGISTRY ∥ SCWRITE, WORKTREE-HOST ∥ FILES.

### 12.3 Package specs

Verification common to all (coordinator routine from AGENTS.md): scope diff equals the listed files; `Package.swift` unchanged unless listed; `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build` and the full suite 3× with the test count rising by the WP's new tests; no stray `smthzd`/`git` processes; e2e with a **private host** (`smthzd --state-dir /tmp/smthz-m4 &`, CLI `/tmp/smthz-verify/debug/smthz <cmd> --socket /tmp/smthz-m4/smthzd.sock`), on throwaway repos under `/tmp/smthz-m4-repos` — **never** on the smthz repo itself. Real temp Git repos in tests (pattern of today's `GitServiceTests`), with local bare repos as remotes; no network.

**WP-M4-0 HOSTCORE (Lane A, 3–4 wd, deps: none; not concurrent with H5-STREAM)**
- Do: router with method classes (§5.1) dispatched **before** `HostService.lock`, keeping auth, admission (64 pending), deadline and cancel; journaling for mutation/job classes only; per-repo gate; `HostJobs` registry with `job.get/cancel/list`; `WorkspaceStore` (schema v1 §4, `user_version`, migration test from empty and from v1); `GitService` modes, streaming stderr with progress callback, stdin, `nil` timeout for writes, `authenticationRequired` detection; `HostClient` raw call keeping `detail`; selectors; CLI common (`--json`, job wait with Ctrl-C → `job.cancel`); stub handlers returning `unknownMethod`.
- Tests (`HostRouterTests`, `HostJobTests`, `WorkspaceStoreTests`, `GitRunModeTests`, `WorkspaceSelectorTests`): a 3 s fake job does not delay a concurrent `session.write` (< 100 ms); read methods leave no `events` rows; job replay by request id returns the same `jobId`; cancel kills a `git` child (no stray process); `userContext` commit succeeds in a temp repo whose identity comes from a temp `GIT_CONFIG_GLOBAL` file while `isolatedRead` fails (reproduces §2.2); progress parser on recorded `Updating files` output.
- Accept: existing 275 tests still pass ×3; e2e `smthz ping` and sessions unchanged; `job.list` answers on a private host.

**WP-M4-CONFIG (Lane B, 2–3 wd, deps: M4-D2 (and D5/D6) decided)**
- Do: `SmthzConfig` parser (§7.2, file lookup per M4-D1, limits, diagnostics list), `.worktreeinclude` parser (§7.3), path normalizer, `WorktreeNaming` (sanitize, emoji → shortcode, prefix strategies, collision candidates, creature pool and tiers), SHA-256 content hash helper for trust.
- Tests (`SmthzConfigTests`, `WorktreeNamingTests`): every rule in §7.2/§7.3 including duplicate key rejection, 262,145-byte file, 65,537-byte field, alias bomb, invalid colour, `../x` and `.git/x` paths, glob/negation skipped; sanitize table (`"../../foo"` → `foo`, `"🚀"` → `rocket`, `"🚀🚀"` with no shortcode dataset → `workspace`, CJK kept); prefix `team//x/` → `team/x`; `R/orca.yaml` parses (setup script present).
- Accept: pure library, no host/app change; if Yams is added, exact pin and notice entry.

**WP-M4-REGISTRY (Lane A, 5–6 wd, deps: HOSTCORE; not concurrent with A3/A4/FIX-HOSTRECONNECT)**
- Do: `repo.*`, `projectGroup.*`, `folderWorkspace.*`, `hostSettings.*`, `repo.scanNested/clone/create` (§5.2); CLI `repo list|add|show|set|set-base-ref|search-refs`, `project list`; app: Add Project dialog real (Browse → `repo.add`, nested-repo import dialog for folders with several repos, Clone from URL with destination and progress, Create new project), sidebar = project headers + one card per worktree/folder workspace (main checkout card for each repo), sort/group/filter from `WorkspaceOptionsMenu` applied, pin/unread persisted through `worktree.set`, project group create/rename/colour/collapse/delete (with "also remove projects"), drag-reorder repos; `ShellController` switches the active `WorkspaceKey` (`worktree:<id>`/`folder:<id>`/`home`), Explorer/Source Control/Go to File follow the active workspace root; Jump palette lists projects and workspaces.
- Tests (`RepoRegistryTests`): add git repo/plain folder/missing path, duplicate add, remove with live session refused, nested scan with depth/limit/timeout, clone from a local bare repo, store survives host restart.
- E2E: `smthz repo add --path /tmp/smthz-m4-repos/a --json` twice (second `alreadyKnown`), `repo list`, `repo set-base-ref`, restart host → still listed; app with private state dir shows the project and its main card; switching cards changes Explorer root; two workspaces keep separate tabs across app restart.

**WP-M4-SCWRITE (Lane B, 5 wd, deps: HOSTCORE)**
- Do: §5.2 Source Control methods and §9 UI.
- Tests (`GitSourceControlTests`): stage/unstage single, many (pathspec file with 5,000 paths) and non-ASCII paths; discard tracked vs untracked (untracked refused without flag); commit with a temp global identity; pre-commit hook rejecting → `gitFailed` with hook output; amend; push to a local bare remote first time (upstream set) and again; push rejected (non-fast-forward) is reported, **never** auto-forced; force-with-lease succeeds only when lease matches; pull ff and conflict; abort merge/rebase; `authenticationRequired` on a URL needing credentials (fake `http://127.0.0.1:1/x.git` must fail fast, not hang).
- E2E: in a temp repo with a bare remote: edit file in a session → panel shows it → stage → commit → push → `git -C bare log` shows the commit; the primary button walks Stage → Commit → Push.

**WP-M4-WORKTREE-HOST (Lane A, 7–8 wd, deps: REGISTRY, CONFIG, M4-D1, M4-D4)**
- Do: §5.2 worktree methods, §8 complete (phases, rollback, sparse, materialize, trust, setup session, removal, preserved branches, external worktrees, reconciliation), CLI `worktree list|show|current|create|set|rm|ps`.
- Tests (`WorktreeLifecycleTests`): create from base, from local branch, from commit, from remote branch (local bare remote); generated-name retirement and suffixes; branch prefix strategies; existing-branch checkout; path outside root refused; sparse create materializes only listed dirs; `.worktreeinclude` copies an ignored `.env` and skips tracked/missing/glob entries; YAML shared dir becomes a symlink; budget overflow warning (test with a lowered budget); setup runs in a session with the env vars and `set -e`; `ask` policy refuses before any Git work (no directory, no branch created); cancel during a slow add (fake slow `git` via a large repo or an injected delay) rolls back fully; remove clean, dirty (refused / forced), with archive hook failing (blocked, waived), unmerged branch preserved, squash-merged branch deleted; host killed mid-create → `failed/hostRestarted` after restart.
- E2E: `smthz worktree create --repo path:/tmp/smthz-m4-repos/a --name ":rocket: fix login" --json` → branch `<prefix>/rocket-fix-login`, path under the workspace root, `worktree list` shows it, `git worktree list` agrees; `worktree current` from inside it; `worktree rm --run-hooks` with a failing archive script → exit 1 `archiveHookFailed`; with `--allow-failed-archive-hook` succeeds; no stray processes.

**WP-M4-FILES (Lane B, 5–6 wd, deps: HOSTCORE; M4-D3 for packaging)**
- Do: §5.2 file methods, §10 search panel, Go to File, Explorer operations with undo/redo, FSEvents changes, rg detection (bundled path → none → `git grep` → in-process).
- Tests (`FileOperationsTests`, `FileSearchTests`): create/rename/copy/trash/restore inside root; symlink escape and `..` refused; natural sort (`9, 99, 100`); FSEvents reports an external write within 2 s; search fixed-string/regex/whole-word/case, include/exclude globs, 2,000-match truncation, cancel; listFiles tracked then ignored pass; behaviour with and without `rg`.
- E2E: Explorer New File → file on disk; Rename; Delete → in Trash; ⌘Z restores it; ⌘⇧F finds a string in the private repo; ⌘P lists 38k+ files of a large temp repo without truncation; an external `touch` appears in Explorer without manual refresh.

**WP-M4-WORKTREE-APP (Lane A, 4–5 wd, deps: WORKTREE-HOST; not concurrent with A3/A4)**
- Do: composer real (Project combobox with "Add a new project" pinned, Name with `:shortcode:` suggestions, Create From: **Name** and **Branch** sources real; Smart/GitHub/GitLab/Linear/Jira stay VISUAL-ONLY until M9; start-from picker via `repo.searchRefs`; Advanced: branch name, parent workspace, sparse directories/presets, setup run toggle; "Create more"), card progress row with phase/percent and Cancel, failure row with Retry/Delete, pending tab replaced by the terminal when ready, Setup tab + `defaultTabs` created by `ShellController`, setup approval dialog, Edit Workspace Details, inline rename, children chip/collapse, Delete dialog real (multi-select, "also delete branch", close-sessions warning, archive hook toggle), Review N Branches dialog, Repository settings sheet (base ref, setup/command-source policy, local hooks, shared paths, external worktree visibility), Jump palette "Create worktree" row.
- E2E (screenshots + `smthz worktree list`): create from composer → card with progress → terminal opens in the new path (`pwd`); setup tab output visible; delete with unmerged commit → Review branches dialog lists it; app restart keeps tabs per worktree.

**WP-M4-CLEANUP (Lane A, 3 wd, deps: WORKTREE-APP)**
- Do: §11.
- Tests (`WorkspaceCleanupTests`): classifier table for each blocker/reason, fingerprint changes un-dismiss, batch limit.
- E2E: three temp worktrees (idle clean, dirty, pinned) → only the first is selectable without force; bulk delete removes it and lists nothing else.

## 13. Decisions for the user

| # | Decision | Options | Recommendation | Blocks |
|---|---|---|---|---|
| M4-D1 | Per-repo config file name and Orca compatibility | (a) `smthz.yaml`, fall back to read-only `orca.yaml` (+ `ORCA_*` env aliases only then); (b) `smthz.yaml` only; (c) `.smthz/config.yaml`; (d) `orca.yaml` only | (a) | CONFIG, WORKTREE-HOST |
| M4-D2 | YAML parser | (a) add **Yams** (MIT, wraps libyaml; exact pin, `Package.swift` change); (b) hand-written subset parser; (c) use JSON/TOML instead of YAML (breaks Orca compatibility) | (a); duplicate-key rejection must be verified by test (**[unverified]** whether Yams rejects duplicates itself; if not, detect them while walking the composed node tree) | CONFIG |
| M4-D3 | Ripgrep | (a) bundle a pinned `rg` binary (ripgrep is MIT/Unlicense) in `Contents/Resources` via `package-app.sh`, notice entry; (b) use `rg` from PATH if present, else `git grep`; (c) `git grep` only | (a) with (b)'s fallback chain; Orca bundles `@vscode/ripgrep-universal` 1.18.0 (`R/package.json:269`) | FILES packaging |
| M4-D4 | Default worktree folder and layout | `~/smthz/workspaces/<repo>/<name>` (mirrors Orca's `~/orca/workspaces`, nested) vs `~/Library/Application Support/smthz/workspaces` (space in path hurts shells) vs next to the repo (`<repo>-worktrees/`) | `~/smthz/workspaces`, nested | WORKTREE-HOST |
| M4-D5 | Emoji shortcode data | (a) embed emojibase-data 17.0.0 shortcodes (MIT; Orca uses it, `R/package.json:289`) as generated Swift source (no `Package.swift` resources); (b) native `CFStringTransform` names only (branch names differ from Orca: 😀 → `grinning-face` vs `grinning`; no `:shortcode:` picker) | (a) | CONFIG |
| M4-D6 | Generated workspace names | reuse Orca's 552 marine-creature names (data from Orca's MIT-licensed source) vs a smthz-owned pool | reuse (parity), attribution in notices — **[unverified]** licence of the name lists themselves; Orca repo licence file `R/LICENSE` to be checked by CONFIG | CONFIG |
| M4-D7 | `git-username` prefix source | Git config keys only (`github.user`, `user.username`, branch-safe `user.name`) vs also probing `gh api user` like Orca | config only in M4; `gh` probe arrives with M9 GitHub. **Possible small reduction**: users relying only on `gh` login get no prefix until M9 | WORKTREE-HOST |
| M4-D8 | Files opened from Go to File / Search / Explorer before the editor exists | reveal in Finder / open with default app vs keep disabled | open with default app (interim), clearly labelled; replaced by M4-EDITOR | FILES |
| M4-D9 | External worktree source classification (Claude Code / GSD / custom roots, inbox) | implement in M4 vs show/hide only | show/hide only in M4; full classification later. **Possible reduction** until then | WORKTREE-HOST |

Not decisions here but needed later: GitHub/GitLab/Linear/Jira links and Smart sources (M9, infra), agent start after setup (`wait-for-setup`, M5), project host setups (M7).

## 14. Risks

| Risk | Mitigation |
|---|---|
| Moving handlers out of the global host lock introduces races (SQLite connection shared, session lookups) | Store has its own lock; handlers never touch `SessionManager` internals except through its locked API; HOSTCORE stress test runs jobs + session I/O concurrently 3× in the full suite |
| `userContext` Git hangs on credential prompts or pager | `GIT_TERMINAL_PROMPT=0`, stdin `/dev/null`, `--no-pager`, `BatchMode=yes` when the user has no `GIT_SSH_COMMAND`, test with an unreachable URL |
| Hooks now run (pre-commit, post-checkout during `worktree add`) and can be slow or interactive | Writes have no timeout but are cancellable jobs; stdin is `/dev/null`; hook output streamed into job events |
| Rollback deletes user data | Rollback only removes paths and branches the job itself created (recorded in the job before each step); tests assert pre-existing branches/directories survive |
| Path canonicalization (`/tmp` vs `/private/tmp`, case-insensitive APFS, Unicode normalization of names) creates duplicate rows | Store `realpath`; compare with `URL.resolvingSymlinksInPath` + `standardized`; unique index on canonical path; tests with `/tmp` and NFD names |
| Journal growth from reads | Read class not journaled (test asserts row count) |
| YAML parser accepts what Orca rejects (duplicates, alias bombs) | Explicit tests from §7.2; decision M4-D2 |
| Big repos: `worktree add` 4.6 s for 39k files **[measured]**, minutes for very large monorepos | Background jobs with progress; sparse checkout; no timeouts on writes |
| Repos with LFS/submodules | Out of the M4 test matrix; submodules shown read-only by `git.status`; note in UI-WIRING as unverified |
| Two app windows (A4) or CLI and app editing the same worktree row | Host is the single writer; app re-reads after mutations; `worktree.set` is last-write-wins per field (Orca does the same per field) |
| ShellController edits collide with M3 WPs | Lane rules in §12.1 |
| Interim "open with default app" executes user files (e.g. `.command`, `.app`) | Use "reveal in Finder" for executables and bundles; open only documents (`NSWorkspace` + UTType check) |

## 15. Deferred out of M4 (recorded so it is not lost)

Agent launch with worktree (`--agent`, wait-for-setup) → M5; hosted reviews, issue/PR/MR links, Smart sources, fork sync, issue command execution → M9; project host setups, SSH/remote paths, downloads → M7; environment recipes → M8; editor, diff viewer, `file open/diff/open-changed` → M4-EDITOR/M4-DIFF; AI commit/PR text → M5; hibernation/sleep → M5; workspace board statuses UI beyond storing `workspace_status` → M10.

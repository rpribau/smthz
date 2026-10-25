# M3 plan: native shell (tabs, tab groups, splits, windows, persistent terminals)

Written 2026-10-24 by a planning worker (task `task_012e78d089f8`). This plan has not been implemented. Status labels used below:

- **[verified]**: read directly from `reference/orca-1.4.238` or from the current smthz sources while writing this plan.
- **[inferred]**: my conclusion from the sources, not proven by running Orca or smthz.
- **[decision]**: a choice that needs the user. Choices that reduce functionality are marked **[reduction?]**.

Inputs: `AGENTS.md`, `docs/ROADMAP.md`, `docs/DESIGN.md`, `docs/PARITY.md`, `docs/TERMINAL-ENGINE.md`, `docs/TERMINAL-BEHAVIOR.md` (written at the same time by another worker), `Sources/SmthzApp/*`, `Sources/SmthzCore/*`, `Sources/smthzd/main.swift`, `scripts/package-app.sh`, and the Orca files cited inline.

Out of scope here: the `clear`/`TERM` terminal bug described in `docs/TERMINAL-BEHAVIOR.md`, which a separate worker fixes. Emulator behaviour (selection, Find, IME, alternate screen, true colour) is also owned by TERMINAL-BEHAVIOR.md. M3 only adds the seams it needs in `TerminalSessionView.swift` (see WP-A2).

---

## 1. Scope

### 1.1 Roadmap definition [verified]
`docs/ROADMAP.md` M3: *"Native shell, persistent terminals, tabs, groups, splits and windows"*. Acceptance: *"Real processes survive UI detach; restore does not duplicate work."* PARITY row 1 (*Shell, onboarding, menus, settings, navigation, windows, tab groups/splits*) names `src/main/window`, `src/main/menu`, `src/renderer/src/app-shell`, `src/shared/workspace-layout`.

AGENTS.md "M3 native shell" says the shell itself (NavigationSplitView, HostMonitor, session list, New Shell, host-not-running state, SwiftTerm rendering) already exists. The remaining M3 work is **tabs, splits, windows, persistence/restoration and host lifecycle**.

### 1.2 Current smthz state (start of M3) [verified]
- `SmthzApp.swift`: one `WindowGroup("Workspaces")` and `AppModel` (destination and columns), with no persistence.
- `ShellView.swift`: sidebar destinations Needs You / Workspaces / Tasks / Automations / Activity / Library. Workspaces shows an `HSplitView` with a flat host-session list and one `TerminalPane`. New Shell is Cmd-Shift-N.
- `WorkspaceModel.swift`: `HostMonitor` polling (1 s), `newShell()` → `session.create /bin/zsh -l` in `$HOME`, default socket `~/Library/Application Support/smthz/smthzd.sock`. The comment says "No host is started implicitly".
- `TerminalSessionView.swift`: one SwiftTerm `TerminalView` per session. It polls `session.read` from cursor 0 (25 ms), sends input through an ordered command queue, and resizes. `.id(sessionID)` remounts it on switch.
- Host: `session.create/write/resize/read/close/list` are journaled and idempotent by (request id + method + params hash). `HostClient.createSession` mints its own request id, so a caller cannot retry idempotently. `SessionInfo` = id, pid, start time, running. It has no cwd, executable or title.
- `smthzd/main.swift` does **not** pass `scrollbackDirectory`, so on-disk scrollback is off in the real host. `SessionManager.readScrollback(id:directory:…)` exists for offline replay.
- Sessions die with the host. Graceful stop kills the process groups. Recovery across a host restart is an M2 remainder and **not M3**.
- No single-instance lock in `smthzd`. On stop, the server unlinks the socket path.

### 1.3 Orca behaviours M3 must match
Each item cites the Orca source it comes from.

**Layout model (two levels of splitting)** [verified]
- A workspace (Orca: worktree or folder, keyed by `worktreeId`/`WorkspaceKey`) owns *tabs*, *tab groups* and a *group layout tree*. Each group has its own tab strip and `tabOrder`. Source: `src/shared/tab-types.ts` (`TabGroupLayoutNode`, `TabGroup` with `activeTabId`, `tabOrder`, `recentTabIds`) and `src/shared/workspace-layout/workspace-layout-model.ts` (`WorkspaceLayout{tabs, groups, groupLayout, leaves, closedTerminalTabs}`).
- Inside one terminal tab there is a second binary tree of *panes* (leaves). Source: `src/shared/terminal-tab-types.ts` `TerminalPaneLayoutNode` and `TerminalLayoutSnapshot{root, activeLeafId, expandedLeafId, titlesByLeafId, lastGridsByLeafId, …}`.
- Both trees are binary `leaf | split{direction, first, second, ratio?}`. A missing ratio means 0.5. Source: `tab-types.ts`, `terminal-tab-types.ts`.
- **Naming trap:** pane trees call side-by-side `vertical` (`terminal-pane-tree.ts` `insertLeafBeside`: left/right → `'vertical'`), while group trees call side-by-side `horizontal` (`tab-group-layout-tree.ts` `insertSplitGroup`: left/right → `'horizontal'`). smthz uses one unambiguous axis enum (WP-C1).
- Invariants: *"A group never stays empty: an empty one is closed"* (`workspace-layout-model.ts`). Pane data is keyed by a leaf id that is unique in the workspace (`LayoutLeaf`).
- Close a group → its sibling subtree takes its place, and focus moves to the sibling's first leaf (`tab-group-layout-tree.ts` `removeGroupLayoutLeaf`, `findSiblingGroupId`, `collapseGroupLayout`).
- Equalize: panes on the same axis get equal shares (three side by side → thirds). A ratio within 0.005 of 0.5 is stored as none, otherwise rounded to 1/1000 (`terminal-pane-tree.ts` `equalizeLayout`, `SPLIT_RATIO_TOLERANCE`).
- Split ratios are persisted model state, not transient UI (`renderer/src/store/slices/tabs/tabs-split-ratio-actions.ts`).
- Layout changes are pure commands → `Applied` result plus *effects* `{stopPtyIds, startPaneKeys}`, or a typed refusal (`workspace_not_found`, `tab_not_found`, `pane_not_found`, `group_not_found`, `last_pane`, `tab_closed`, …). Source: `workspace-layout-command-types.ts` (`LayoutCommand`, `LayoutEffects`, `LayoutRefusalCode`). smthz copies this pattern (WP-C2/C3).

**Tabs** [verified]
- Closing the active tab activates the most recent other tab in the same group (per-group MRU), with the visual neighbour as fallback (`renderer/src/store/slices/tab-group-state.ts` `pickNextActiveTab`, `pickNeighbor`, `pushRecentTabId`).
- Context menu (`components/tab-bar/SortableTabContextMenu.tsx` and siblings): Close, Close Others, Close All Tabs To The Left/Right, Change Title, Tab Color (None, Gray, Red, Orange, Yellow, Green, Teal, Blue, Purple, Pink), Pin/Unpin Tab, Duplicate Tab, Move Tab to Split (Left/Right/Up/Down), Split terminal right/down, Close split pane, Copy Tab ID.
- Pinned tabs survive "Close Others" (`terminal-tab-types.ts` `isPinned`). A direct close of a pinned tab asks for confirmation (`renderer/src/store/pinned-tab-close-guard.ts`).
- Closing a tab whose shell has a running child process asks for confirmation, with a "don't ask again" option (`renderer/src/store/running-terminal-close-confirm.ts`).
- Reopen Closed Tab recreates **a fresh shell in the same startup directory**, with title, colour and position, and **never the old PTY, scrollback, or a relaunched agent**. Stack depth 10 per workspace (`renderer/src/store/slices/recently-closed-tabs.ts`, `MAX_RECENT_CLOSED_TERMINAL_TABS = 10`).
- Default titles are stable "Terminal N" (`defaultTitle`). A live OSC title can override the display but not the default (`terminal-tab-types.ts`).
- A new tab is placed after the active tab (`src/shared/session-tab-placement.ts`).

**Process exit → pane** [verified] (`workspace-layout/workspace-layout-process-exit.ts`)
- An unproven exit (attach found nothing, negative code) only **unbinds** the pane. It is never taken as proof of death. This matches ROADMAP: *"No treating missing observations as proof of process death"*.
- A local non-zero exit **keeps** the pane, showing the error.
- An exit after user input **retires** the pane.
- A sole pane that spawned fresh and exits keeps its message. A fresh split pane that printed nothing is kept. Otherwise the pane is retired.

**Keyboard shortcuts (darwin defaults)** [verified] from `src/shared/keybindings/definitions-core-{1..4}.ts`:

| Action id | Default (macOS) |
|---|---|
| `tab.newTerminal` | Cmd-T |
| `tab.close` / `terminal.closePane` | Cmd-W (closes the pane; the last pane closes the tab) |
| `tab.closeAll` | Cmd-Opt-W |
| `tab.rename` | Cmd-R |
| `tab.reopenClosed` | Cmd-Shift-T |
| `tab.nextAllTypes` / `tab.previousAllTypes` | Cmd-Shift-] / Cmd-Shift-[ |
| `tab.nextSameType` / `tab.previousSameType` | Cmd-Opt-] / Cmd-Opt-[ |
| `tab.previousRecent` | Ctrl-Tab (MRU) |
| `tab.nextTerminal` / `tab.previousTerminal` | Ctrl-PageDown / Ctrl-PageUp |
| `tab.selectByIndex` | Ctrl-1…9 |
| `terminal.splitRight` / `terminal.splitDown` | Cmd-D / Cmd-Shift-D |
| `terminal.focusNextPane` / `focusPreviousPane` | Cmd-] / Cmd-[ |
| `terminal.expandPane` | Cmd-Shift-Return |
| `terminal.equalizePaneSizes`, `setTitle`, `clearPaneTitle` | unbound (menu only) |
| `workspace.selectByIndex` | Cmd-1…9 |
| `worktree.navigateUp` / `Down` | Cmd-Shift-↑ / Cmd-Shift-↓ |
| `worktree.palette` | Cmd-J |
| `worktree.history.back` / `forward` | Cmd-Opt-← / Cmd-Opt-→ |
| `sidebar.left.toggle` | Cmd-B |
| `floatingTerminal.toggle` | Cmd-Opt-A |
| `zoom.in` / `out` / `reset` | Cmd-= / Cmd-- / Cmd-0 |
| `terminal.copySelection/paste/selectAll/search/clear` | Cmd-C/V/A/F/K (emulator side: TERMINAL-BEHAVIOR.md owns the behaviour; M3 only adds the menu items) |

Orca has a terminal-first/orca-first shortcut policy (`src/shared/keybindings/types.ts` `TerminalShortcutPolicy`, `src/shared/window-shortcut-policy.ts`) and a user keybindings file with per-platform overrides and diagnostics (`KeybindingFileSnapshot`).

**Windows** [verified/inferred]
- Orca has **one main window** (`src/main/window/createMainWindow.ts`). It also has a **floating terminal panel** with its own retained pane tree (`renderer/src/components/floating-terminal/*`, "the closed floating workspace retains its pane tree"), a dashboard pop-out (`main/window/dashboard-popout-window.ts`) and a workspace "space" window (`main/window/workspace-space-window.ts`). [verified]
- Main window bounds and maximized state are persisted with a debounce, and near-minimum bounds are never saved (`main/window/main-window-state-lifecycle.ts`). Saved bounds are rejected if they have no meaningful visible area on any attached display (`main/window/window-bounds-validation.ts`). [verified]
- Closing the window runs a confirmation step for running processes (`main/window/window-close-decision.ts`). [verified]
- Native multiple workspace windows are a smthz/DESIGN addition (*"tabs/splits/detached windows"* in DESIGN.md screen coverage), not an Orca behaviour. [inferred] Adding them is an extension, not a reduction.

**Persistence and restoration** [verified]
- `src/shared/workspace-session-state-types.ts` (`WorkspaceSessionState`) persists `activeWorktreeId`, tabs, `terminalLayoutsByTabId`, `tabGroups`, `tabGroupLayouts`, `activeGroupIdByWorktree`, `activeTabIdByWorktree`, `lastVisitedAtByWorktreeId` (Cmd-J ordering), `closedTerminalTabTombstonesByTabId`, `terminalPtyIncarnationsByPaneKey`, and `lastGridsByLeafId` (*"so main starts its terminal at that size"*).
- `terminal-layout-snapshot-schema.ts` decodes with *salvage*: bad sub-records are dropped, not the whole file.
- Orca keeps PTYs in a separate daemon that outlives the UI (`src/main/daemon/*`). On macOS it runs the daemon as a **launchd job with a fork fallback** (`main/daemon/macos-daemon-launchd.ts`), detects stale bundled daemons (`daemon-bundle-staleness.ts`) and throttles respawn crash-loops with a sliding window (`daemon-respawn-throttle.ts`).
- `main/daemon/AGENTS.md` endpoint rules: *"Never collapse 'can't tell' into 'dead'"* (only `ECONNREFUSED`/missing proves death; a timeout or `EPERM` proves nothing), *"No actor removes a name it did not create"*, *"Never remove the endpoint on shutdown."*

**Navigation** [verified] Workspaces are selected from the sidebar. There are Cmd-1…9 and up/down shortcuts, Back/Forward history, and the Cmd-J palette ordered by recency (`lastVisitedAtByWorktreeId`). Toggling the sidebar never closes processes (DESIGN.md: *"Resizing or hiding a view never closes its process"*).

### 1.4 What M3 includes and excludes
Included: everything in 1.3 for **terminal tabs** in **Home and plain-folder workspaces**, the floating terminal, multiple windows, persistence/restore, and the host lifecycle (bundle, auto-start, stop, version check).

Excluded (later milestones, unchanged scope):
- Editor, browser, agent and simulator tab kinds (M4–M6, M10). The model reserves `kind` so they slot in later.
- Git/worktree detection and nested worktrees (M4).
- Agent status, sleeping and resume (M5).
- Paired or remote hosts (M7).
- Process survival across a **host** restart (M2 remainder).
- Signing, notarization and the launchd agent (M11).

---

## 2. Architecture

### 2.1 Layering
```
SmthzCore (UI-free, tested with @Test)
  LayoutTree.swift        generic binary split tree + geometry
  ShellModel.swift        ids, Workspace/Tab/Group/Pane records, ShellState, invariants
  ShellTabCommands.swift  tab/group commands -> (state, effects) | refusal
  ShellPaneCommands.swift pane commands, session binding, exit verdict
  ShellStateStore.swift   versioned JSON persistence, salvage, atomic write
  Keybindings.swift       action ids, Orca darwin defaults, parser, override file, conflicts
  HostLauncher.swift      probe / spawn / stop smthzd, respawn throttle, version check
  HostClient/HostService  + idempotent create, session metadata, foreground, shutdown, replay
SmthzApp (SwiftUI + AppKit, verified by the coordinator's UI checks)
  ShellController.swift   @MainActor @Observable: owns ShellState, runs effects, persists
  HostController.swift    wraps HostLauncher + HostMonitor, Host menu
  LayoutSplitView.swift   AppKit NSView: lays out a LayoutNode, dividers, keeps child views
  TerminalPaneHost.swift  PaneID -> TerminalSessionController cache, pause/resume
  TabStripView.swift      per-group tab strip (AppKit or SwiftUI), drag and context menu
  WorkspaceWindow.swift   window scene, sidebar of workspaces, toolbar
  ShellCommands.swift     SwiftUI Commands / menus bound to Keybindings
  FloatingTerminalPanel.swift  NSPanel with its own workspace layout
```
Rule: **every decision about structure lives in SmthzCore and has tests.** The app only translates gestures into `ShellCommand`s and effects into host RPCs. This follows Orca, whose layout commands are pure functions in `src/shared/workspace-layout/*`. [verified]

### 2.2 Core types (WP-C1/C2; exact signatures in section 3)
- `LayoutNode<Leaf>`: `.leaf(Leaf)` | `.split(axis: SplitAxis, ratio: Double, first:, second:)`. `SplitAxis.horizontal` means the children sit **side by side** (left | right). `.vertical` means stacked (top / bottom). This removes Orca's naming inversion.
- IDs: `WorkspaceKey`, `WindowID`, `GroupID`, `TabID`, `PaneID`. Each is a `RawRepresentable` String wrapper. The four UUID-based ones use lowercase UUIDs. `WorkspaceKey` is `home`, `folder:<abs path>` or `floating`.
- `ShellState { version, workspaces: [WorkspaceKey: WorkspaceLayout], windows: [WindowState], workspaceOrder: [WorkspaceKey], lastVisited: [WorkspaceKey: Date] }`.
- `WorkspaceLayout { key, displayName, rootPath, tabs: [TabID: TerminalTabRecord], groups: [GroupID: TabGroup], groupLayout: LayoutNode<GroupID>?, activeGroup, panes: [PaneID: PaneRecord], recentlyClosed: [ClosedTabSnapshot] (≤10), nextDefaultTitleNumber }`.
- `TerminalTabRecord { id, kind = .terminal, createdAt, defaultTitle, customTitle?, color?, isPinned, panes: LayoutNode<PaneID>, activePane, expandedPane?, startupCwd? }`.
- `PaneRecord { id, title?, lastGrid?, startupCwd?, binding: SessionBinding?, pendingCreateRequestID?, state: PaneState }` with `PaneState = .unstarted | .starting | .live | .exited(code:signal:) | .ended(reason:)`.
- `SessionBinding { hostIncarnation: ProcessIdentity /*smthzd pid + start*/, sessionID: String, process: ProcessIdentity /*child pid + start, from SessionInfo*/ }`. **PID alone never proves ownership** (AGENTS.md), so a binding is valid only while `hostIncarnation` equals the live `host.identity`.
- `WindowState { id, workspace: WorkspaceKey, frame: CGRectCodable?, sidebarVisible, sidebarWidth, destination }`.

### 2.3 How terminals map to host sessions
- **One pane ↔ at most one host session.** A host session with no pane is an *unattached session*: CLI-created ones, or a pane whose layout was lost. They are listed in the sidebar ("Unattached sessions") with **Open in New Tab**, which adopts them. Orca has the same idea: `createTerminalTab.adopt` (`LiveTerminalAdoption`). [verified]
- Starting a pane (effect `startPanes`): the controller stores a fresh `pendingCreateRequestID` in the pane record and **persists it before** the RPC. It then calls `session.create(requestID:, executable: login shell, cwd: startupCwd, rows/cols: lastGrid ?? measured grid)` and binds the result. If the app crashes between the RPC and the bind, the relaunch re-sends the same request id, and the host journal replays the same session id. **No second shell is spawned.** This needs `HostClient.createSession(requestID:)` (WP-H1).
- Initial size: create with the pane's measured grid (or `lastGrid` on restore) instead of 80x24. TERMINAL-ENGINE.md lists the create-at-80x24-then-resize race. TERMINAL-BEHAVIOR.md P3 is the replay-size issue, owned there.
- Stopping (effect `stopSessions`): `session.close(id)` only after the user closed the tab or pane (with confirmation if a child is running, WP-A6). Hiding, resizing, closing a window, quitting the app or toggling the sidebar never stops a session (DESIGN.md).
- Exit: the terminal controller reports `HostReadResult.exit` → `ShellCommand.processExited(pane, exit, facts)`. The verdict follows Orca's rules (1.3). `unknownSession` from a host whose identity differs from the binding → `.ended(.hostRestarted)` (an unbind, **not** retire). A transport error → keep the binding and retry. Neither counts as proof of death.

### 2.4 AppKit/SwiftUI layer
- Scenes: `WindowGroup(id: "workspace", for: WindowID.self)` per workspace window, plus `Settings` later. Restoration is ours (ShellState.windows). SwiftUI's automatic scene restoration is disabled on that scene (`.restorationBehavior(.disabled)`), so relaunch does not create duplicates. [inferred: API availability and behaviour on macOS 26 must be checked by the WP-A4 author with Context7/Apple docs.]
- Window content: `NavigationSplitView` (sidebar: the destinations that already exist + the workspace list + unattached sessions) → detail: `WorkspaceView` = `LayoutSplitView<GroupID>` → per group `TabStripView` + `LayoutSplitView<PaneID>` of the active tab → `TerminalPaneHost` views.
- `LayoutSplitView` is a custom `NSView`, not nested `NSSplitView`s. Child frames come from the core's tested `LayoutNode.frames(in:divider:)`. Divider drags call `setRatio(path:)`. Child `NSView`s are cached by leaf id, so a split, move or close **never recreates a terminal view** and never replays its log. Orca's large remount-recovery machinery (`terminal-tab-types.ts` `TerminalTabRecoveryLedger`) shows how costly remounts are. [inferred]
- Hidden tabs: their controllers stay alive but **pause polling**. On show, they resume from the saved cursor. If the host reports `truncated`, the controller resets the emulator and replays (DESIGN.md: *"pause drawing of inactive views without stopping work"*).
- Liquid Glass stays on the system toolbar, sidebar and controls. Tab strips and terminals use stable, opaque semantic surfaces, with no glass per group (DESIGN.md: *"Avoid repeated blurred layers"*). [decision D10]
- Focus: `activePane` and `activeGroup` in the model are the truth. The controller makes the corresponding `TerminalView` first responder after every command that changes them. Keyboard focus survives reconnects and layout changes (DESIGN.md accessibility).
- Accessibility identifiers (used by the coordinator's System Events checks): `ws-sidebar`, `group:<GroupID>`, `tabstrip:<GroupID>`, `tab:<TabID>`, `pane:<PaneID>`, `divider:<path>`, `host-status`. Every tab button has a label ("Terminal 2, pinned, running") and every split action has a menu equivalent.

### 2.5 Persistence
- File: `~/Library/Application Support/smthz/shell-state.json`. Mode 0600 inside the existing 0700 directory. The app overrides the directory with the launch argument `-SmthzStateDirectory <path>` (UserDefaults argument domain). The socket/journal default moves with it, so verification never touches real state.
- Format: `{"version":1, …}` written with `JSONEncoder` (sorted keys). The write is atomic: temp file in the same directory, `fsync`, then `rename`. Saves are debounced 300 ms after a mutating command. `applicationWillTerminate` flushes synchronously.
- Load: version > known → refuse, rename the file to `shell-state.json.future-<ts>` and start empty (an older build never clobbers newer state). Corrupt JSON → rename to `.corrupt-<ts>` and start empty. Valid JSON with bad sub-records → **salvage** (drop the bad workspace/tab/pane and record it in a `LoadReport`), as Orca's zod salvage does. After decoding, `ShellState.repaired()` enforces the invariants (no empty groups, no dangling ids, active ids valid).
- Window frames: saved as part of `WindowState`. They are not saved during termination teardown, and near-minimum frames are never saved. On restore, the frame is rejected if it has less than 100x50 pt visible on any `NSScreen.visibleFrame`, which mirrors Orca's `window-bounds-validation.ts`. That check is a pure function in core (`FrameValidation.isUsable(frame:screens:)`).

### 2.6 Restoration rules ("restore does not duplicate work")

| Situation | Behaviour |
|---|---|
| App relaunch, same host incarnation | For each bound pane: `session.list` contains the id → reattach (no `session.create`). The emulator replays from cursor 0, or from the disk scrollback when the in-memory window was truncated. Host session count before and after relaunch is equal. |
| App relaunch, pane had `pendingCreateRequestID` and no binding | Re-send `session.create` with the same request id. Same host → same session id, no new process. Host changed → host returns an id that `list` does not contain → treat as below. |
| App relaunch or live, **host incarnation changed** (host restarted) | Binding becomes `.ended(.hostRestarted)`. Show the saved scrollback dimmed (from `session.replay`, WP-H2), then a notice line. For a **plain login shell** in a *visible* pane, start a fresh shell in `startupCwd` (Orca cold-restore semantics). Hidden panes start on first show. **A pane that ran an explicit command is never re-run.** [decision D2] |
| Host not running at app launch | `HostLauncher.ensureRunning()` starts the bundled `smthzd` (2.7), then applies the rule above. |
| Window closed (not quit) | Its workspace and sessions stay. The workspace stays in every window's sidebar. Reopening shows the same tabs attached to the same sessions. |
| Quit app | Host and sessions keep running (Orca daemon parity) [decision D5]. |
| Tab closed by the user | Sessions closed (after confirmation). A snapshot goes on `recentlyClosed`. Reopen = fresh shell in the same cwd, same title/colour/position. |

### 2.7 Host lifecycle: bundle, auto-start, stop
- Bundle: `scripts/package-app.sh` builds the `smthzd` product as well and copies it to `smthz.app/Contents/MacOS/smthzd` before `codesign --force --deep --sign -`. The app finds it with `Bundle.main.url(forAuxiliaryExecutable: "smthzd")`. When the app runs unbundled (`swift run SmthzApp`), it falls back to the sibling `smthzd` next to the app executable.
- Probe: `HostClient(socketPath:)` + `ping`. Mapping: `hostNotRunning` (ENOENT/ECONNREFUSED) → may spawn. A timeout, `EPERM` or authentication error → **do not spawn** and show an error state (Orca daemon AGENTS.md: *"can't tell" is not "dead"*).
- Spawn: `posix_spawn` with `POSIX_SPAWN_SETSID`, stdin `/dev/null`, stdout/stderr appended to `~/Library/Logs/smthz/smthzd.log` (0600), all other fds closed (`POSIX_SPAWN_CLOEXEC_DEFAULT`). The host is in its own session, so it outlives the app, including a force quit. The launcher then polls `ping` until ready (5 s timeout). Environment: the app's environment plus `SMTHZ_LAUNCHED_BY=app`. Choosing the shell environment is the job of the TERM bug fix (TERMINAL-BEHAVIOR.md), and M3 does not change it.
- Single instance: `smthzd` takes `flock(LOCK_EX|LOCK_NB)` on `<state dir>/smthzd.lock` **before** opening the journal or binding, and exits with code 3 ("already running") if the lock is held. With the lock held for the process's lifetime, a starting host can never replace a socket a live or stopping host still owns. This avoids the race in Orca's `main/daemon/AGENTS.md`, where a stopping host's unlink deletes a successor's socket. The existing unlink-on-stop then becomes safe: no successor can bind before the lock is released at exit.
- Crash-loop throttle: at most 3 spawn attempts in 60 s (sliding window, Orca `daemon-respawn-throttle.ts`). After that, show "Host keeps failing to start. View log / Retry".
- Version: after connecting, compare `version` with `ApplicationIdentity.version` and the RPC protocol version. If they differ, show "Host <v> differs from app <v>. Restart host (N sessions will end)". **Never restart a host with live sessions automatically** [decision D9].
- Stop: Host menu → "Stop Host…" (confirmation lists running sessions) → `host.shutdown` RPC (authenticated, WP-H2) → wait for the socket to stop answering. Fallback when the RPC fails: SIGTERM to the pid **only if** `proc_pidinfo` start time equals the `host.identity` the app recorded. Never by PID alone. "Restart Host" = stop + ensureRunning.

---

## 3. Work packages

Rules for every WP (from AGENTS.md):
- Build and test with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` and the WP's own `--scratch-path .build-<wp>`.
- Every test has `@Test`. The coordinator compares the test count; the baseline is **131**.
- Swift 6 strict concurrency: no `@unchecked Sendable` in new code unless justified in a comment. No `nonisolated(unsafe)`.
- **`Package.swift` must not change in any WP.** All new files go into existing targets.
- No new dependencies, no Node.
- Create new files or rewrite whole files. Do not edit with line-level sed/patch.
- Only the listed files may change. The coordinator diffs against a snapshot.
- Tests use real processes, sockets and files in temp dirs, with socket paths under `/tmp/smthz-<short>` (<104 bytes).

Tracks run in parallel because their file sets are disjoint: **C** (core layout), **H** (host), **K** (keybindings), then **A** (app, mostly sequential because it shares `SmthzApp/*`).

### WP-C1: LayoutTree (generic split tree + geometry)
- Goal: a pure, tested binary layout tree used for both pane splits and group splits.
- New files: `Sources/SmthzCore/LayoutTree.swift`, `Tests/SmthzCoreTests/LayoutTreeTests.swift`. No other files.
- API:
```swift
public enum SplitAxis: String, Codable, Sendable { case horizontal /* side by side */, vertical /* stacked */ }
public enum PaneSide: String, Codable, Sendable, CaseIterable { case left, right, top, bottom }
public enum SplitBranch: String, Codable, Sendable { case first, second }
public indirect enum LayoutNode<Leaf: Hashable & Codable & Sendable>: Equatable, Sendable, Codable {
    case leaf(Leaf)
    case split(axis: SplitAxis, ratio: Double, first: LayoutNode, second: LayoutNode)
}
public extension LayoutNode {
    var leaves: [Leaf] { get }                       // visual order, first before second
    func contains(_ leaf: Leaf) -> Bool
    func inserting(_ new: Leaf, beside target: Leaf, side: PaneSide, ratio: Double = 0.5) -> LayoutNode?   // nil: target missing or new present
    func removing(_ leaf: Leaf) -> LayoutNode?       // sibling takes parent's place; nil if it was the only leaf
    func sibling(of leaf: Leaf) -> Leaf?             // first leaf of the sibling subtree (Orca findSiblingGroupId)
    func moving(_ leaf: Leaf, beside target: Leaf, side: PaneSide) -> LayoutNode?
    func settingRatio(_ ratio: Double, at path: [SplitBranch]) -> LayoutNode   // clamps to 0.05...0.95
    func equalized() -> LayoutNode                   // Orca equalizeLayout weights; 1/1000 rounding
    func leaf(after leaf: Leaf) -> Leaf?             // cyclic, for focusNextPane
    func leaf(before leaf: Leaf) -> Leaf?
    func frames(in rect: CGRect, divider: CGFloat) -> [Leaf: CGRect]
    func dividers(in rect: CGRect, divider: CGFloat) -> [(path: [SplitBranch], axis: SplitAxis, frame: CGRect)]
    func ratio(forDividerAt path: [SplitBranch], dragLocation: CGPoint, in rect: CGRect,
               divider: CGFloat, minimum: CGSize) -> Double   // keeps both sides >= minimum
}
```
- Codable JSON shape: `{"type":"leaf","id":…}` / `{"type":"split","axis":…,"ratio":…,"first":…,"second":…}`. The ratio is omitted when |r−0.5| ≤ 0.005. Decoding rejects duplicate leaves and depth > 64, and clamps a ratio outside (0,1) to 0.5.
- Acceptance tests (≥ 14 `@Test`):
  - insert on all four sides gives the expected axis and order;
  - remove collapses to the sibling, and removing the only leaf gives nil;
  - sibling selection matches Orca's examples;
  - equalize three side by side → ratios 0.333/0.5;
  - frames tile the rect exactly (sum of areas + dividers = rect, no overlap) for a random tree of 20 leaves;
  - minimum-size clamp;
  - next/previous cycle;
  - JSON round trip, and rejection of duplicate leaves;
  - a property test with a seeded SplitMix64 generator: 500 random insert/remove/move operations keep `leaves` unique, and `frames` count equals `leaves` count.
- Dependencies: none. Can run in parallel with H1, K1.

### WP-C2: ShellModel + tab/group commands
- Goal: the workspace/tab/group model, invariants, and the tab/group half of the command reducer.
- New files: `Sources/SmthzCore/ShellModel.swift`, `Sources/SmthzCore/ShellTabCommands.swift`, `Tests/SmthzCoreTests/ShellTabCommandTests.swift`.
- API (types as in 2.2, plus):
```swift
public enum TabColor: String, Codable, Sendable, CaseIterable { case gray, red, orange, yellow, green, teal, blue, purple, pink }
public struct ShellEffects: Equatable, Sendable { public var startPanes: [PaneID]; public var stopSessions: [String] }
public enum ShellRefusal: Error, Equatable, Sendable {
    case workspaceNotFound, tabNotFound, groupNotFound, paneNotFound, lastPane, pinnedTab, invalid(String)
}
public enum ShellCommand: Equatable, Sendable {
    case openWorkspace(WorkspaceKey, displayName: String, rootPath: String?)
    case closeWorkspace(WorkspaceKey)                  // stops all its sessions (effects)
    case createTab(WorkspaceKey, group: GroupID?, cwd: String?, title: String?)   // after the active tab
    case closeTab(TabID, force: Bool)                  // pinned & !force -> .pinnedTab
    case closeOtherTabs(TabID), closeTabsToRight(TabID), closeTabsToLeft(TabID), closeAllTabs(WorkspaceKey)
    case activateTab(TabID), selectTab(WorkspaceKey, index: Int)
    case nextTab(WorkspaceKey), previousTab(WorkspaceKey), previousRecentTab(WorkspaceKey)
    case renameTab(TabID, String?), setTabColor(TabID, TabColor?), setPinned(TabID, Bool)
    case duplicateTab(TabID)                           // fresh shell in same cwd
    case moveTab(TabID, toGroup: GroupID, index: Int)
    case moveTabToSplit(TabID, side: PaneSide)         // new group beside the tab's group
    case setGroupRatio(WorkspaceKey, path: [SplitBranch], ratio: Double)
    case activateGroup(GroupID)
    case reopenClosedTab(WorkspaceKey)
}
public struct ShellApplied: Equatable, Sendable { public let state: ShellState; public let effects: ShellEffects }
public extension ShellState {
    static var empty: ShellState { get }               // contains .home workspace, no tabs
    func applying(_ command: ShellCommand, now: Date = .now,
                  ids: inout some ShellIDSource) -> Result<ShellApplied, ShellRefusal>
    func violations() -> [String]                      // invariant check, empty when valid
    func repaired() -> ShellState
}
public protocol ShellIDSource { mutating func next() -> String }   // tests inject deterministic ids
```
- Invariants enforced by `violations()`:
  - every tab is in exactly one group's `tabOrder`;
  - no empty group, unless it is the workspace's only group and the workspace has no tabs;
  - `groupLayout` leaves equal the group set;
  - `activeGroup`/`activeTab`/`activePane` refer to existing objects;
  - `panes` keys equal the union of the tabs' pane leaves;
  - `recentlyClosed.count ≤ 10`;
  - MRU lists contain only ids that are present.
- Acceptance tests (≥ 16):
  - close the active tab → MRU target, then the neighbour fallback (Orca `pickNextActiveTab` cases);
  - Close Others keeps pinned tabs;
  - closing a pinned tab without force is refused;
  - closing the last tab of a group collapses the group and the sibling becomes active;
  - `moveTabToSplit` on each side;
  - `moveTab` across groups, including an emptied source group;
  - `reopenClosedTab` restores title/colour/position with a new pane and no binding, and emits `startPanes` with no reuse of the session id;
  - `createTab` places after the active tab;
  - default titles "Terminal 1, 2, …" stay stable after renames;
  - `closeTab` emits `stopSessions` for bound panes only;
  - `previousRecentTab` follows the MRU;
  - a seeded property test: 1,000 random commands, `violations()` stays empty after each step.
- Depends on: C1.

### WP-C3: pane commands, session binding, exit verdict
- Goal: splits inside a tab, focus, expand, binding to host sessions, and the process-exit rules.
- New files: `Sources/SmthzCore/ShellPaneCommands.swift`, `Tests/SmthzCoreTests/ShellPaneCommandTests.swift`. This WP may **append cases** to `ShellCommand` in `ShellModel.swift` only if C2 did not reserve them. Preferred: C2 declares them all and returns `.invalid("not implemented")`, and C3 only adds `ShellPaneCommands.swift` plus the dispatch in `ShellTabCommands.swift`'s `applying` switch. List both files as allowed.
- Commands:
  - `splitPane(TabID, pane: PaneID, side: PaneSide)`: the new pane inherits `startupCwd` and emits `startPanes`.
  - `closePane(TabID, PaneID)`: the last pane → `.lastPane`. The controller maps Cmd-W on the last pane to `closeTab`.
  - `focusPane`, `focusNextPane`, `focusPreviousPane`, `toggleExpandPane`, `equalizePanes`.
  - `setPaneRatio(TabID, path:, ratio:)`, `renamePane(PaneID, String?)`, `setPaneGrid(PaneID, cols:, rows:)`.
  - `paneStarting(PaneID, requestID:)`, `bindSession(PaneID, SessionBinding)`.
  - `processExited(PaneID, ProcessExitFacts)` with `ProcessExitFacts { code: Int32?, signal: Int32?, spawnedFresh, restored, inputWritten, outputReceived, tabHadPaneAtConnect }`.
  - `hostIncarnationChanged(ProcessIdentity)`: unbinds every mismatched binding → `.ended(.hostRestarted)`.
  - `adoptSession(WorkspaceKey, SessionInfo, host: ProcessIdentity)`: new tab bound to an existing session; it emits **no** `startPanes`.
  - `restartPane(PaneID)`: fresh shell, same cwd.
- Exit verdict: port `exitVerdict` from `workspace-layout-process-exit.ts` as `ExitVerdict { keep, unbind, retire }` (pure function with a table test). A missing observation is never `retire`.
- Acceptance tests (≥ 14):
  - every row of the Orca verdict table;
  - `hostIncarnationChanged` touches only mismatched bindings;
  - `adoptSession` creates no start effect;
  - retiring the last pane closes the tab and records `recentlyClosed`;
  - expand + close of the expanded pane clears `expandedPane`;
  - focus next/previous wraps;
  - split keeps `activePane` on the new pane;
  - the seeded property test (C2's generator extended with pane commands) keeps `violations()` empty.
- Depends on: C2. Can run in parallel with C4 (disjoint files once C2 has fixed the types).

### WP-C4: ShellStateStore (persistence)
- Goal: versioned load/save with salvage, atomic write, frame validation.
- New files: `Sources/SmthzCore/ShellStateStore.swift`, `Tests/SmthzCoreTests/ShellStateStoreTests.swift`.
- API:
```swift
public struct ShellLoadReport: Equatable, Sendable { public var salvaged: [String]; public var backupPath: String? }
public enum ShellStateStore {
    public static let currentVersion = 1
    public static func load(from url: URL) -> (ShellState, ShellLoadReport)   // never throws: falls back to .empty
    public static func save(_ state: ShellState, to url: URL) throws          // atomic, 0600, fsync
}
public enum FrameValidation { public static func isUsable(_ frame: CGRect, screens: [CGRect], minimumVisible: CGSize = .init(width: 100, height: 50)) -> Bool }
```
- Acceptance tests (≥ 10):
  - round trip of a state produced by 200 random commands;
  - the file mode is 0600;
  - a crash-simulation partial temp file leaves the old file intact;
  - corrupt JSON → `.corrupt-*` backup and empty state;
  - a future version → `.future-*` backup;
  - one bad tab inside a valid workspace → salvaged, with the rest kept and listed in the report;
  - dangling `activeTab` repaired;
  - `FrameValidation` on/off-screen cases, including a frame on a disconnected second display.
- Depends on: C2 types.

### WP-K1: Keybinding registry
- Goal: the action ids and Orca darwin defaults (table 1.3) as data, a parser, an optional override file, and conflict diagnostics.
- New files: `Sources/SmthzCore/Keybindings.swift`, `Tests/SmthzCoreTests/KeybindingsTests.swift`.
- API:
  - `KeyChord { key: String; command, option, control, shift: Bool }`, parsed from Orca strings such as `"Mod+Shift+BracketRight"`, `"Ctrl+PageDown"`, `"Mod+Alt+ArrowLeft"`;
  - `KeybindingAction: String` (the Orca ids above, M3 subset);
  - `KeybindingRegistry.defaults`;
  - `KeybindingRegistry.loading(overridesJSON: Data) -> (KeybindingRegistry, [KeybindingDiagnostic])`;
  - `chords(for:) -> [KeyChord]` and `action(for: KeyChord) -> KeybindingAction?`.
  - Override file shape: Orca `KeybindingOverrides` (`{"tab.close":["Mod+W"]}`, an empty array unbinds).
  - Conflict diagnostics: two actions on one chord in the same scope (the deliberate pair `tab.close`/`terminal.closePane` excepted).
- Acceptance tests (≥ 8): parse/format round trip for every default; an override replaces; an empty list unbinds; an unknown action id → warning; a conflict → error diagnostic; the defaults table equals the M3 subset of Orca's darwin defaults (hard-coded expectation table copied from 1.3).
- Depends on: none. Parallel with C1/H1.
- [decision D8] Whether the override file is read in M3 (`~/Library/Application Support/smthz/keybindings.json`) or only in settings (M10).

### WP-H1: host RPC for the shell (idempotent create, metadata, foreground)
- Goal: what the app needs from the host to restore without duplicates and to confirm closes.
- Allowed files: `Sources/SmthzCore/HostClient.swift`, `Sources/SmthzCore/HostService.swift`, `Sources/SmthzCore/SessionManager.swift`, `Sources/SmthzCore/PTYSession.swift` (only for the foreground pgid accessor). New test file `Tests/SmthzCoreTests/HostShellRPCTests.swift`.
- Changes:
  1. `HostClient.createSession(requestID: String? = nil, executable:…, rows:, cols:)`: passes the id through to `call(requestID:)`. Existing callers compile unchanged.
  2. `SessionInfo` gains **optional** `executable: String?`, `arguments: [String]?`, `cwd: String?`, `createdAt: Double?` (seconds since 1970). The JSON stays backward compatible: old payloads decode.
  3. New RPC `session.foreground {id}` → `{pgid, pid, executable: String?, isShell: Bool}`, using `tcgetpgrp(master)` and `proc_pidpath`. `isShell` is true when the foreground pgid equals the session leader's pid. It is not journaled (read-only), like `session.list`.
- Acceptance tests (≥ 6):
  - the same request id twice → the same session id, and `ps` shows one child;
  - `list` returns `cwd`/`executable`;
  - `foreground` on an idle `/bin/zsh -f` → `isShell == true`;
  - after writing `sleep 30\n` → `isShell == false` and the executable ends with `/sleep`;
  - after Ctrl-C (0x03) → back to the shell;
  - an unknown id → `unknownSession`.
- Coordinator e2e: `smthz run` still works and `smthz sessions` shows unchanged output. The suite runs ×3.
- Depends on: none (parallel with C*, K1). **Conflict warning:** the TERM bug fix probably touches `HostService`/`SessionManager` too. Schedule H1 **after** that fix lands, or give that fix's file list to the coordinator first.

### WP-H2: host lifecycle support (shutdown, lock, scrollback, replay)
- Allowed files: `Sources/smthzd/main.swift`, `Sources/SmthzCore/HostService.swift`, `Sources/SmthzCore/HostClient.swift`. New test file `Tests/SmthzCoreTests/HostLifecycleTests.swift`.
- Changes:
  1. `smthzd`: `--state-dir <dir>` (default: Application Support/smthz). It derives socket, journal, `smthzd.lock` and `scrollback/` from it. Explicit `--socket`/`--journal` still override.
  2. `flock` single-instance lock before the journal opens. Exit code 3 with "smthzd already running" on stderr.
  3. Disk scrollback **on by default**: `SessionManager(scrollbackDirectory: <state>/scrollback, scrollbackLimit: 16 MiB)` [decision D11].
  4. RPC `host.shutdown` (authenticated like the others, journaled): replies `{ok:true}` and then performs the same graceful stop path as SIGTERM, on the main queue after the reply is flushed.
  5. RPC `session.replay {id, from, maxBytes}`: reads the disk scrollback of an id from this **or a previous** host incarnation (`SessionManager.readScrollback`). It returns `{data, next, eof}` or `unknownSession`. Validate the id as a lowercase UUID so it cannot traverse paths.
  6. `HostClient.shutdown()` and `HostClient.replay(id:from:maxBytes:)`.
- Acceptance tests (≥ 7):
  - a second `smthzd` with the same state dir exits 3 while the first serves, and the first's socket still answers;
  - `host.shutdown` → the process exits 0, no strays, the socket is gone;
  - after shutdown, a new host starts on the same dir;
  - `session.replay` returns the output of a session from a previous host process (start host A, run `echo marker`, stop A, start B, replay → contains `marker`);
  - an id with `../` → `badRequest`;
  - scrollback files are mode 0600.
- Coordinator e2e: the real binaries, two hosts racing (`smthzd & smthzd`), exactly one survives. `smthz ping` works.
- Depends on: H1 (same files: sequential).

### WP-H3: HostLauncher (UI-free)
- New files: `Sources/SmthzCore/HostLauncher.swift`, `Tests/SmthzCoreTests/HostLauncherTests.swift`.
- API:
```swift
public struct HostEndpoint: Sendable, Equatable {
    public let stateDirectory: URL; public var socketPath: String { get }; public var logPath: String { get }
    public static func standard(home: URL) -> HostEndpoint
}
public enum HostLaunchState: Equatable, Sendable {
    case running(identity: ProcessIdentity, version: String, compatible: Bool)
    case startedByUs(identity: ProcessIdentity)
    case unreachable(reason: String)          // timeout/EPERM/auth: not spawned
    case throttled(retryAfter: Duration)
    case failed(exitStatus: Int32?, logTail: String)
}
public actor HostLauncher {
    public init(endpoint: HostEndpoint, executable: URL, appVersion: String = ApplicationIdentity.version,
                throttle: (attempts: Int, window: Duration) = (3, .seconds(60)))
    public func ensureRunning(timeout: Duration = .seconds(5)) async -> HostLaunchState
    public func stop(expected: ProcessIdentity, timeout: Duration = .seconds(5)) async throws  // host.shutdown, then verified SIGTERM fallback
}
```
- Spawn as in 2.7 (`posix_spawn` + `POSIX_SPAWN_SETSID` + `POSIX_SPAWN_CLOEXEC_DEFAULT`, stdout/stderr to the log). Not `Foundation.Process`, because it would keep the child in the app's session/process group. [inferred]
- Tests (≥ 7) use the real `smthzd` built next to the test bundle. It is resolved from the test bundle's directory; use `#require` so a missing binary **fails** rather than skips. The coordinator runs `swift build` before `swift test`. Cases:
  - not running → `startedByUs` and ping works;
  - already running → `running` and no second process;
  - the host survives the launcher's owning task ending (the child's `getsid` differs from the test's);
  - a fake executable that exits 1 → `failed` with a log tail, and the 4th call within the window → `throttled`;
  - `stop(expected:)` with a wrong start time → refuses and does not signal;
  - `stop` with the right identity → exits, and the socket is gone;
  - an unreachable state (socket file present but owned by a non-listening dummy that accepts and never answers) → `unreachable`, nothing spawned.
- Depends on: H2.

### WP-A0: ShellController (app state owner) + state directory
- Goal: replace `WorkspaceModel` with a controller around `ShellState`. It applies commands, executes effects against the host and persists. The UI barely changes yet: one tab per workspace and the old single terminal pane, now backed by the model.
- Allowed files:
  - rewrite `Sources/SmthzApp/WorkspaceModel.swift` → delete it and create `Sources/SmthzApp/ShellController.swift`;
  - `Sources/SmthzApp/SmthzApp.swift`;
  - `Sources/SmthzApp/ShellView.swift`, minimal rewiring only.
- Behaviour:
  - `-SmthzStateDirectory` launch argument;
  - debounced save, plus a synchronous flush on terminate;
  - the effect executor runs `startPanes` (persist `pendingCreateRequestID` → `createSession(requestID:)` → `bindSession`) and `stopSessions` (`session.close`);
  - it reconciles with `HostMonitor` snapshots (`hostIncarnationChanged`, unattached-session list);
  - all RPC happens in an actor, never on the main actor;
  - New Shell becomes `createTab(.home)`.
- Acceptance (manual by coordinator, script in section 5):
  - fresh state dir → New Shell → quit → relaunch → the same session id is shown attached, and `smthz sessions` count is unchanged;
  - `shell-state.json` contains one tab with a binding.
  - Build and the 131+N tests still pass.
- Depends on: C3, C4, H1. (H3 is not needed yet: the coordinator starts `smthzd` manually.)

### WP-A1: bundle + auto-start + Host menu
- Allowed files: `scripts/package-app.sh`, new `Sources/SmthzApp/HostController.swift`, `Sources/SmthzApp/SmthzApp.swift` (menu only), `Sources/SmthzApp/ShellView.swift` (toolbar status item only).
- Behaviour:
  - the script builds `smthzd` and copies it into `Contents/MacOS/`;
  - on launch the app calls `HostLauncher.ensureRunning()` [decision D4];
  - Host menu: Status, Start Host, Stop Host…, Restart Host…, Show Host Log;
  - the toolbar status shows incompatible-version, throttled and unreachable states as text plus a symbol;
  - setting `autoStartHost` (default true) lives in UserDefaults.
- Acceptance:
  - `scripts/package-app.sh debug`, then `ls build/smthz.app/Contents/MacOS/smthzd`, then `codesign -v --deep build/smthz.app`;
  - with no host: `open build/smthz.app --args -SmthzStateDirectory /tmp/smthz-m3` → within 5 s `pgrep -f "smthzd.*smthz-m3"` = 1 and the toolbar reads "Local host connected";
  - quit the app → the host is still running (`pgrep` = 1) and `smthz sessions --socket /tmp/smthz-m3/smthzd.sock` still lists the sessions;
  - Stop Host… → no `smthzd`, no stray children.
- Depends on: A0, H3.

### WP-A2: pane splits in a tab (LayoutSplitView + TerminalPaneHost)
- Allowed files: new `Sources/SmthzApp/LayoutSplitView.swift`, new `Sources/SmthzApp/TerminalPaneHost.swift`, `Sources/SmthzApp/TerminalSessionView.swift` (seams only: `pause()`/`resume()`, a resume cursor, `onTitle`, `onCwd` (OSC 7 via `hostCurrentDirectoryUpdate`), `onFocus`, `onExit(facts)` callbacks, and an initial-grid parameter), `Sources/SmthzApp/ShellView.swift`.
- Behaviour:
  - Cmd-D / Cmd-Shift-D, Cmd-[ / Cmd-], Cmd-Shift-Return, Cmd-W (pane, last pane → tab), divider drag, double-click on a divider to equalize;
  - the focus ring marks the active pane;
  - the view for an existing pane is never recreated on layout change (the cache is keyed by PaneID);
  - OSC 7 cwd is stored as `startupCwd` for new splits.
- Acceptance:
  - split right ×2 + down ×1 → 4 panes, each a distinct host session (`smthz sessions` +3);
  - typing `echo A` in pane 1 is unchanged after splitting pane 2 (no replay flicker; screenshot before/after);
  - closing pane 2 → its session gone from `smthz sessions`, and the others are unchanged;
  - drag a divider, relaunch → same ratio (± 1 pt) and the same sessions;
  - `stty size` in each pane matches its visible grid.
- Depends on: A0 **and the TERM bug fix** (both edit `TerminalSessionView.swift`).

### WP-A3: tab strips and tab groups
- Allowed files: new `Sources/SmthzApp/TabStripView.swift`, new `Sources/SmthzApp/WorkspaceView.swift`, `Sources/SmthzApp/ShellView.swift`.
- Behaviour:
  - one strip per group, showing title, colour dot, pin, "running" indicator and close button;
  - drag to reorder; drag to another strip; drag onto the content edge → `moveTabToSplit`;
  - the context menu from 1.3, Duplicate and Copy Tab ID included;
  - rename inline (Cmd-R);
  - Cmd-T, Cmd-Shift-T, Cmd-Shift-[ ], Cmd-Opt-[ ], Ctrl-Tab, Ctrl-PageUp/Down, Ctrl-1…9, Cmd-Opt-W;
  - group splits render through `LayoutSplitView<GroupID>`, and an empty group closes.
- Every drag has a menu or keyboard alternative (DESIGN.md).
- Acceptance:
  - three tabs, Move Tab to Split ▸ Right → two strips, and the JSON has two groups and a horizontal split;
  - closing the active tab returns to the MRU tab (scripted: activate 1, 3, 2, close 2 → 3 active);
  - pin + Close Others keeps the pinned tab;
  - Reopen Closed Tab → fresh shell (new session id) in the same cwd (`pwd`) with the same title/colour;
  - VoiceOver reads the tab label (Accessibility Inspector or `osascript` AX description).
- Depends on: A2.

### WP-A4: workspaces, sidebar navigation, multiple windows
- Allowed files: new `Sources/SmthzApp/WorkspaceWindow.swift`, `Sources/SmthzApp/SmthzApp.swift`, `Sources/SmthzApp/ShellView.swift`.
- Behaviour:
  - sidebar lists Home + opened folders ("Open Folder…" with `NSOpenPanel` → `openWorkspace(folder:)`, default cwd = folder) and "Unattached sessions" (Open in New Tab → `adoptSession`);
  - Cmd-1…9, Cmd-Shift-↑/↓, Cmd-Opt-←/→ history, Cmd-J palette (recency order), Cmd-B sidebar;
  - Cmd-N New Window [decision D3];
  - a workspace is shown in at most one window: selecting one already open elsewhere focuses that window;
  - window frames and sidebar state are restored (frame validation);
  - closing a window keeps the sessions.
- Acceptance:
  - two windows (Home, `/tmp`), quit, relaunch → both windows reappear with the same frames and tabs, and the `smthz sessions` count is unchanged;
  - set the saved frame of window 2 off-screen in the JSON → it opens at the default position;
  - close window 2 → its sessions remain, and reopening via the sidebar shows them attached;
  - a CLI-created session (`smthz run -- /bin/zsh`) appears under Unattached, and Open in New Tab attaches without creating a session.
- Depends on: A3.

### WP-A5: menus and keybinding application
- Allowed files: new `Sources/SmthzApp/ShellCommands.swift`, `Sources/SmthzApp/SmthzApp.swift` (`.commands { ShellCommands(...) }` only).
- Behaviour:
  - every action from 1.3 appears in the File/Edit/View/Window menus with its key equivalent from `KeybindingRegistry` (overrides if D8 = yes) and is enabled or disabled from the model state;
  - Ctrl-Tab and Ctrl-1…9 are implemented with a local `NSEvent` monitor only while a shell window is key, because menu equivalents for Ctrl-Tab are unreliable [inferred];
  - terminal-reserved chords (plain Ctrl-letters, Option-as-Meta) are never claimed;
  - conflicts from `KeybindingRegistry` diagnostics are written to the log and shown once.
- Acceptance: a System Events script sends each chord and checks the JSON or screen effect (section 5). Ctrl-C still interrupts `sleep 100` in a pane, and Option-b still moves back a word in zsh.
- Depends on: A3, K1. (A4 and A5 both touch `SmthzApp.swift`: run them sequentially, A4 first.)

### WP-A6: close confirmations and process-exit UI
- Allowed files: new `Sources/SmthzApp/CloseConfirmation.swift`, `Sources/SmthzApp/ShellController.swift`, `Sources/SmthzApp/TabStripView.swift`.
- Behaviour:
  - closing a tab, pane, window-with-unpinned-work, workspace or the app with "Stop host on quit" queries `session.foreground`;
  - a non-shell foreground triggers a sheet "‘sleep’ is still running in Terminal 2. Close anyway?" with "Don't ask again", and duplicate requests are merged (Orca `running-terminal-close-confirm.ts`);
  - pinned close confirmation;
  - exit UI per the verdict: keep → dimmed `[Process exited: code]` + "Restart" button; ended(hostRestarted) → saved scrollback via `session.replay` + notice + auto fresh shell (D2).
- Acceptance:
  - `sleep 100` + Cmd-W → sheet; Cancel → the session is alive; Confirm → gone;
  - an idle shell + Cmd-W → no sheet;
  - `exit 3` → pane kept with the notice; `exit` after typing → pane retired;
  - Stop Host from the menu while the app is open → panes show "Host restarted" with old output dimmed; after Start Host, the visible panes have fresh shells and the hidden tabs start on activation; nothing is re-run (a pane started as `smthz`-adopted `sleep 1000` is not restarted).
- Depends on: A3 (A4/A5 optional), H2.

### WP-A7: floating terminal panel
- Allowed files: new `Sources/SmthzApp/FloatingTerminalPanel.swift`, `Sources/SmthzApp/ShellCommands.swift` (one menu item).
- Behaviour: Cmd-Opt-A toggles a non-activating `NSPanel` (floating level, all spaces) that shows the `floating` workspace's active tab with its own pane tree. Hiding the panel never stops its sessions, and its frame is persisted (Orca `floating-terminal-panel-*`).
- Acceptance: toggle → panel appears with a shell; run `sleep 500`; toggle off/on → same session; relaunch → the panel's last visibility and frame are restored.
- Depends on: A5.

### WP-A8: M3 hardening pass (no new features)
- Allowed files: whatever `Sources/SmthzApp/*` the coordinator lists from the open defects found in A0–A7. Also the cosmetic items already in AGENTS.md: the thousands separator in pids/ids, and the "Terminal" header mid-pane.
- Acceptance: the full verification matrix (section 5) passes in one session, with screenshots archived under `/tmp/smthz-m3-evidence/`.

### Dependency graph and parallel lanes
```
C1 ──> C2 ──┬─> C3 ──┐
            └─> C4 ──┤
K1 ──────────────────┤
[TERM bug fix] ─> H1 ─> H2 ─> H3
                     └───────┤
                             v
                    A0 (needs C3,C4,H1) ─> A1 (needs H3)
                    A0 ─> A2 (needs TERM fix) ─> A3 ─> A4 ─> A5 (needs K1) ─> A7
                                               └─> A6 (needs H2) ──────────────> A8
```
Lanes that may run at the same time (disjoint files, one `--scratch-path` each):
- {C1, K1, H1};
- {C2, H2};
- {C3, C4, H3};
- A1 with A2 is **not** allowed (both touch `ShellView.swift`);
- A6 may run beside A4 only if A4 does not touch `ShellController.swift`/`TabStripView.swift`.

The coordinator should still prefer one A-worker at a time.

Expected test count after the core and host WPs: 131 + C1 14 + C2 16 + C3 14 + C4 10 + K1 8 + H1 6 + H2 7 + H3 7 = **≥ 213**. The A WPs add no SwiftPM tests. Their verification is the UI script.

---

## 4. Risks and open decisions

### Decisions for the user
| ID | Decision | Recommendation | Functional impact |
|---|---|---|---|
| D1 | Who owns the layout: the app (`shell-state.json`) or the host? Orca 1.4.238 keeps the layout model in the runtime ("The one workspace tab layout model the runtime holds", `workspace-layout-model.ts`) so paired clients and the CLI converge. | App-side in M3, moving to the host with paired clients in M7. | **[reduction?]** Until M7 the CLI cannot list or modify tabs/panes, and two app instances do not share a layout. Orca's CLI can address terminals by tab. Needs acceptance or a host-owned layout in M3, which would add roughly 2 host WPs. |
| D2 | Cold restore after a host restart: start fresh shells automatically (Orca) or wait for a "Start shell" click. | Automatic for plain login shells in visible panes, lazy for hidden ones; never re-run commands. | None if automatic. Manual would be a small UX difference. |
| D3 | Multiple windows: one workspace per window (extension beyond Orca's single main window), Cmd-N = New Window. Not planned: dragging a tab out into its own window (not in Orca). | As stated. | Extension, no reduction. |
| D4 | Host launch: detached `posix_spawn` (M3) vs launchd agent (Orca on macOS uses launchd with fork fallback, `macos-daemon-launchd.ts`). | Spawn in M3; launchd via `SMAppService` with M11 signing. | **[reduction?]** Without launchd, a crashed host is restarted only when the app next probes it (the app polls every 1 s while open). Nothing restarts it while the app is closed. |
| D5 | Quit behaviour: keep the host and sessions running after quit. | Keep by default, with a "Stop host when quitting" option. | None. |
| D6 | M3 workspaces = Home + plain folders, without Git/worktree awareness (M4). | Yes. | None (M4 scope). |
| D7 | Shortcut deviations from Orca: Cmd-N New Window (Orca: none); the current Cmd-Shift-N New Shell is removed in favour of Cmd-T; Cmd-=/-/0 change the terminal font size (Orca zooms the whole web UI, which has no direct native equivalent). | As stated. | Zoom is a **native-equivalent** choice. It needs acceptance as such. |
| D8 | Read the user keybinding override file in M3 or wait for the settings UI (M10). | Read the file in M3 (cheap, K1); no editor UI until M10. | None if read. Deferring is a temporary gap. |
| D9 | Host version mismatch: never restart automatically while sessions are live. | Prompt. | None. |
| D10 | Liquid Glass only on the system toolbar/sidebar/controls; tab strips stay opaque. | Yes, per DESIGN.md. | None. |
| D11 | Disk scrollback default: 16 MiB per session, files kept for ended sessions for 7 days, total cap 1 GiB. The current code allows up to 64 MiB per session and never deletes. | As stated. A cleanup task is needed (could go in H2 if allowed). | Disk usage vs how much history can be replayed. |
| D12 | Process survival across a **host** restart stays out of M3 (M2 remainder). M3's acceptance only says "survive UI detach". | Confirm. | Host restart ends every shell (scrollback is kept). Orca's daemon also loses PTYs on daemon death and cold-restores. [inferred from `cold-restore-*` files] |

### Technical risks
- **Shared files with the TERM bug fix**: `TerminalSessionView.swift`, and probably `HostService`/`SessionManager`. Mitigation: H1 and A2 wait for that fix, and the coordinator snapshots before each.
- **SwiftUI window restoration duplicates**: SwiftUI may restore windows itself in addition to ours. A4 must verify `.restorationBehavior(.disabled)` (or `NSQuitAlwaysKeepsWindows`) on macOS 26 with Apple docs. [inferred]
- **Menu equivalents vs terminal input**: Cmd chords go to menus before the first responder, which is what we want. Ctrl-Tab/Ctrl-digit menu items may not fire, or may steal input from TUIs. A5 tests this, and the fallback is an `NSEvent` local monitor.
- **Polling cost with many panes**: every visible pane polls `session.read` every 25 ms over its own connection. 20 visible panes means 800 RPC/s when idle. Mitigation: pause hidden panes (A2). A host push/subscribe RPC is the proper fix (an M2 follow-up). No numbers until a baseline exists (AGENTS.md).
- **Replay size**: replay from cursor 0 is bounded by the 4 MiB in-memory window, and beyond that by disk scrollback. Replay at a different grid than the original output is TERMINAL-BEHAVIOR.md P3 and is not solved here.
- **Socket ownership**: without the H2 lock, "Restart Host" can race (a stopping host unlinks the new socket). H2 must land before A1 exposes Restart.
- **Hermes/Codex scope creep** on `Package.swift`: no WP needs it. Any change there means rejection.
- **Synthetic input limits** (TERMINAL-ENGINE.md): `keystroke " "` is dropped and `'` is garbled. UI scripts use `key code` for spaces and avoid quotes. Real keyboard checks remain for the user.

---

## 5. Verification matrix and definition of done

### 5.1 Coordinator UI harness (exact commands)
```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
S=/tmp/smthz-m3; rm -rf $S; mkdir -m 700 $S
scripts/package-app.sh debug
open build/smthz.app --args -SmthzStateDirectory $S
sleep 4; pgrep -fl smthzd                                   # 1 host for $S
B=.build-lunaapp/debug                                     # package-app.sh's default scratch path
$B/smthz sessions --socket $S/smthzd.sock                   # session inventory
python3 -m json.tool $S/shell-state.json | head -80          # model as persisted
osascript -e 'tell application "System Events" to keystroke "d" using command down'   # split right
osascript -e 'tell application "System Events" to tell process "smthz" to get value of attribute "AXIdentifier" of every UI element of window 1'
screencapture -x -o -l $(osascript -e 'tell application "smthz" to id of window 1') $S/shot.png   # window-only capture
osascript -e 'quit app "smthz"'; sleep 1; pgrep -fl smthzd   # host survives quit
```
(The window-id lookup may need `orca computer` or a `CGWindowList` one-liner if the app has no AppleScript dictionary. Fallback: `screencapture -x $S/full.png`.)

### 5.2 Matrix
| # | Behaviour | Unit tests | Host e2e (CLI) | UI check | WP |
|---|---|---|---|---|---|
| 1 | Split tree ops, geometry, equalize | LayoutTreeTests | – | screenshot of 4-pane split | C1, A2 |
| 2 | Tabs/groups commands + MRU + pin | ShellTabCommandTests | – | close/MRU script | C2, A3 |
| 3 | Pane commands, exit verdict, host-incarnation unbind | ShellPaneCommandTests | – | exit 3 / exit / host stop | C3, A6 |
| 4 | Persistence round trip, salvage, frame validation | ShellStateStoreTests | – | off-screen frame edit | C4, A4 |
| 5 | Keybinding defaults equal Orca darwin | KeybindingsTests | – | chord script | K1, A5 |
| 6 | Idempotent create, metadata, foreground | HostShellRPCTests | double create → 1 child | – | H1 |
| 7 | Single instance, shutdown, replay across host restart | HostLifecycleTests | `smthzd & smthzd` → one survives | – | H2 |
| 8 | Launcher spawn / throttle / verified stop | HostLauncherTests | `pgrep` after app quit | Host menu | H3, A1 |
| 9 | **Processes survive UI detach** | – | `smthz sessions` count before = after quit+relaunch, and after window close | relaunch shows the same output | A0, A4 |
| 10 | **Restore does not duplicate work** | C2/C3 property tests, H1 | count of `session.create` journal rows = count of panes created by the user (`sqlite3 $S/journal.sqlite "select count(*) from entries where …"`, query written by the A0 author) | kill -9 the app during New Shell, relaunch → one session | A0 |
| 11 | Host restart → ended panes, saved scrollback, fresh shells only for shells | C3 | replay contains marker | screenshot with dimmed history | H2, A6 |
| 12 | Close confirmation on running child | – | `session.foreground` | `sleep 100` + Cmd-W sheet | H1, A6 |
| 13 | Reopen closed tab = fresh shell, same cwd/title/colour/position | C2 | new session id | `pwd` matches | C2, A3 |
| 14 | Multiple windows, one workspace each, frames restored | C4 | – | 2-window relaunch | A4 |
| 15 | Floating terminal keeps its session | C2 (floating key) | – | toggle script | A7 |
| 16 | Accessibility: labels, identifiers, keyboard alternatives for drags, focus after changes | – | – | AX attribute dump; VoiceOver spot check by the user | A3–A8 |
| 17 | No stray processes, no fd leaks after all of the above | existing PTY tests | `pgrep` for children after Stop Host | – | all |

### 5.3 Definition of done for M3
M3 is accepted only when **all** of these hold, checked by the coordinator, not taken from worker reports:
1. Build OK with the Xcode toolchain. Full suite ≥ 213 tests, all passing on **3 consecutive runs**. `Package.swift` unchanged since the start of M3 (diff).
2. Rows 1–17 of the matrix pass in one coordinator session, with evidence (command output + screenshots) recorded in `docs/HANDOFF.md`.
3. With the real bundle: auto-start works, the host survives app quit and window close, Stop/Restart Host leave no strays, and a second host cannot start.
4. Quit and relaunch with ≥ 2 windows, ≥ 2 groups, a 3-pane split and a pinned coloured tab restores the identical structure, ratios (± 1 pt), titles, colours, focus, and the **same session ids**. No new `session.create` happens.
5. Host restart: no command is re-executed; saved output is visible; only plain shells restart (per D2).
6. Every M3 shortcut from table 1.3 (adjusted by D7/D8) works or is documented as deliberately unbound. Terminal-reserved input (Ctrl-C, Option-as-Meta) is unaffected.
7. The PARITY ledger row "Shell … windows, tab groups/splits" is updated with scenario rows: proved / native equivalent (D7 zoom) / reduction accepted by the user (D1, D4 if accepted) / deferred (editor/browser/agent tab kinds).
8. Decisions D1–D12 are answered by the user and recorded in `docs/HANDOFF.md`. No reduction ships without that answer.

### 5.4 Verified vs inferred in this plan
- **Verified** (read in source while writing): all Orca citations in 1.3 and 2.x; the current smthz behaviour in 1.2 (scrollback not wired in `smthzd`, `createSession` without a request id, `SessionInfo` fields, no lock, unlink on stop, `WorkspaceModel` comment, Cmd-Shift-N).
- **Inferred, not tested:**
  - that Orca's multi-window surfaces are limited to those listed;
  - that Orca loses PTYs on daemon death and cold-restores (from file names);
  - the SwiftUI restoration API behaviour on macOS 26;
  - that `posix_spawn` + SETSID is needed instead of `Process` for the host to outlive the app;
  - that Ctrl-Tab menu equivalents are unreliable;
  - the polling-cost arithmetic;
  - the test-count estimates.
- Not run: no smthz or Orca binary was launched for this plan. Nothing in it has been implemented.


## 6. Progress log (coordinator, 2026-10-24)

| WP | Status | Verified |
|---|---|---|
| C1 LayoutTree | done | 16 tests |
| K1 Keybindings | done | 10 tests |
| C2 ShellModel + tab commands | done | suite 206 -> 211 with UI tokens, x3 |
| H1 host shell RPC | done | e2e `smthz run/sessions`, no strays |
| C3, C4, H2, H3, A0-A8 | pending | after the UI phase (docs/UI-GAP.md WPs UI-3/UI-4/UI-6/UI-7/UI-10 overlap A3/A4) |

Decisions D1, D4, D7 accepted by the user on 2026-10-24. UI-first order set by the user; see `docs/UI-SPEC.md` §16.

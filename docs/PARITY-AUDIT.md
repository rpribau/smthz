# PARITY-AUDIT — what smthz still lacks to replicate Orca 1.4.238

Updated: **2026-10-31T16:45:32Z, revision 2** (previous audit: 2026-10-31, Opus research inventory). Re-audit author: dispatched Codex worker `task_7e1e5a87ec6b`, using **ponytail**. Reference: `reference/orca-1.4.238` (read-only, abbreviated `R/`). This is a code/reference audit; no fresh build, tests, GUI launch, provider call, Git write or GitHub write was performed.

## Changes since the previous audit

- Rechecked every original inventory row against current Sources, Tests and reference declarations, retaining sections 2.1–2.19. The old 96-file/14-RPC/37-key inventory is superseded: **197 Swift source files, 73 test files and 661 literal `@Test` definitions** are present. Definition count is not a new test-run result.
- Waves 10–17 add streamed terminal output, tab groups/reopen, effective keybindings and editor, host-owned projects/worktrees/config/hooks/cleanup, Source Control writes, Explorer mutations/search, agent roster/launch/hooks/live UI, browser pane/profiles/protocol/forwarding/executor, JSONL decoders, Codex app-server core, orchestration DAG/mail/gates, attention and additional settings.
- Corrected reference counts: **45 TUI agent ids**, **39 settings-pane files**, **287 CLI command paths**, **91 shortcut actions**, and **754 unique literal RPC names** in the method tree. The previous “311 methods” counted files, while its ≥93 literal-method grep missed `name:` declarations and nested families.
- The old ≈8% functional/≈20% visual figures were judgment estimates. The new numbers use the explicit weighted checklist below; changed measurement and corrected inventory prevent a clean before/after percentage comparison.
- New unresolved findings include the bundled hook executable resolving to the GUI binary, inactive agent default preference, divergent shortcut availability, app-global nonpersistent browser tabs, profile detach/import gaps, unreachable Activity/transcript views, and cleanup's omitted active-workspace parameter.

## 1. Method

| Step | Evidence and boundary |
|---|---|
| Primary inventory | Read/grepped current `Sources/`, `Tests/`, reference CLI specs, nested RPC method definitions/manifest, TUI-agent union, keybinding definitions, settings panes and renderer feature modules. Runtime registration hooks were traced through `smthzd/main.swift`, `HostService.swift`, app launch and `ShellView.swift`. |
| Execution evidence | `docs/UI-WIRING.md` is an evidence ledger, not authority for current implementation. Later specific entries override earlier stale entries only after their code callers were checked. `docs/TERMINAL-CONFORMANCE.md` supplies recorded T1 GUI evidence. Latest CHAT1 entry records five 661-test passes; B4 records 88/88 browser checks twice. Neither was rerun here. |
| Status | **DONE**: the stated row's behavior reaches a real implementation and has relevant recorded core/E2E evidence. **PARTIAL**: only some checklist behaviors are implemented, wiring/verification is incomplete, or a core exists without the product flow. **VISUAL-ONLY**: surface/preference without the promised backend effect; always zero functional. **MISSING**: no corresponding implementation. DONE does not claim every subsequent GUI change was exercised. |
| Functional measurement | Each row explicitly gives **F = covered subrequirements / declared checklist total**. Checklist units follow the behaviors in that row (or command/method/action/pane counts where those are enumerated); counts are coarse inventory coverage, not a claim that every option or edge case matches. Source-wired GUI behavior with tested backend can receive functional credit, with its missing GUI acceptance stated in Evidence; a view alone cannot. |
| Visual measurement | Each row has two evidence gates: meaningful corresponding visual structure, and representative completed/rendered behavior recorded in the GUI ledger. **V 0/2** = absent/backend only; **V 1/2** = partial/standalone/GUI-unverified surface; **V 2/2** = corresponding representative surface rendered. Unavailable empty-state shells get at most 1/2 and no functional credit. No pixel comparison was performed. |
| Size and aggregation | **S=1, M=2, L=4, XL=8** reflect Orca feature size; DONE rows retain size. Area weight = sum of its row weights; F% = 100 × Σ(weight × F fraction)/Σweights; V% similarly from V gates. **26 disjoint inventory areas, total weight 456**. A feature's backend and its CLI/settings delivery are distinct inventory surfaces, not extra implementations. The required shared-weight JSON schema has no visual-N/A field: backend-only work retains V=0, including in the overall visual mean. |
| Scope and flags | Accepted English-only and Windows/WSL exclusions are displayed as **D**, with zero scoring weight. Deferred companion mobile remains visible as an Orca gap. **U** owner decision; **I** infrastructure/credentials; **S** signing; **R** possible reduction needing acceptance. No accepted reduction was invented. |
| Artifacts | `docs/parity-status.json` stores only area percentages/weights/existing issue ids. Overall means are computed by `scripts/update-parity-readme.py`, never stored in JSON. `docs/PARITY-ISSUES.md` maps all 32 open issues and proposes uncovered work; no GitHub mutation. |
| Tooling scope | No existing `graphify-out/graph.json` was present; generating one would violate this task's three-file write boundary, so direct source/reference inspection was used. No scratch directory was created. |

Path shorthand in tables: **C/** = `Sources/SmthzCore/`, **A/** = `Sources/SmthzApp/`, **T/** = `Tests/SmthzCoreTests/`; bare executable paths are under `Sources/`. Reference paths in the Orca column are relative to R/.

### 1.1 Code/doc discrepancies resolved by this audit

- Terminal output now uses `session.subscribe` in `A/TerminalSessionView.swift`; only CLI attach and some unrelated status reads still poll. The old polling gap is complete.
- `TabStripView` now exposes groups, movement, rename/colour/collapse and reopen/bulk-close handlers; group drag/menu/relaunch GUI acceptance remains pending.
- Keybindings are consumed by app monitors/menus, and override JSON is read. **91 ids / 47 available**, plus **six browser actions** in a separate hard-coded monitor and **three Explorer actions** that ignore availability = **56 distinct source-wired action paths**. Registry availability alone understates the behavior; it also falsely disables those nine rows in the editor.
- Explorer mutates through `fs.*`, Source Control performs real writes, and worktree/project dialogs call host-owned jobs. Earlier read-only/stub rows in UI-WIRING are superseded by their M4 entries and code.
- Settings has **nine routed non-placeholder page bodies plus per-project Repository = 10/39** dedicated reference-pane bodies; **9/39** have some real backend/consumed behavior (Privacy does not). Most remain partial.
- `NotificationsSettingsPane` and an early UI-WIRING settings row still say delivery is unavailable; `AttentionModel` now consumes three of those toggles and actually schedules notifications. Terminal Bell and Send Test remain inactive.
- The onboarding Agent step still says detection is unavailable and has disabled buttons: roster delivery elsewhere did not wire this step.
- The core host-reconnect test now kills/restarts a real host with token rotation. This closes the old core regression; app lifecycle/relaunch acceptance is a separate GUI gap.

### 1.2 Measured surface census

| Surface | Reference denominator | Current smthz coverage | Interpretation |
|---|---|---|---|
| Host RPC | **754** unique literal method names | **208** distinct configured routes; **125** exact-name intersections, **124** excluding unsupported `browser.exec` (**16.45%**); **41** additional renamed/subset counterparts give **165/754 (21.88%)** mapped callable capabilities | Includes reduced browser behavior, not complete request/result compatibility. The 41 renamed/subset counterparts below receive functional correspondence credit without being called exact-name compatible. |
| CLI | **287** unique `path:[…]` declarations, excluding tests; browser specs use 80 relative paths | **120/287 (41.81%)** paths have a callable behavioral correspondence, including **25 reduced browser commands**; **80/80** browser paths parse, **79/80** execute and one fails unsupported | Alias mappings below are explicit; flags/selector/JSON parity is not implied. Fully classified browser commands are a conservative **54/80**, after downgrading profile set/use-default beyond protocol metadata's 56/23/1 forecast. |
| Shortcuts | **91** action ids in `definitions-core-1..4.ts` | **91/91** metadata; **56/91 (61.54%)** action paths source-wired; **47/91 (51.65%)** registry-available | Six browser bindings bypass overrides; three Explorer handlers ignore availability. GUI verification varies by action. |
| Settings | **39** direct `settings/*Pane.tsx` files | **10/39 (25.64%)** dedicated bodies; **9/39 (23.08%)** with some real behavior | Placeholder/sidebar headings excluded. Partial panes are scored below rather than called complete. |
| TUI roster | **45** ids in `src/shared/tui-agent.ts` | **45/45** catalog ids | PATH/version detection and launch templates are fixture/fake-agent tested; this does not prove 45 real installed providers. |
| UI surfaces | **46** canonical screen/surface families in §1.3 | **26/46 (56.52%)** have at least partial visual structure; **8/46 (17.39%)** have explicit representative rendered evidence recorded in this census | Includes partial/unreachable shells. Neither count is pixel fidelity or full behavior parity. Area visual percentages use row weights/gates, not this unweighted screen census. |

Reproduction: recursively inspect non-test/non-fixture `R/src/main/runtime/rpc/methods/**/*.ts` for literal method `name:` declarations, including wrappers (744 direct definitions + 10 wrapped names); deduplicate. Cross-check `methods/index.ts` imports/spreads. This is a **static declared-name census**: conditional layout/sidebar registrations are included; a live runtime manifest and dynamically constructed names were not evaluated. Count CLI literal paths under `src/cli/specs`, ignoring tests; 80 browser paths are relative to the browser root. Expand Swift router helper calls, its loops, session special methods and the 79 distinct BrowserCommand method names. Inspect the 91 Swift definitions and actual dispatch callers instead of counting only enum cases.

| CLI family | Orca paths | Callable correspondence | Current delivery |
|---|---:|---:|---|
| status / host list,name / agent-context | 4 | 1 | `ping` status subset |
| terminal | 12 | 5 | create→run; list→sessions; read; send→write; close→kill |
| terminal-daemon | 2 | 0 | absent |
| worktree / repo / project / reference | 24 | 14 | 7 worktree + 6 repo + project list |
| file / search | 4 | 0 | backend APIs only |
| orchestration | 30 | 19 | storage/mail/DAG/gates CLI; no workers/coordinator/request-show |
| automations | 7 | 0 | absent |
| account / agent launch / agent hooks management | 9 | 1 | agent launch; hook ingestion is an extra command |
| browser | 80 | 79 | 54 full + 25 reduced; exec unsupported |
| computer | 14 | 0 | absent |
| emulator | 16 | 0 | absent |
| Linear / Jira | 49 | 0 | absent |
| skills / artifacts / profile state | 13 | 0 | absent |
| environment / vm doctor | 12 | 0 | absent |
| serve / service / restore | 5 | 1 | `smthzd` foreground serving |
| speech keys / diagnostics | 4 | 0 | absent |
| app open / claude-teams | 2 | 0 | absent |
| **Total** | **287** | **120** | Partial correspondence, not full behavioral equivalence |


The renamed/subset census adds these **41 distinct reference method targets** beyond the 124 callable exact-name intersections. Watch delivery, settings scope and status payloads are partial correspondences; no wire-level compatibility is claimed.

| Family | Explicit smthz → Orca capability mapping | Additional targets |
|---|---|---:|
| Files | fs.list→files.readDir; fs.stat→files.stat; fs.exists→files.pathsExist; fs.createFile→files.createFile; fs.createDir→files.createDir; fs.rename→files.rename; fs.copy→files.copy; fs.trash→files.delete; fs.listFiles→files.listAll; fs.search→files.search; fs.changes→files.watch | 11 |
| Git | git.stageAll→git.bulkStage; git.unstageAll→git.bulkUnstage; git.branches→git.localBranches; git.switchBranch→git.checkout | 4 |
| Worktrees | worktree.remove→worktree.rm; worktree.prefetchBase→worktree.prefetchCreateBase; worktree.deletePreservedBranch→worktree.forceDeleteBranch | 3 |
| Repos | repo.remove→repo.rm | 1 |
| Orchestration | run-create/use/current/list/show→runCreate/Use/Current/List/Show; task-create/list/update→taskCreate/List/Update; dispatch-show→dispatchShow; gate-create/resolve/list→gateCreate/Resolve/List (all orchestration.*) | 12 |
| Terminal | session.create/list/read/write/resize/close/subscribe→terminal.create/list/read/send/resizeForClient/close/subscribe | 7 |
| Settings | hostSettings.get/set→settings.get/update (host subset only) | 2 |
| Status | ping→status.get (liveness subset) | 1 |


### 1.3 UI screen census and GUI evidence

The reference column is normalized to renderer feature families (`R/src/renderer/src/components/{terminal-pane,editor,native-chat,browser-pane,…}`), including major modal/palette/settings surfaces; this declared 46-item checklist avoids counting helper components as separate screens. A partial/standalone surface is “present” only, and a GUI check of an older browse/form shell does not verify newer operations.

| Screen/surface family | Area | Current source | Evidence |
|---|---|---|---|
| Main window/sidebar/tabs | terminal | A/ShellView.swift | rendered |
| Terminal pane/find/exit | terminal | A/TerminalSessionView.swift; docs/TERMINAL-CONFORMANCE.md | rendered |
| Explorer | files | A/RightSidebar/ExplorerPanel.swift | rendered (older browse UI); new operations unverified |
| Folder Search | files | A/RightSidebar/SearchPanel.swift | code only |
| Source Control | git | A/RightSidebar/SourceControlPanel.swift | rendered |
| Code editor | editor | absent | missing |
| Markdown editor | editor | absent | missing |
| File viewer family | editor | absent | missing |
| Single/combined diff | editor | absent | missing |
| Review annotation UI | editor | absent | missing |
| Native chat/transcript | chat | A/Chat/ChatTranscriptView.swift | standalone/offscreen only; unreachable |
| Agent dashboard | agents | absent | missing |
| Agent Live panel/badges | agents | A/RightSidebar/AgentsPanel.swift; A/Agents/AgentStatusBadge.swift | rendered (fake agent) |
| History/search/resume | history | AgentsPanel history shell | partial shell only |
| Browser | browser | A/Browser/BrowserPaneView.swift | rendered |
| Browser design mode | browser | absent | missing |
| Provider account manager | accounts | absent | missing |
| Tasks | integrations | A/Pages/TasksPage.swift | partial shell only |
| Provider issue/item dialog | integrations | absent | missing |
| Pull request/review page | integrations | absent | missing |
| Automations | automations | A/Pages/AutomationsPage.swift | partial shell only |
| Automation runs | automations | AutomationsPage showingRuns branch | partial shell only |
| Orchestration run/task/worker UI | orchestration | absent | missing |
| Activity feed | attention | A/Attention/AttentionFeed.swift | code only; unreachable |
| Mobile | mobile | A/Pages/MobilePage.swift | partial shell only |
| SSH/plain SSH | remote | absent | missing |
| Remote host/environment manager | remote | absent | missing |
| Ports | remote | A/RightSidebar/PortsPanel.swift | partial shell only |
| VM manager | remote | absent | missing |
| Skills catalog | library | absent | missing |
| Plugin catalog/panels | library | absent | missing |
| Artifacts/profile library | library | absent | missing |
| Dictation | tools | absent | missing |
| Computer use | tools | absent | missing |
| Emulator | tools | absent | missing |
| Resource Manager | projects | A/StatusBar/ResourceManagerPopover.swift | code only; measured data backend real |
| Workspace cleanup | projects | A/Dialogs/WorkspaceCleanupView.swift | code only |
| Onboarding/setup | onboarding | A/Onboarding/* | code only; partial steps |
| Jump palette | projects | A/Palette/JumpPalette.swift | code only |
| Go to File | files | A/Palette/GoToFilePalette.swift | code only |
| Settings shell | settings | A/Settings/SettingsView.swift | rendered (Shortcuts; other panes listed in §2.9) |
| Workspace composer | projects | A/Dialogs/NewWorkspaceComposer.swift | code only |
| Add Project/Clone/Create | projects | A/Dialogs/AddProjectDialog.swift | rendered (forms only) |
| Repository settings | settings | A/Dialogs/RepositorySettingsSheet.swift | code only |
| Close/delete confirmations | terminal | A/Dialogs/* | partial rendering; newer variants unverified |
| Quick commands menu/editor | terminal | A/Tabs/QuickCommand* | code only |

## 2. Feature inventory

**F** is covered/total checklist behavior; **V** is completed visual evidence gates out of two. **D** rows are accepted scope exclusions. All 133 original table rows are retained; settings/performance and explicit residual CLI/runtime rows expand the audit to **178 rows**. The area id partitions each row exactly once. Unverified GUI paths are named rather than inferred from a successful build.

### 2.1 Terminal, panes, tabs, workspaces, windows

| ID / feature | Orca (R/) | Status | Evidence / remaining checklist | Size | Area | F | V |
|---|---|---|---|---|---|---:|---:|
| 2.1.1 Persistent PTY owner (daemon) | `src/main/daemon`, `src/main/pty` | DONE | C/PTYSession.swift; C/SessionManager.swift; T/PTYSessionTests.swift: real PTY owner. | L | terminal | 1/1 | 0/2 |
| 2.1.2 Sessions outlive UI / app quit | `docs/.../model/session-restore.mdx` | DONE | C/SessionManager.swift; A/ShellController.swift; UI-WIRING A0/A1 records reconnect/app-quit ownership. | M | terminal | 1/1 | 0/2 |
| 2.1.3 Sessions after **host** restart (cold restore, respawn shells, scrollback) | `src/main/daemon`, `serve restore resume` | MISSING | C/HostLauncher.swift and smthzd/main.swift close children; no host-restart respawn/restore path (D2/D12). | L | persistence | 0/1 | 0/2 |
| 2.1.4 Host as launchd service | `macos-daemon-launchd.ts`, `serve service install` | MISSING | C/HostLauncher.swift uses posix_spawn; no launchd plist/install API. D4 temporarily deferred. | M | persistence | 0/1 | 0/2 |
| 2.1.5 Emulation engine | xterm.js in `components/terminal-pane` | PARTIAL | A/TerminalSessionView.swift + SwiftTerm: rendering, alternate screen, colour and selection have recorded T1 evidence; IME and Unicode cell-width conformance remain unproved. T/TerminalConformanceTests.swift. | L | terminal | 4/6 | 2/2 |
| 2.1.6 Output transport | push stream over IPC | DONE | A/TerminalSessionView.swift subscribes from cursor; C/HostService.swift handleStream; T/SessionStreamTests.swift covers ordering, reconnect, bounds/exit. CLI attach still polls. | M | terminal | 1/1 | 0/2 |
| 2.1.7 OSC title / cwd | terminal-pane | DONE | A/TerminalSessionView.swift setTerminalTitle/hostCurrentDirectoryUpdate: OSC title and cwd. | S | terminal | 2/2 | 2/2 |
| 2.1.8 OSC 52 clipboard | `terminal.mdx#TUI clipboard` | DONE | A/Terminal/TerminalClipboardPolicy.swift + clipboardCopy: bounded writes, query denial and replay suppression; docs/TERMINAL-CONFORMANCE.md W8 records real clipboard checks. Later Settings toggle GUI unverified. | S | terminal | 3/3 | 2/2 |
| 2.1.9 Link actions (URLs, file paths → editor/browser, modifier routing) | `components/link-actions`, `BrowserTerminalLinkActionsSetting` | PARTIAL | C/TerminalLink.swift + A/TerminalSessionView.swift: external URLs and cwd-relative file reveal; editor line/column and browser/modifier routing incomplete. T/TerminalLinkTests.swift. | M | terminal | 2/4 | 1/2 |
| 2.1.10 Find in terminal | `terminal.search` | DONE | A/Terminal/TerminalFindBar.swift; UI-WIRING records find in real terminal. | S | terminal | 1/1 | 2/2 |
| 2.1.11 Copy terminal context | `terminal.mdx#Copy terminal context` | PARTIAL | A/Terminal/TerminalContextMenu.swift + copyContext; formatter tested in T/TerminalLinkTests.swift; menu/clipboard run not performed (desktop locked). | S | terminal | 1/2 | 1/2 |
| 2.1.12 Themes / Ghostty import / Warp import | `src/main/ghostty`, `src/main/warp-themes`, `GhosttyImportModal` | PARTIAL | A/TerminalTheme.swift: built-in palette; no Ghostty or Warp import parser/UI. | M | terminal | 1/3 | 2/2 |
| 2.1.13 Shell integration, readiness, history (bash/zsh/fish) | `bash-prompt-command-composition.ts`, `fish-history*`, `runtime/terminal` | PARTIAL | C/Agents/ProgramStatusScanner.swift handles OSC 133 prompt readiness; no bash/zsh/fish injection or shell-history service. T/ProgramStatusScannerTests.swift. | M | terminal | 1/3 | 0/2 |
| 2.1.14 Switch input source, native key bindings | `terminal.switchInputSource`, `terminal.mdx#Native key bindings` | PARTIAL | A/TerminalSessionView.swift cycles NSTextInputContext sources; native key handling exists, non-US/IME GUI policy unverified (UI-WIRING T1b). | S | terminal | 1/2 | 1/2 |
| 2.1.15 Tabs: create/close/rename/colour/pin/reorder/Ctrl-1…9/Ctrl-Tab | `components/tab-bar` | DONE | A/TabStripView.swift, A/TabView.swift, C/ShellTabCommands.swift: create/close/rename/colour/pin/reorder/index/recent; T/ShellTabCommandTests.swift. New registry dispatch GUI checks remain pending. | L | terminal | 8/8 | 2/2 |
| 2.1.16 Reopen closed tab, close all, next/prev same type | `tab.reopenClosed` etc. | DONE | C/ShellTabCommands.swift and A/ShellView.swift: reopen stack, close-all, next/previous same type; core tests, A3 GUI reopen/bulk-close pending. | M | terminal | 4/4 | 1/2 |
| 2.1.17 Non-terminal tab types (agent, browser, simulator, markdown) | `tab.newAgent/newBrowser/newSimulator/newMarkdown` | PARTIAL | A/Browser/* + A/ShellView.swift supplies a real browser surface. Agent launches still use ShellTabKind.terminal; no structured-agent, simulator or markdown tab kind. Browser state is outside ShellModel. | L | terminal | 1/4 | 1/2 |
| 2.1.18 Pane splits, focus, equalize, expand | `model/tabs-panes-splits.mdx` | DONE | A/LayoutSplitView.swift + A/TerminalPaneHost.swift; C/ShellPaneCommands.swift: split/focus/equalize/expand. T/ShellPaneCommandTests.swift; prior A2 GUI splits recorded. | L | terminal | 4/4 | 2/2 |
| 2.1.19 Tab groups (incl. across worktrees, pinned boundaries) | `components/tab-group` | PARTIAL | A/TabStripView.swift + C/ShellTabCommands.swift: create/rename/colour/collapse/move with pinned boundaries; cross-worktree grouping absent. A3 drag/menu GUI pending. | M | terminal | 5/6 | 1/2 |
| 2.1.20 Multiple workspaces in sidebar | `components/sidebar` | PARTIAL | A/Workspaces/WorkspaceCatalogModel.swift + A/ShellController.swift: host catalog and workspace-specific layouts; GUI worktree switching/relaunch not exercised. | M | projects | 1/2 | 1/2 |
| 2.1.21 Multiple windows, dashboard popout | `src/main/window`, `components/dashboard-popout` | MISSING | A/SmthzApp.swift has one shared AppModel/WindowGroup, New Window disabled; no independent window ownership or dashboard popout (D3). | L | windows | 0/2 | 0/2 |
| 2.1.22 Floating terminal / floating workspace (max/min) | `components/floating-terminal`, `FloatingWorkspacePane` | VISUAL-ONLY | A/StatusBarView.swift floating chip; no floating NSPanel or maximize/minimize implementation. | M | windows | 0/3 | 1/2 |
| 2.1.23 Standalone terminal, plain SSH terminal | `components/standalone-terminal`, `plain-ssh-terminal` | MISSING | No standalone-terminal or plain-SSH surface in A/; R/components/standalone-terminal and plain-ssh-terminal remain unmatched. | M | windows | 0/2 | 0/2 |
| 2.1.24 Resource Manager (memory, end, go-to, cleanup) | `terminal.mdx#Resource Manager`, `workspace-cleanup` | PARTIAL | A/StatusBar/ResourceManagerPopover.swift + A/Dialogs/WorkspaceCleanupView.swift: memory/end/go-to and real cleanup RPC; active-workspace guard not passed. T/WorkspaceCleanupTests.swift; cleanup GUI unverified. | M | projects | 4/5 | 1/2 |
| 2.1.25 Close confirmations | `components/terminal-pane` dialogs | DONE | A/Dialogs/{CloseTerminalDialog,BulkCloseDialog,PinnedTabCloseDialog}.swift + ShellView handlers; prior UI-WIRING confirmations exercised; startup race remains. | M | terminal | 1/1 | 2/2 |
| 2.1.26 Quick commands | `components/terminal-quick-commands`, `QuickCommandsPane` | PARTIAL | A/Tabs/QuickCommandStore.swift/Menu/Dialog: saved commands reach PTY; save/run relaunch round trip not recorded. | S | terminal | 1/2 | 1/2 |
| 2.1.27 Windows shell, admin mode, WSL | `src/main/wsl`, `src/wsl-guest`, `windows` | MISSING | Windows/admin/WSL excluded from scoring: accepted macOS app scope; tracked as deferred, not delivered. | D | terminal | 0/1 | 0/2 |

### 2.2 Projects, worktrees, Git

| ID / feature | Orca (R/) | Status | Evidence / remaining checklist | Size | Area | F | V |
|---|---|---|---|---|---|---:|---:|
| 2.2.1 Project/repo registry (add, list, set, folders, persistence) | `src/main/ipc/repos`, CLI `repo *`, `project *` | DONE | C/RepoRPC.swift, WorkspaceStore+Repos.swift; A/Workspaces/WorkspaceCatalogModel.swift; T/RepoRegistryTests.swift verifies add/list/update/folders/restart persistence. Add Project GUI pending. | M | projects | 5/5 | 1/2 |
| 2.2.2 Clone / create / SSH project | `project setup-clone/-create` | PARTIAL | C/RepoRPC.swift clone/create jobs + A/Dialogs/AddProjectDialog.swift; local bare clone tested; SSH target project flow absent. | M | projects | 2/3 | 1/2 |
| 2.2.3 Worktree create (background, start-from picker, branch naming, emoji names, parent/child lineage) | `src/main/ipc/worktrees`, `model/worktrees.mdx`, `worktree-creation`, `workspace-emoji` | DONE | C/WorktreeCreator.swift, WorktreeNaming.swift; A/Dialogs/NewWorkspaceComposer.swift + WorktreeLifecycleModel.swift; T/WorktreeLifecycleTests.swift (base, names, lineage, rollback). GUI create/pwd not exercised. | L | projects | 6/6 | 1/2 |
| 2.2.4 `orca.yaml` (setup/archive/commands/terminal defaults/issue commands) | `model/orca-yaml.mdx` | PARTIAL | C/SmthzConfig.swift loads smthz.yaml then orca.yaml; setup/archive/defaultTabs/issue-command parsing tested in T/SmthzConfigTests.swift. Issue-command execution/integrations absent. | M | projects | 4/5 | 1/2 |
| 2.2.5 `.worktreeinclude`, shared dirs, sparse checkout | `components/sparse`, `src/shared/new-workspace` | DONE | C/WorktreeMaterializer.swift, WorktreeInclude.swift, WorktreeCreator.swift implement includes/shared paths/sparse; T/WorktreeLifecycleTests.swift. Sparse preset UI persists locally; no host preset CRUD. | M | projects | 3/3 | 1/2 |
| 2.2.6 Setup/archive hooks, per-repo hooks | `agents/hooks-memory.mdx` | DONE | C/SetupRunner.swift, WorktreeRemover.swift + repo local hooks/trust hashes; T/WorktreeLifecycleTests.setupTrustEnvironmentAndSetE and failingArchiveBlockedThenWaived. | M | projects | 3/3 | 1/2 |
| 2.2.7 Workspace delete/archive, preserved branches, cleanup | `workspace-cleanup` | PARTIAL | C/WorktreeRemover.swift + CleanupRPC.swift and delete/preserved-branch sheets: delete/archive/preservation tested. Cleanup active/agent/editor/SSH blocker integration incomplete. | L | projects | 3/4 | 1/2 |
| 2.2.8 Multi-repo project groups, folder workspaces | `src/main/project-groups` | PARTIAL | C/RepoRPC.swift projectGroup/folderWorkspace methods + T/RepoRegistryTests.groupsFoldersAndHostSettings; app folder cards exist. Group create/rename/colour/collapse/reorder UI absent. | M | projects | 2/3 | 1/2 |
| 2.2.9 Hibernation / sleeping workspaces | `agents/hibernation.mdx` | MISSING | A/Sidebar/WorkspaceContextMenu.swift Sleep action remains nil; no hibernation/session-resume service. | M | agents | 0/1 | 0/2 |
| 2.2.10 Base ref, compare against upstream, keep main up to date, auto-rename branch | `GitPane`, `BaseRefPicker` | PARTIAL | C/RepoRPC.swift base ref + C/GitWriteRPC.swift upstream/branchCompare + WorktreeCreator refresh-main setting; auto-rename branch absent, branchCompare UI not wired. | M | git | 3/4 | 1/2 |
| 2.2.11 Workspace sort/group/filter | sidebar options | VISUAL-ONLY | A/Sidebar/WorkspaceOptionsMenu.swift saves sort/group/filter preferences; WorkspaceCatalogModel hard-sorts main/name, no corresponding catalog behavior. | S | projects | 0/3 | 1/2 |
| 2.2.12 Worktree history back/forward, navigate up/down, jump palette | `worktree.history.*`, `cmd-j` | PARTIAL | A/Palette/JumpPaletteModel.swift lists open session tabs; no project/task rows, worktree history or up/down dispatch (C/Keybindings.swift unavailable). | S | projects | 1/5 | 1/2 |
| 2.2.13 Unread/pin/mark read workspace | sidebar | DONE | A/Workspaces/WorkspaceCatalogModel.swift + WorktreeLifecycleModel.swift call worktree.set/folderWorkspace.update; C/WorkspaceStore+Worktrees.swift persists pin/unread; GUI pending. | S | projects | 3/3 | 1/2 |
| 2.2.14 Workspace checkpoints (card status from agents) | `cli/worktree-checkpoints.mdx` | PARTIAL | smthz/WorktreeCommands.swift set --comment/--workspace-status and C/WorktreeRPC.swift persist/read checkpoint metadata. WorkspaceCatalogModel does not expose those fields on cards; live agent badges are separate from persisted checkpoint status. | S | projects | 2/3 | 1/2 |

### 2.3 Files, editor, diffs, Source Control, Checks

| ID / feature | Orca (R/) | Status | Evidence / remaining checklist | Size | Area | F | V |
|---|---|---|---|---|---|---:|---:|
| 2.3.1 File explorer browse | `editing/file-explorer.mdx` | DONE | A/RightSidebar/ExplorerPanel.swift + C/FilesRPC.swift fs.list; earlier read-only explorer seen; newer operations GUI pending. | S | files | 1/1 | 2/2 |
| 2.3.2 Explorer ops (create, rename, delete, undo/redo, copy path, drag-drop, git decorations, download remote) | `fileExplorer.*` keybindings | PARTIAL | A/RightSidebar/ExplorerPanel.swift + ExplorerUndoStack.swift: create/rename/trash/undo/redo/path-copy/drag/decorations; remote download absent. C/FileOperations.swift + T/FileOperationsTests.swift; GUI unverified. | L | files | 8/9 | 1/2 |
| 2.3.3 Folder search (ripgrep) | `src/main/ripgrep`, `sidebar.search.toggle` | DONE | C/FileSearch.swift + fs.search jobs; A/RightSidebar/SearchPanel.swift. T/FileSearchTests.swift covers rg/git-grep/in-process fallback; default suite skips optional rg path without SMTHZ_TEST_RG. | M | files | 1/1 | 1/2 |
| 2.3.4 Go to File (Cmd-P) | `model/quick-open.mdx` | PARTIAL | A/Palette/GoToFilePalette.swift uses paged fs.listFiles + fuzzy/recent ranking; opens via InterimFileOpener (default app/Finder), no in-app editor. GUI pending. | S | files | 2/3 | 1/2 |
| 2.3.5 Code editor (autosave, multicursor, go-to, find/replace, minimap, word wrap, font, languages, conflict-safe writes) | `components/editor`, `editing/monaco.mdx`, `file-write-disk-precondition.ts` | MISSING | No A/Editor or Monaco bundle/host; C/FilesRPC.swift registers neither fs.read nor fs.write. docs/EDITOR-EXPERIMENT.md is research only; #1 needs decision. | XL | editor | 0/1 | 0/2 |
| 2.3.6 Markdown editor (slash menu, links, TOC, front matter, tables, review annotations) | `editing/markdown.mdx` | MISSING | No Markdown editor surface; A/Chat/ChatTranscriptView.swift inline markdown rendering is unrelated. R/editing/markdown.mdx scope remains. | L | editor | 0/1 | 0/2 |
| 2.3.7 Viewers: HTML, Mermaid, PDF, images, CSV/TSV, Jupyter | `editing/viewers.mdx`, `src/main/notebook` | MISSING | No dedicated HTML/Mermaid/PDF/image/CSV/notebook viewers. Browser file navigation and default-app open do not implement R/editing/viewers.mdx. | L | editor | 0/6 | 0/2 |
| 2.3.8 Source Control status | `src/main/source-control` | DONE | A/RightSidebar/SourceControlPanel.swift + C/GitSourceControl.swift; real status and ahead/behind. | S | git | 1/1 | 2/2 |
| 2.3.9 Stage/unstage/discard/commit/amend/push, AI commit message | `review/commit-push.mdx`, `CommitMessageAiPane` | PARTIAL | C/GitSourceControl.swift + GitWriteRPC.swift and A/RightSidebar/SourceControlCommitBox.swift: stage/unstage/discard/commit/amend/push; AI message generator disabled. T/GitSourceControlTests.swift; UI-WIRING records Stage→Commit→Push. | L | git | 6/7 | 2/2 |
| 2.3.10 Diff viewer (combined diff, file tree, word wrap, whitespace, collapse unchanged) | `review/diff-viewer.mdx`, `editor/combined-diff` | PARTIAL | C/GitService.swift.diff and GitWriteRPC.swift git.diff provide text; no single/combined visual diff, tree, whitespace or unchanged-collapse controls. | L | editor | 1/5 | 0/2 |
| 2.3.11 Diff comments, annotate AI diff, send review notes to agent | `components/diff-comments`, `review/annotate-ai-diff.mdx` | MISSING | No diff-comments/AI annotation/review-note model or UI; C/Keybindings.swift review actions unavailable. | L | editor | 0/3 | 0/2 |
| 2.3.12 Conflicts / rebase / squash | `squash.*` RPC | PARTIAL | C/GitSourceControl.swift + SourceControlPanel conflict banner handle merge/rebase abort/continue; squash workflow absent. T/GitSourceControlTests.swift; conflict GUI pending. | M | git | 2/3 | 1/2 |
| 2.3.13 Attribution of AI changes | `review/attribution.mdx` | MISSING | No AI-change attribution store or git integration in C/; R/review/attribution.mdx unmatched. | M | git | 0/1 | 0/2 |
| 2.3.14 Checks panel (CI) | `components/right-sidebar` | VISUAL-ONLY | A/RightSidebar/ChecksPanel.swift has no CI provider; SourceControl backend does not supply checks. | M | integrations | 0/1 | 1/2 |
| 2.3.15 Open in external editor (VS Code etc.) | `external-editor-launch.ts` | PARTIAL | InterimFileOpener in A/Palette/GoToFilePalette.swift routes safe documents to default app/Finder; dedicated VS Code/Cursor editor selection absent. | S | files | 1/2 | 1/2 |

### 2.4 Agents

| ID / feature | Orca (R/) | Status | Evidence / remaining checklist | Size | Area | F | V |
|---|---|---|---|---|---|---:|---:|
| 2.4.1 Roster/detection of 45 TUI agents, CLI version probe | `src/shared/tui-agent.ts`, `agent-cli-version-probe.ts` | DONE | C/Agents/AgentCatalog.swift exactly matches 45 R/src/shared/tui-agent.ts ids (previous 47 incorrect); AgentDetection.swift PATH/version probes; T/AgentCatalogTests.swift + AgentDetectionTests.swift. | M | agents | 45/45 | 2/2 |
| 2.4.2 Launch agent in tab with defaults/env/permissions/trust | `src/main/agent-launch`, `agent-trust-presets.ts`, `AgentsPane` | PARTIAL | C/Agents/AgentLaunch.swift + A/Agents/AgentLauncher.swift: argv/env/permissions/prompt delivery; default-agent preference not consumed; managed trust/account flow absent. T/AgentLaunchTests.swift uses fake agents, no paid/real provider run. | L | agents | 4/6 | 2/2 |
| 2.4.3 Status hooks, state indicators, restart chip | `src/main/agent-hooks`, `model/agents-sessions.mdx` | PARTIAL | C/Agents/{AgentStatusStore,AgentHookPayload,ProgramStatusScanner}.swift + HostService agent.hook/status; A/Agents/AgentStatusBadge.swift restart chip and AgentsPanel live list. T/AgentHookRPCTests.swift; UI-WIRING AG4 fake-agent GUI states/restart verified. Bundled hook CLI execution still broken/unverified. | L | agents | 3/4 | 2/2 |
| 2.4.4 Agent dashboard | `components/dashboard` | MISSING | No A/Dashboard; A/RightSidebar/AgentsPanel.swift live list is not R/components/dashboard. | M | agents | 0/1 | 0/2 |
| 2.4.5 Native structured chat (Claude, Codex, ACP; composer, questions, permissions, attachments, forks) | `src/main/native-chat`, `src/main/acp`, `agents/native-chat.mdx` | PARTIAL | C/Chat/Codex/CodexAppServerClient.swift tested stdio transport; no Claude/ACP control transport, reachable composer, approval UI, attachments, questions or forks. A/Chat/ChatTranscriptView.swift standalone only. T/CodexAppServerTests.swift: fake process only. | XL | chat | 1/8 | 1/2 |
| 2.4.6 Accounts + hot-swap (Claude, Codex, Cursor, Grok, Antigravity, MiniMax, OpenCode…) | `claude-accounts`, `codex-accounts`, `cursor-accounts`, `grok-accounts`, `AccountsPane` | MISSING | No provider account service/Keychain account store/hot-swap. AgentLaunch rejects accountId with unsupportedAccount; browser cookie Keychain helper is not agent accounts. | L | accounts | 0/1 | 0/2 |
| 2.4.7 Usage / rate limits / estimated cost | `claude-usage`, `codex-usage`, `opencode-usage`, `muse-usage`, `rate-limits`, `stats` | MISSING | No usage/rate-limit/cost providers in C/; settings Stats label is not a meter. | M | accounts | 0/3 | 0/2 |
| 2.4.8 Session history / AI vault FTS search, resume | `ai-vault`, `ai-vault-search`, `agents/session-history.mdx` | PARTIAL | C/Chat/TranscriptReader.swift + Claude/Codex decoders tail JSONL; A/Chat standalone renderer; no session catalog/FTS/resume product flow. T/Transcript*Tests.swift, real-file count sanity recorded; no Chat/Terminal toggle. | L | history | 1/4 | 1/2 |
| 2.4.9 Memory files | `src/main/memory` | MISSING | No memory-file browser/editor/service; R/src/main/memory plus agents/hooks-memory docs unmatched. | M | history | 0/1 | 0/2 |
| 2.4.10 Subagents / teams, hand-off between agents | `claude-teams`, `agents/codex.mdx` | PARTIAL | C/Agents/AgentHookPayload.swift captures child metadata; no child roster/teams or hand-off runtime. The claude-agent-teams catalog id alone is not teams support. | M | agents | 1/3 | 0/2 |
| 2.4.11 Agent awake (prevent sleep) | `agent-awake-service.ts` | MISSING | No IOPMAssertion/activity sleep-prevention service in Sources (R/agent-awake-service.ts). | S | agents | 0/1 | 0/2 |
| 2.4.12 Generated tab titles, text generation | `src/main/text-generation` | MISSING | No generated-title or text-generation service; OSC title updates are terminal-provided. | S | agents | 0/2 | 0/2 |

### 2.5 Browser (WebKit)

| ID / feature | Orca (R/) | Status | Evidence / remaining checklist | Size | Area | F | V |
|---|---|---|---|---|---|---:|---:|
| 2.5.1 Browser pane: tabs, address bar, back/forward/reload, find, zoom, home page, search engine | `components/browser-pane`, `browser/overview.mdx` | PARTIAL | A/Browser/{BrowserTabModel,BrowserToolbar,BrowserFind,BrowserPaneView}.swift: tabs/address/navigation/find/zoom/popups/dialogs; home/search preference persistence absent. T/BrowserURLInputTests.swift; UI-WIRING B1 records real localhost GUI. | L | browser | 7/9 | 2/2 |
| 2.5.2 Worktree-scoped sessions, localhost labels, link routing | `BrowserLocalhostWorktreeLabelsSetting` | PARTIAL | A/Browser/Automation/BrowserAutomation.swift load handles localhost URL; worktree target ignored and labels/routing not workspace-scoped; BrowserTabStore is app-global. | M | browser | 1/3 | 1/2 |
| 2.5.3 Profiles, identity, cookie import, Google sign-in | `browser/profiles.mdx` | PARTIAL | C/Browser/BrowserProfileStore.swift + A/Browser/Automation/BrowserAutomation.swift profiles/identity reachable via CLI; cookie importers fixture-tested but no callers in A/, no Google import/sign-in path or profile UI. T/BrowserCookieImport*Tests.swift. | L | browser | 2/4 | 1/2 |
| 2.5.4 Design mode / grab / annotate element → chat | `browser/design-mode.mdx` | MISSING | No grab/annotation/agent attachment surface; C/Keybindings.swift browserGrabElement/browserAnnotateElement unavailable. | L | browser | 0/3 | 0/2 |
| 2.5.5 Browser automation CLI (80 command paths) | `src/cli/specs/browser-*.ts`, `browser-client-automation-protocol.ts` | PARTIAL | C/Browser/BrowserAutomationProtocol.swift + A/Browser/Automation/* + smthz/BrowserCommands.swift: 80 parsed, 79 execute, 54 classified full after downgrading profile set/use-default; 25 partial, exec unsupported. scripts/browser-e2e.sh recorded 88/88 twice; R-B1..B12 unresolved reductions. | XL | browser | 54/80 | 1/2 |
| 2.5.6 Site permissions, downloads, viewport emulation, devtools | `BrowserSitePermissionsSetting`, `DevToolsPane` | PARTIAL | A/Browser/BrowserTabModel.swift + BrowserDownloadsShelf.swift: downloads, inspectable WebKit and partial viewport; no persisted per-site permission manager. B1 GUI download exercised; public WebKit inspector differs from Chromium. | M | browser | 3/4 | 2/2 |
| 2.5.7 Remote/hosted browser for SSH workspaces | `BrowserClientHostedRemoteSetting` | MISSING | No remote browser execution/tunnel; host forwarding is local host→local GUI, not SSH/relay. | L | remote | 0/1 | 0/2 |

### 2.6 Orchestration and CLI

| ID / feature | Orca (R/) | Status | Evidence / remaining checklist | Size | Area | F | V |
|---|---|---|---|---|---|---:|---:|
| 2.6.1 `status`, `host list/name`, `agent-context` | src/cli/specs/core.ts; environment.ts; introspection.ts | PARTIAL | smthz/main.swift ping is a status subset; no host list/name or agent-context. Paths is extra, not an Orca host-command replacement. | S | cli | 1/4 | 0/2 |
| 2.6.2 `terminal create/list/read/send/close/stop/split/rename/set-pane-title/show/switch/wait` | src/cli/specs/core.ts; terminal-send.ts; terminal-close.ts; terminal-set-pane-title.ts | PARTIAL | smthz/main.swift run/sessions/read/write/kill map create/list/read/send/close. No CLI split/rename/pane-title/show/switch/wait or non-destructive stop. attach is extra and remains TTY-unverified. | M | cli | 5/12 | 0/2 |
| 2.6.3 `terminal-daemon status/restart` | src/cli/specs/terminal-daemon.ts | MISSING | No terminal-daemon CLI parser; app Host menu is not CLI status/restart. | S | cli | 0/2 | 0/2 |
| 2.6.4 `worktree *`, `repo *`, `project *`, `reference *` | src/cli/specs/worktree-set.ts; core.ts; repo.ts; project.ts; reference.ts | PARTIAL | smthz/{RepoCommands,WorktreeCommands,CLICommon}.swift: 6 repo + 7 worktree + project list; no six project-setup paths or four reference paths. Host clone/create UI does not add CLI setup commands. | L | cli | 14/24 | 0/2 |
| 2.6.5 `file open/diff/open-changed`, `search` | src/cli/specs/file.ts; search.ts | MISSING | No file open/diff/open-changed/search CLI branch (C/FilesRPC.swift only backend APIs). | M | cli | 0/4 | 0/2 |
| 2.6.6 `orchestration *` (runs, tasks DAG, dispatch, workers, mail, ask/reply, gates, coordinator, federation) | src/cli/specs/orchestration.ts; orchestration-worker-specs.ts | PARTIAL | C/Orchestration/{OrchestrationStore,OrchestrationRPC}.swift + smthz/OrchestrationCommands.swift: runs/DAG/dispatch/mail/ask/gates/reset; 19 CLI verbs, 21 RPC incl wait helpers. Missing 8 worker verbs, request-show, coordinator-start/stop; no federation. T/OrchestrationTests.swift. | XL | orchestration | 19/30 | 0/2 |
| 2.6.7 `automations *` | src/cli/specs/automations.ts | MISSING | No automations CLI/parser or scheduler. | L | cli | 0/7 | 0/2 |
| 2.6.8 `account *`, `agent launch`, `agent hooks *` | src/cli/specs/account.ts; agent-launch.ts; agent-hooks.ts | PARTIAL | smthz/AgentCommands.swift implements agent launch; provider account and agent hooks prepare/status/on/off paths absent. HookCommand.swift is scoped ingestion, not hook-management CLI. | M | cli | 1/9 | 0/2 |
| 2.6.9 `browser` family (tab/profile/identity/automation) | src/cli/specs/browser-basic.ts; browser-advanced.ts | PARTIAL | smthz/BrowserCommands.swift and C/Browser/BrowserCommandParser.swift cover all 80 paths; 54 full / 25 reduced / 1 unsupported at executor. T/BrowserCommandParserTests.swift; recorded B4 E2E. | XL | cli | 54/80 | 0/2 |
| 2.6.10 `computer *` | src/cli/specs/computer.ts | MISSING | No computer command branch in smthz/main.swift/CLICommon.swift. | L | cli | 0/14 | 0/2 |
| 2.6.11 `emulator *` | src/cli/specs/emulator.ts | MISSING | No emulator command branch (reference has 16 paths, not 15). | L | cli | 0/16 | 0/2 |
| 2.6.12 `linear *` / `jira *` | src/cli/specs/linear.ts; linear-mcp.ts; jira.ts | MISSING | No Linear/Jira CLI branch; reference 29 Linear + 20 Jira paths. | L | cli | 0/49 | 0/2 |
| 2.6.13 `skills *`, `artifacts *`, `profile state *` | src/cli/specs/skills.ts; artifacts.ts; profile-state.ts | MISSING | No skills/artifacts/profile-state branches (reference 6+5+2). | M | cli | 0/13 | 0/2 |
| 2.6.14 `environment *`, `vm recipe doctor` | src/cli/specs/environment.ts; managed-server.ts; vm.ts | MISSING | No environment or vm recipe doctor parser (11+1); host list/name counted above. | L | cli | 0/12 | 0/2 |
| 2.6.15 `serve`, `serve service *`, `serve restore resume` | src/cli/specs/serve.ts | PARTIAL | smthzd/main.swift foreground serving maps serve behavior; no restore resume or service install/status/uninstall. CLI spelling/response compatibility not claimed. | M | cli | 1/5 | 0/2 |
| 2.6.16 `speech openai-key *`, `diagnostics memory` | src/cli/specs/speech.ts; diagnostics.ts | MISSING | No speech-key or memory-diagnostics CLI paths. | S | cli | 0/4 | 0/2 |
| 2.6.17 CLI install into PATH / registration | src/renderer/src/components/settings/general-pane/CliSection.tsx; src/main/cli | MISSING | A/Settings/SettingsPanes.swift Register disabled; scripts/package-app.sh packages binaries, no PATH registration. | S | distribution | 0/1 | 1/2 |
| 2.6.18 Host RPC surface | src/main/runtime/rpc/methods/index.ts | PARTIAL | 208 distinct routes incl unsupported exec; 124 callable exact-name Orca intersections plus 41 explicitly mapped renamed/subset counterparts = 165/754. This counts callable capability correspondence, including partial semantics; full parameter/result compatibility is not asserted. | XL | cli | 165/754 | 0/2 |
| 2.6.19 App open / claude-teams CLI | src/cli/specs/core.ts | MISSING | No smthz app-open or claude-teams CLI branch. Counted separately so every one of the 287 reference paths appears in the family census. | S | cli | 0/2 | 0/2 |
| 2.6.20 Supervised worker lifecycle / coordinator runtime | src/main/runtime/rpc/methods/orchestration/workers.ts; orchestration/worker-control.ts | MISSING | C/Orchestration/OrchestrationStore.swift dispatch only writes a terminal handle; no worker spawning, observation, stop/abandon/release/retain, real injection or coordinator process. T/OrchestrationTests.swift covers storage only. | XL | orchestration | 0/1 | 0/2 |
| 2.6.21 Orchestration federation / remote authority | src/main/runtime/rpc/methods/orchestration/federation*.ts | MISSING | No federation/remote authority runtime in C/Orchestration; R/orchestration/federation*.ts APIs have no equivalent. | L | orchestration | 0/1 | 0/2 |
| 2.6.22 Orchestration run/task/worker UI | src/renderer/src/components/settings/OrchestrationPane.tsx | MISSING | Settings Orchestration routes placeholder; no run/task/gate browser or worker dashboard in A/. | M | orchestration | 0/1 | 0/2 |

### 2.7 Automations

| ID / feature | Orca (R/) | Status | Evidence / remaining checklist | Size | Area | F | V |
|---|---|---|---|---|---|---:|---:|
| 2.7.1 Schedules, timezones, missed-run grace, prechecks, session reuse, extra agent args, run history, per-host targets | `src/main/automations`, `src/shared/automation-schedules.ts`, `cli/automations.mdx` | VISUAL-ONLY | A/Pages/AutomationsPage.swift VISUAL-ONLY: schedules/timezones/grace/prechecks/reuse/args/history/host targets absent; R/automations.ts exposes seven real methods. | L | automations | 0/8 | 1/2 |
| 2.7.2 Settings pane | `AutomationsSettingsPane` | MISSING | A/Settings/SettingsView.swift automations routes SettingsUnavailableBody. | S | automations | 0/1 | 0/2 |

### 2.8 Integrations

| ID / feature | Orca (R/) | Status | Evidence / remaining checklist | Size | Area | F | V |
|---|---|---|---|---|---|---:|---:|
| 2.8.1 GitHub: PRs/reviews, auto-merge, stacked PRs, issues, actions, tasks, API budget, item dialog, PR page | `src/main/github`, `components/github*`, `pull-request-page`, `review/github.mdx` | MISSING | No C/GitHub service; A/Pages/TasksPage.swift and ChecksPanel visual placeholders; local Git push does not implement PR/check/issue APIs. | XL | integrations | 0/1 | 0/2 |
| 2.8.2 GitLab, Gitea, Bitbucket, Azure DevOps | `src/main/gitlab`, `src/main/gitea`, `src/main/bitbucket`, `src/main/azure-devops` | MISSING | No GitLab/Gitea/Bitbucket/Azure adapters; TasksPage provider icon has no client. | L | integrations | 0/4 | 0/2 |
| 2.8.3 Linear (issues, comments, relations, MCP-style write, agent skill) | `src/main/linear`, `LinearAgentSkillPane` | MISSING | No Linear client, OAuth/token store or issue/write commands; disabled connect control only. | L | integrations | 0/1 | 0/2 |
| 2.8.4 Jira | `src/main/jira`, `review/jira.mdx` | MISSING | No Jira client/credentials/CLI; disabled TasksPage connect control only. | M | integrations | 0/1 | 0/2 |
| 2.8.5 Task page / task sources | `components/task-page`, `TasksPane` | VISUAL-ONLY | A/Pages/TasksPage.swift switches local provider-empty states, never fetches tasks. UI-WIRING destination page is stub. | M | integrations | 0/1 | 1/2 |

### 2.9 Settings pages (Orca 39 panes)

| ID / feature | Orca (R/) | Status | Evidence / remaining checklist | Size | Area | F | V |
|---|---|---|---|---|---|---:|---:|
| 2.9.1 AccountsPane | src/renderer/src/components/settings/AccountsPane.tsx | MISSING | A/Settings/SettingsView.swift has no matching dedicated pane body; route absent or SettingsUnavailableBody. Sidebar title alone receives no credit. | S | settings | 0/1 | 0/2 |
| 2.9.2 AdvancedPane | src/renderer/src/components/settings/AdvancedPane.tsx | MISSING | A/Settings/SettingsView.swift has no matching dedicated pane body; route absent or SettingsUnavailableBody. Sidebar title alone receives no credit. | S | settings | 0/1 | 0/2 |
| 2.9.3 AgentsPane | src/renderer/src/components/settings/AgentsPane.tsx | PARTIAL | SettingsPanes AgentsSettingsPane queries roster; stored default not used at launch and broader agent configuration absent. | S | settings | 1/3 | 1/2 |
| 2.9.4 AppearancePane | src/renderer/src/components/settings/AppearancePane.tsx | PARTIAL | A/Settings/AppearancePane.swift: theme/zoom/title/status controls consumed; icon/chat-contrast/compact card behavior incomplete. Other sidebar controls also real; latest controls GUI pending. | S | settings | 4/7 | 2/2 |
| 2.9.5 ArtifactsSettingsPane | src/renderer/src/components/settings/ArtifactsSettingsPane.tsx | MISSING | A/Settings/SettingsView.swift has no matching dedicated pane body; route absent or SettingsUnavailableBody. Sidebar title alone receives no credit. | S | settings | 0/1 | 0/2 |
| 2.9.6 AutomationsSettingsPane | src/renderer/src/components/settings/AutomationsSettingsPane.tsx | MISSING | A/Settings/SettingsView.swift has no matching dedicated pane body; route absent or SettingsUnavailableBody. Sidebar title alone receives no credit. | S | settings | 0/1 | 0/2 |
| 2.9.7 BrowserPane | src/renderer/src/components/settings/BrowserPane.tsx | MISSING | A/Settings/SettingsView.swift has no matching dedicated pane body; route absent or SettingsUnavailableBody. Sidebar title alone receives no credit. | S | settings | 0/1 | 0/2 |
| 2.9.8 BrowserUsePane | src/renderer/src/components/settings/BrowserUsePane.tsx | MISSING | A/Settings/SettingsView.swift has no matching dedicated pane body; route absent or SettingsUnavailableBody. Sidebar title alone receives no credit. | S | settings | 0/1 | 0/2 |
| 2.9.9 CommitMessageAiPane | src/renderer/src/components/settings/CommitMessageAiPane.tsx | MISSING | A/Settings/SettingsView.swift has no matching dedicated pane body; route absent or SettingsUnavailableBody. Sidebar title alone receives no credit. | S | settings | 0/1 | 0/2 |
| 2.9.10 ComputerUsePane | src/renderer/src/components/settings/ComputerUsePane.tsx | MISSING | A/Settings/SettingsView.swift has no matching dedicated pane body; route absent or SettingsUnavailableBody. Sidebar title alone receives no credit. | S | settings | 0/1 | 0/2 |
| 2.9.11 DevToolsPane | src/renderer/src/components/settings/DevToolsPane.tsx | MISSING | A/Settings/SettingsView.swift has no matching dedicated pane body; route absent or SettingsUnavailableBody. Sidebar title alone receives no credit. | S | settings | 0/1 | 0/2 |
| 2.9.12 DeveloperPermissionsPane | src/renderer/src/components/settings/DeveloperPermissionsPane.tsx | MISSING | A/Settings/SettingsView.swift has no matching dedicated pane body; route absent or SettingsUnavailableBody. Sidebar title alone receives no credit. | S | settings | 0/1 | 0/2 |
| 2.9.13 EphemeralVmsPane | src/renderer/src/components/settings/EphemeralVmsPane.tsx | MISSING | A/Settings/SettingsView.swift has no matching dedicated pane body; route absent or SettingsUnavailableBody. Sidebar title alone receives no credit. | S | settings | 0/1 | 0/2 |
| 2.9.14 ExperimentalPane | src/renderer/src/components/settings/ExperimentalPane.tsx | MISSING | A/Settings/SettingsView.swift has no matching dedicated pane body; route absent or SettingsUnavailableBody. Sidebar title alone receives no credit. | S | settings | 0/1 | 0/2 |
| 2.9.15 FloatingWorkspacePane | src/renderer/src/components/settings/FloatingWorkspacePane.tsx | MISSING | A/Settings/SettingsView.swift has no matching dedicated pane body; route absent or SettingsUnavailableBody. Sidebar title alone receives no credit. | S | settings | 0/1 | 0/2 |
| 2.9.16 GeneralPane | src/renderer/src/components/settings/GeneralPane.tsx | PARTIAL | A/Settings/SettingsPanes.swift: workspace-root/nesting and close-confirmation groups consumed; editor/Open-in apps/CLI-update groups absent. GUI pending. | S | settings | 2/5 | 1/2 |
| 2.9.17 GitPane | src/renderer/src/components/settings/GitPane.tsx | PARTIAL | SettingsPanes GitSettingsPane: prefix and refresh-main live through hostSettings; compare-base/Jira-casing/SC-order missing. GUI pending. | S | settings | 2/5 | 1/2 |
| 2.9.18 GitProviderApiBudgetPane | src/renderer/src/components/settings/GitProviderApiBudgetPane.tsx | MISSING | A/Settings/SettingsView.swift has no matching dedicated pane body; route absent or SettingsUnavailableBody. Sidebar title alone receives no credit. | S | settings | 0/1 | 0/2 |
| 2.9.19 InputPane | src/renderer/src/components/settings/InputPane.tsx | MISSING | A/Settings/SettingsView.swift has no matching dedicated pane body; route absent or SettingsUnavailableBody. Sidebar title alone receives no credit. | S | settings | 0/1 | 0/2 |
| 2.9.20 IntegrationsPane | src/renderer/src/components/settings/IntegrationsPane.tsx | MISSING | A/Settings/SettingsView.swift has no matching dedicated pane body; route absent or SettingsUnavailableBody. Sidebar title alone receives no credit. | S | settings | 0/1 | 0/2 |
| 2.9.21 LinearAgentSkillPane | src/renderer/src/components/settings/LinearAgentSkillPane.tsx | MISSING | A/Settings/SettingsView.swift has no matching dedicated pane body; route absent or SettingsUnavailableBody. Sidebar title alone receives no credit. | S | settings | 0/1 | 0/2 |
| 2.9.22 MobileEmulatorSettingsPane | src/renderer/src/components/settings/MobileEmulatorSettingsPane.tsx | MISSING | A/Settings/SettingsView.swift has no matching dedicated pane body; route absent or SettingsUnavailableBody. Sidebar title alone receives no credit. | S | settings | 0/1 | 0/2 |
| 2.9.23 MobilePane | src/renderer/src/components/settings/MobilePane.tsx | MISSING | A/Settings/SettingsView.swift has no matching dedicated pane body; route absent or SettingsUnavailableBody. Sidebar title alone receives no credit. | S | settings | 0/1 | 0/2 |
| 2.9.24 MobileSettingsPane | src/renderer/src/components/settings/MobileSettingsPane.tsx | MISSING | A/Settings/SettingsView.swift has no matching dedicated pane body; route absent or SettingsUnavailableBody. Sidebar title alone receives no credit. | S | settings | 0/1 | 0/2 |
| 2.9.25 NotificationsPane | src/renderer/src/components/settings/NotificationsPane.tsx | PARTIAL | SettingsPanes toggles enabled/agentTaskComplete/suppressWhileFocused consumed by AttentionModel; terminalBell and Send Test inactive; copy still incorrectly says delivery unavailable. | S | settings | 3/5 | 1/2 |
| 2.9.26 OrcaAccountSettingsPane | src/renderer/src/components/settings/OrcaAccountSettingsPane.tsx | MISSING | A/Settings/SettingsView.swift has no matching dedicated pane body; route absent or SettingsUnavailableBody. Sidebar title alone receives no credit. | S | settings | 0/1 | 0/2 |
| 2.9.27 OrchestrationPane | src/renderer/src/components/settings/OrchestrationPane.tsx | MISSING | A/Settings/SettingsView.swift has no matching dedicated pane body; route absent or SettingsUnavailableBody. Sidebar title alone receives no credit. | S | settings | 0/1 | 0/2 |
| 2.9.28 PrivacyPane | src/renderer/src/components/settings/PrivacyPane.tsx | VISUAL-ONLY | SettingsPanes PrivacySettingsPane stores a value; no telemetry backend consumes it. | S | settings | 0/1 | 1/2 |
| 2.9.29 QuickCommandsPane | src/renderer/src/components/settings/QuickCommandsPane.tsx | DONE | SettingsPanes QuickCommandsSettingsPane calls real QuickCommandStore CRUD/editor dialogs; sheet-on-settings interaction unverified. | S | settings | 1/1 | 1/2 |
| 2.9.30 RepositoryPane | src/renderer/src/components/settings/RepositoryPane.tsx | PARTIAL | SettingsView project:<id> embeds real RepositorySettingsSheet: name/colour/base/hooks/shared paths/visibility groups; issue-command editing/integration incomplete. GUI pending. | S | settings | 5/6 | 1/2 |
| 2.9.31 RuntimeEnvironmentsPane | src/renderer/src/components/settings/RuntimeEnvironmentsPane.tsx | MISSING | A/Settings/SettingsView.swift has no matching dedicated pane body; route absent or SettingsUnavailableBody. Sidebar title alone receives no credit. | S | settings | 0/1 | 0/2 |
| 2.9.32 SessionHistorySettingsPane | src/renderer/src/components/settings/SessionHistorySettingsPane.tsx | MISSING | A/Settings/SettingsView.swift has no matching dedicated pane body; route absent or SettingsUnavailableBody. Sidebar title alone receives no credit. | S | settings | 0/1 | 0/2 |
| 2.9.33 SettingsSetupGuidePane | src/renderer/src/components/settings/SettingsSetupGuidePane.tsx | MISSING | A/Settings/SettingsView.swift has no matching dedicated pane body; route absent or SettingsUnavailableBody. Sidebar title alone receives no credit. | S | settings | 0/1 | 0/2 |
| 2.9.34 ShareSkillsSettingsPane | src/renderer/src/components/settings/ShareSkillsSettingsPane.tsx | MISSING | A/Settings/SettingsView.swift has no matching dedicated pane body; route absent or SettingsUnavailableBody. Sidebar title alone receives no credit. | S | settings | 0/1 | 0/2 |
| 2.9.35 ShortcutsPane | src/renderer/src/components/settings/ShortcutsPane.tsx | PARTIAL | A/Settings/ShortcutsPane.swift: search/editor/conflict and file edit real; double-tap/policy controls incomplete. T/KeybindingOverrideTests.swift; file edit→menu update GUI verified. | S | settings | 2/3 | 2/2 |
| 2.9.36 SshPane | src/renderer/src/components/settings/SshPane.tsx | MISSING | A/Settings/SettingsView.swift has no matching dedicated pane body; route absent or SettingsUnavailableBody. Sidebar title alone receives no credit. | S | settings | 0/1 | 0/2 |
| 2.9.37 TasksPane | src/renderer/src/components/settings/TasksPane.tsx | MISSING | A/Settings/SettingsView.swift has no matching dedicated pane body; route absent or SettingsUnavailableBody. Sidebar title alone receives no credit. | S | settings | 0/1 | 0/2 |
| 2.9.38 TerminalPane | src/renderer/src/components/settings/TerminalPane.tsx | PARTIAL | A/Settings/TerminalSettingsPane.swift + TerminalSettingsModel.swift: font/cursor/rendering groups consumed; imports/advanced mouse-copy controls/blur incomplete. T1b creation-time apply fixed; newer GUI controls untested. | S | settings | 3/6 | 2/2 |
| 2.9.39 VoicePane | src/renderer/src/components/settings/VoicePane.tsx | MISSING | A/Settings/SettingsView.swift has no matching dedicated pane body; route absent or SettingsUnavailableBody. Sidebar title alone receives no credit. | S | settings | 0/1 | 0/2 |
| 2.9.40 Settings search | src/renderer/src/components/settings | PARTIAL | A/Settings/SettingsSidebar.swift filters page metadata; ShortcutsPane has row search. No global search of settings controls/values. | S | settings | 1/2 | 1/2 |

### 2.10 Notifications and attention

| ID / feature | Orca (R/) | Status | Evidence / remaining checklist | Size | Area | F | V |
|---|---|---|---|---|---|---:|---:|
| 2.10.1 Agent-finished notifications, persistent bell, custom sounds, tuning | `src/main/notifications`, `notifications.mdx` | PARTIAL | A/Attention/AttentionModel.swift attaches app-wide: agent transitions, notifications and fixed-name sounds; persistent terminal bell/delivery tuning not fully implemented. C/AttentionRules.swift + T/AttentionRulesTests.swift; notification/audio GUI untested. | M | attention | 3/5 | 1/2 |
| 2.10.2 Mark unread / activity feed | `components/activity`, `activity.mdx` | PARTIAL | AttentionModel persists unread/read state to 0600 attention.json; A/Attention/AttentionFeed.swift has no caller. Shell .activity opens Mobile, no Activity page. | M | attention | 1/2 | 1/2 |
| 2.10.3 Dock badge/menu, tray | `src/main/dock`, `src/main/tray` | PARTIAL | A/SmthzApp.swift applicationDockMenu + AttentionModel badge/menu; no tray/status item. Dock and persistence relaunch not exercised. | S | attention | 2/3 | 1/2 |
| 2.10.4 Pet, stats, star nag, feature tips/wall, contextual tours | `src/renderer/src/components/{pet,stats,star-nag,feature-tips,feature-wall,contextual-tours}` | MISSING | No pet/stats/star-nag/tips/feature-wall/tours implementation; sidebar labels are not those features. Star/social links need decision. | L | attention | 0/6 | 0/2 |

### 2.11 Mobile, pairing, relay

| ID / feature | Orca (R/) | Status | Evidence / remaining checklist | Size | Area | F | V |
|---|---|---|---|---|---|---:|---:|
| 2.11.1 Pairing, relay, mobile web/app (chat, quick commands, tabs, account switcher, SC, browser view) | `mobile/`, `src/main/managed-server`, `mobile.mdx`, `mobileWeb.*` RPC | VISUAL-ONLY | A/Pages/MobilePage.swift placeholder only; no pairing/relay/mobile client. Companion deferred, retained as an Orca gap rather than silently removed. | XL | mobile | 0/1 | 1/2 |

### 2.12 SSH and remote hosts

| ID / feature | Orca (R/) | Status | Evidence / remaining checklist | Size | Area | F | V |
|---|---|---|---|---|---|---:|---:|
| 2.12.1 SSH targets (host keys, passphrases, Kerberos, FIDO2, port forwarding, remote files/download, relay on Linux without toolchain, sessions across app close) | `src/main/ssh`, `ssh.mdx` | MISSING | No SSH service/OpenSSH target registry/bootstrap/files/credentials path; status chip is visual only. | XL | remote | 0/1 | 0/2 |
| 2.12.2 Remote smthz servers (`serve`, access links, Tailscale, memory limit, remote updates) | `src/main/orcad`, `remote-servers.mdx` | PARTIAL | C/WebSocketTransport.swift and T/WebSocketTransportTests.swift provide loopback framing; TLS/auth policy, remote serving, pairing and relay absent. | XL | remote | 1/5 | 0/2 |
| 2.12.3 Linux execution host build | `ways-to-run.mdx` | MISSING | C/ProcessIdentity.swift imports Darwin/proc_pidinfo; package macOS platform, Network.framework/AppKit dependencies; no Linux host build/portability proof. | L | remote | 0/1 | 0/2 |
| 2.12.4 Ports scanner + forwarding | `src/main/ports`, `workspace-ports*` | VISUAL-ONLY | A/RightSidebar/PortsPanel.swift has no scanner or forwarding backend; browser localhost parsing is not port discovery. | M | remote | 0/2 | 1/2 |
| 2.12.5 Ephemeral VMs / environments / recipes | `src/main/ephemeral-vm`, CLI `environment *` | MISSING | No VM lifecycle/environment/recipe executor; C/SmthzConfig.swift counts recipes for diagnostics only. | XL | remote | 0/3 | 0/2 |
| 2.12.6 Open remote workspace in VS Code | `ssh.mdx` | MISSING | No remote workspace→VS Code launch route. | S | remote | 0/1 | 0/2 |

### 2.13 Skills, plugins, artifacts, profiles

| ID / feature | Orca (R/) | Status | Evidence / remaining checklist | Size | Area | F | V |
|---|---|---|---|---|---|---:|---:|
| 2.13.1 Skills discovery/install/update/rollback, bundled guides (orca-cli, orchestration, computer-use, linear, emulator), MCP servers | `src/main/skills`, `skills/`, `skill-guides/`, `cli/skills.mdx` | MISSING | No skills discovery/install/update/rollback or MCP service in Sources; existing local agent skills are tooling, not product features. | L | library | 0/1 | 0/2 |
| 2.13.2 Skill sharing between hosts / cloud | `skill-cloud*`, `ShareSkillsSettingsPane` | MISSING | Settings share-skills routes placeholder; no own sharing backend. | M | library | 0/1 | 0/2 |
| 2.13.3 Plugins (manifests, panels, workers, catalog) | `src/main/plugins`, `components/plugin-catalog` | MISSING | No plugin manifest/catalog/worker/panel runtime; settings Plugins label only. | XL | library | 0/1 | 0/2 |
| 2.13.4 Artifacts publish/share, own account/profile/org storage | `src/main/artifacts`, `orca-profiles`, `cloud/` | MISSING | No artifact publish/storage/account/profile/org service; browser profiles are unrelated. Own infrastructure absent. | XL | library | 0/1 | 0/2 |

### 2.14 Speech, computer use, emulators

| ID / feature | Orca (R/) | Status | Evidence / remaining checklist | Size | Area | F | V |
|---|---|---|---|---|---|---:|---:|
| 2.14.1 Dictation (local models + hosted transcription) | `src/main/speech`, `components/dictation` | MISSING | No local/hosted dictation model or speech-key provider; Voice settings placeholder. | L | tools | 0/2 | 0/2 |
| 2.14.2 macOS computer use (AX tree, input, screenshots, helper, permissions) | `native/computer-use-macos`, `src/main/computer` | MISSING | No AX/CG computer helper or computer CLI. Audit tooling permissions are not app features. | L | tools | 0/1 | 0/2 |
| 2.14.3 iOS Simulator / Android emulator panes + CLI | `src/main/emulator`, `components/emulator-pane` | MISSING | No simctl/adb execution, emulator pane, or CLI; New Emulator tab disabled. | L | tools | 0/2 | 0/2 |

### 2.15 Updates, distribution, diagnostics

| ID / feature | Orca (R/) | Status | Evidence / remaining checklist | Size | Area | F | V |
|---|---|---|---|---|---|---:|---:|
| 2.15.1 App bundle, icon, bundled host | `electron-builder`, `Casks/` | DONE | scripts/package-app.sh builds ad-hoc app/icon/bundled smthzd; existing packaging runs recorded. Dedicated hook CLI is not bundled. | M | distribution | 1/1 | 2/2 |
| 2.15.2 Signed/notarized build, Homebrew cask | `install.mdx` | MISSING | No stable signing/notarization/cask; ApplicationIdentity bundle id remains dev.smthz.app placeholder. | M | distribution | 0/2 | 0/2 |
| 2.15.3 Auto-update (+ remote host updates) | `src/main/updater` | VISUAL-ONLY | A/SmthzApp.swift Help update alert and Settings Check Now disabled; no update feed/local or remote updater. | M | distribution | 0/2 | 1/2 |
| 2.15.4 Crash reporting, hang watchdog, diagnostics, telemetry + opt-out, privacy pane | `crash-reporting`, `hang-watchdog`, `diagnostics`, `telemetry`, `observability` | VISUAL-ONLY | A/Settings/SettingsPanes.swift stores privacy.shareUsageData but no sender consumes it; no crash reporting/watchdog/diagnostics/telemetry backends. Stored preference earns no functional credit. | L | distribution | 0/5 | 1/2 |
| 2.15.5 Third-party notices | – | DONE | THIRD-PARTY-NOTICES.md exists; no new license validation in this audit. | S | distribution | 1/1 | 0/2 |

### 2.16 Onboarding

| ID / feature | Orca (R/) | Status | Evidence / remaining checklist | Size | Area | F | V |
|---|---|---|---|---|---|---:|---:|
| 2.16.1 Six-step onboarding, skip, reopen | `components/onboarding` | DONE | A/Onboarding/{OnboardingView,OnboardingSteps}.swift + ShellView route: steps/skip/reopen real; prior UI-WIRING records routing. | M | onboarding | 3/3 | 2/2 |
| 2.16.2 Agent/integration steps, setup guide, checklist | `components/setup-guide`, `SettingsSetupGuidePane` | VISUAL-ONLY | A/Onboarding/OnboardingSteps.swift agent detection text and integration buttons remain disabled despite agent backend; Setup Guide route placeholder. No detection/checklist wiring. | S | onboarding | 0/3 | 1/2 |
| 2.16.3 Language step | i18n `src/main/i18n` | DONE | English-only accepted scope; excluded from scoring (no multilingual parity claimed). | D | onboarding | 1/1 | 2/2 |

### 2.17 Keyboard shortcuts and menus

| ID / feature | Orca (R/) | Status | Evidence / remaining checklist | Size | Area | F | V |
|---|---|---|---|---|---|---:|---:|
| 2.17.1 91 keybinding actions | `src/shared/keybindings` | PARTIAL | C/Keybindings.swift: 91 ids, 47 available. Plus six browser actions in A/Browser/BrowserPaneView.swift and three Explorer actions in ExplorerFocusMonitor work despite available:false = 56 source-wired actions; 35 absent. Overrides ignored by browser hard-coded monitor; broad GUI acceptance incomplete. | L | shortcuts | 56/91 | 1/2 |
| 2.17.2 User override file, conflicts, double-tap, keyboard-layout aware matching | `keybinding-file*.ts`, `keybindings-*` tests | PARTIAL | C/KeybindingOverrides.swift + A/Settings/ShortcutsPane.swift: override file and conflict editor real/tested; double-tap modifiers and full layout-aware matching absent. UI-WIRING records file edit changes menu; recorder/reset GUI pending. | M | shortcuts | 2/4 | 1/2 |
| 2.17.3 App menus (File/Edit/Appearance/View/Help, Check for Updates, Report Crash, Force Reload) | `src/main/menu` | PARTIAL | A/SmthzApp.swift real File/View/Tabs/Terminal menus and observation Force Reload; Check Updates/Report Crash alerts are stubs; independent New Window missing. Existing native Edit commands retained. | M | shortcuts | 4/7 | 1/2 |

### 2.18 Persistence and recovery

| ID / feature | Orca (R/) | Status | Evidence / remaining checklist | Size | Area | F | V |
|---|---|---|---|---|---|---:|---:|
| 2.18.1 Shell layout/tab state, pending-create idempotency | `src/main/persistence`, `model/session-restore.mdx` | DONE | C/ShellStateStore.swift + A/ShellController.swift persist layout and pending-create IDs; T/ShellStateStoreTests.swift. Browser tabs excluded by BrowserTabModel design. | L | persistence | 2/2 | 0/2 |
| 2.18.2 Host journal, idempotent RPC, capability token | `runtime/rpc` | PARTIAL | C/EventJournal.swift + HostService.swift journal/capability auth tested; handshake/request.cancel outside durable idempotency. T/RPCHardeningTests.swift. | M | persistence | 2/3 | 0/2 |
| 2.18.3 Projects/worktrees/settings persistence, backup, profile state rollback/exports | `persistence`, `profile state *` | PARTIAL | C/WorkspaceStore.swift + WorkspaceStore+Repos.swift + worktrees persist projects/worktrees/host settings; corruption backup exists in ShellStateStore, but coordinated backup/profile exports/rollback CLI absent. T/WorkspaceStoreTests.swift + RepoRegistryTests.storeSurvivesHostRestartAndReadsAreNotJournaled. | M | persistence | 3/6 | 0/2 |
| 2.18.4 Durable file write / transaction lock | `durable-file-write.ts`, `file-transaction-lock.ts` | PARTIAL | FileOperations exclusive non-clobber ops and HostRepoGate serialize mutations; no editor writeIfUnchanged/durable file transaction service (fs.read/write unregistered). | M | persistence | 1/2 | 0/2 |

### 2.19 Performance

| ID / feature | Orca (R/) | Status | Evidence / remaining checklist | Size | Area | F | V |
|---|---|---|---|---|---|---:|---:|
| 2.19.1 Performance baseline, benchmarks and soak | src/main/diagnostics; docs/site/content/docs | MISSING | No Orca baseline or comparable smthz benchmark/soak artifact; streaming is a real change, not performance proof. | L | performance | 0/1 | 0/2 |

## 3. Percentage estimate

Measured **inventory coverage**, using the explicit method in §1; no judgment multiplier for PARTIAL status. Functional fractions and visual gates remain visible row by row. The machine file rounds each area's result to two decimals; weighted overall means below use those same rounded area values.

| Area id / name | Weight | Functional | Visual | Existing issues |
|---|---:|---:|---:|---|
| terminal — Terminal, panes and tabs | 42 | 76.59% | 60.71% | #1, #2, #13, #26, #30, #31 |
| windows — Windows and floating surfaces | 8 | 0.00% | 12.50% | #16, #22, #31 |
| projects — Projects and worktrees | 28 | 77.62% | 50.00% | #31 |
| git — Git and source control | 11 | 66.02% | 63.64% | #3, #31 |
| files — Explorer, search and file opening | 9 | 85.80% | 55.56% | #1, #16, #31 |
| editor — Editor, markdown, viewers and diffs | 24 | 3.33% | 0.00% | #1, #2, #3 |
| agents — Agent roster, launch and lifecycle | 18 | 46.30% | 55.56% | #31 |
| chat — Structured agent chat | 8 | 12.50% | 50.00% | #4, #5, #6, #7 |
| accounts — Agent accounts and usage | 6 | 0.00% | 0.00% | #8 |
| history — Session history and memory | 6 | 16.67% | 33.33% | #7, #9 |
| browser — Browser pane and automation | 24 | 52.82% | 54.17% | #10, #11, #12, #13, #31 |
| orchestration — Orchestration runtime | 22 | 23.03% | 0.00% | #14 |
| cli — CLI and RPC delivery surfaces | 54 | 20.72% | 0.00% | #14, #15, #16, #17, #19, #20, #21, #23, #25, #26, #27, #28 |
| automations — Scheduled automations | 5 | 0.00% | 40.00% | #15 |
| integrations — Providers, tasks and checks | 22 | 0.00% | 9.09% | #19, #20 |
| settings — Settings panes and search | 40 | 14.51% | 17.50% | #24, #31 |
| attention — Notifications, activity and engagement | 9 | 31.85% | 27.78% | #31 |
| mobile — Mobile companion | 8 | 0.00% | 50.00% | #17, #32 |
| remote — SSH, remote hosts, ports and VMs | 35 | 4.57% | 2.86% | #16, #17, #18 |
| library — Skills, plugins, artifacts and sharing | 22 | 0.00% | 0.00% | #21 |
| tools — Speech, computer use and emulators | 12 | 0.00% | 0.00% | #25, #26, #27 |
| distribution — Packaging, updates and diagnostics | 12 | 25.00% | 45.83% | #28 |
| onboarding — Onboarding and setup guide | 3 | 66.67% | 83.33% | #19, #20, #31 |
| shortcuts — Shortcuts and menus | 8 | 57.55% | 50.00% | #24, #31 |
| persistence — Persistence, recovery and backup | 16 | 45.83% | 0.00% | #1, #23 |
| performance — Performance baseline and soak | 4 | 0.00% | 0.00% | #29 |
| **Overall** | **456** | **29.86%** | **24.56%** | Existing/proposed issue coverage: PARITY-ISSUES.md |

Visual coverage includes missing/backend surfaces with zero credit under the required common weights. A main window that resembles Orca cannot compensate for absent editor, provider, remote and library surfaces. Functional APIs and standalone transcript/Codex components receive only the checklist credit shown; they do not imply reachable native chat.

The largest uncovered weighted functional areas are **CLI 42.81 units**, **Settings 34.20**, **Remote 33.40**, **Editor 23.20**, **Integrations 22.00**; **Library also 22.00** (tie). These rank remaining inventory weight, not elapsed-time predictions.

## 4. Gap list as work packages

Completed foundations are **not** new backlog: H5 streaming, A3 group/reopen core+UI, A5 full metadata/override integration, M4 host registry/worktree/config/hooks, SC writes, file mutation/search, AG roster/launch/status/live UI, B1/B2/B3/B4 browser slices, CHAT0 decoders/standalone view, CHAT1 Codex core, orchestration store/CLI and first attention/settings slices. The rows below describe only residual delivery. Nxx ids are **proposed issues**, not live GitHub numbers; see PARITY-ISSUES.md.

| Work package | Remaining result | Area(s) | Existing/proposed issue | Size | Dependency / decision |
|---|---|---|---|---|---|
| TERMINAL-REMAINDER | Shell readiness/history, theme imports, full link/native-key routing | terminal | N09 | M | editor/browser routes |
| TERMINAL-CONFORMANCE | Real IME/ZWJ/mouse/reflow/VoiceOver/light; Copy Context/input-source/settings GUI; replay size | terminal,persistence | #30, #31 | M | real unlocked desktop |
| WINDOWS | Independent windows/dashboard popout, floating/standalone terminals, restore ownership | windows | #22 | L | D3 |
| PROJECTS-UX | Groups/order/filter/history/Jump/parent/checkpoint UI; cleanup blockers; setup-session adoption | projects | N01, #31 | M | existing host catalog |
| GIT-REMAINDER | Base compare/rename, squash, AI commit generation and attribution | git | N02 | L | agent transport for AI |
| FILES-UX | External editor routing, Open in Terminal, native editor handoff | files | N03, #16, #31 | S | editor; remote downloads via SSH |
| EDITOR | Monaco decision + E0–E7; registered fs.read/write; conflict-safe durable edits | editor,files,persistence | #1 | XL | owner engine acceptance |
| VIEWERS | Markdown editing and HTML/Mermaid/PDF/image/CSV/notebook viewers | editor | #2 | L | EDITOR |
| DIFF | Single/combined diff, review notes/comments/annotations | editor,git | #3 | L | EDITOR |
| AGENT-LAUNCH-FINISH | Dedicated packaged hook CLI, launch defaults/setup policy/trust, real-provider conformance | agents | N04 | M | U-B2 for global changes |
| AGENT-LIFECYCLE | Dashboard, hibernation/resume, awake, durable restart context | agents | N05 | L | RECOVERY |
| AGENT-TEAMS | Child roster/team/handoff and generated titles/text | agents | N06 | L | provider accounts/control |
| CHAT-WIRE | Reachable PTY transcript toggle, transcript discovery/decoder completeness, composer | chat,history | #7 | M | AGENT-LAUNCH-FINISH |
| CHAT-CODEX | Use tested Codex client for streaming/composer/approvals/interrupt/resume UI | chat | #4 | L | CHAT-WIRE; real 0.164.x conformance |
| CHAT-CLAUDE | Chosen Claude transport + control requests and structured UI | chat | #5 | L | U-B3 |
| CHAT-ACP | Generic ACP transport/version gate/UI | chat | #6 | L | chat surface |
| ACCOUNTS | Keychain accounts/hot-swap/usage/rate-limit/cost | accounts | #8 | L | credentials; meters decision |
| HISTORY | Session catalog/FTS/search/resume and memory files | history | #9 | L | existing transcript reader |
| BROWSER-MODEL | Persist browser kinds/URLs/profiles in ShellModel, splits, scoped worktrees/links | browser | #13 | L | state schema migration |
| BROWSER-PROFILES | Profile/import UI, real import fixtures/permissions, jar semantics/deferred cleanup | browser | #11 | M | U-B1; real Keychain/FDA checks |
| BROWSER-REDUCTIONS | Resolve R-B1..B12, remaining RPCs, page errors/limits; acceptance or implementation | browser,cli | #10 | L | owner reduction decisions |
| BROWSER-DESIGN | Grab/highlight/annotation and captured element→agent attachment | browser | #12 | L | chat attachments |
| ORCH-WORKERS | Spawn/control/observe/inject workers, coordinator, request receipts, federation and UI | orchestration | #14 | XL | agents; remote authority for federation |
| AUTOMATIONS | Schedules/timezones/prechecks/history/reuse/host targets + CLI/page/settings | automations,cli | #15 | L | agents; orchestration |
| SSH-LINUX | SSH target/bootstrap/host keys/remote files/Linux host + CLI | remote,files,cli | #16 | XL | Linux portability |
| REMOTE-AUTH | Own authenticated TLS host/pairing/access links/revocation/relay | remote,mobile | #17 | XL | own infra and credentials |
| PORTS | Scan/probe/kill/forward and actual Ports UI | remote | #18 | M | SSH for remote forwarding |
| VM-ENVIRONMENTS | VM environments/recipes/provisioning/recovery/doctor + CLI | remote | N12 | XL | provider/infra decision |
| PROVIDERS-GIT | GitHub/GitLab/Gitea/Bitbucket/Azure PR/issues/checks/tasks | integrations,cli | #19 | XL | OAuth/token strategy |
| PROVIDERS-ISSUES | Linear/Jira tasks and command/write surfaces | integrations,cli | #20 | L | OAuth/token strategy |
| LIBRARY | Own skills/MCP/sharing/plugins/artifacts/profile storage services and UI | library,cli | #21 | XL | Node gate; own infra |
| SETTINGS | 29 placeholder panes, partial existing panes, full control/value search | settings | #24 | L | backends per pane |
| KEYS-REMAINDER | 35 absent action paths, availability reconciliation, browser overrides, layout/double-tap/menu parity | shortcuts | N07, #24 | M | feature backends |
| ATTENTION | Activity route/bell/tuning/test/tray; Focus/audio/Dock/persistence acceptance | attention | N10, #31 | M | real notification permissions |
| ENGAGEMENT | Pet/stats/tips/wall/tours; decide star/social/feedback destinations | attention | N11 | L | owner content decisions |
| ONBOARDING | Live agent/default/provider/setup-guide steps | onboarding | N13 | S | provider setup as available |
| SPEECH | Local and hosted dictation + key CLI/settings | tools,cli | #27 | L | hosted key decision |
| COMPUTER | AX/CG helper, input/screenshot/permissions/CLI | tools,cli | #25 | L | stable signing/TCC |
| EMULATORS | simctl/adb panes and CLI | tools,cli | #26 | L | simulators/adb |
| RECOVERY | Host restart policy/session restore, handshake/cancel semantics, launchd | persistence | #23 | L | D2/D12/D4 |
| PERSISTENCE | Coordinated own-state backup/export/rollback; corruption/restart migration | persistence | N14 | M | schema boundaries; no Orca state import |
| CLI-REMAINDER | Local command gaps, meaningful --help and complete flags/JSON/errors; map all 287 paths | cli | N08 + backend issues | L | each corresponding backend |
| DISTRIBUTION | Bundle id/sign/notarize/cask/update/diagnostics/telemetry consent/CLI registration | distribution | #28 | L | signing account/endpoints |
| PERF | Orca baseline, then comparison and soak; no invented budgets | performance | #29 | L | stable reproducible workload |
| GUI-VERIFY | Run the recorded unverified menus/drags/forms/settings/relaunch workflows | all GUI areas | #31 | M | unlocked desktop/private state |
| MOBILE | Companion/mobile client after own access/relay services | mobile | #32 | XL | accepted deferral; REMOTE-AUTH |

Open decisions/resources: D2/D12 host restart and D3 independent-window ownership; U-B1 browser reductions **R-B1..B12** (including Safari inspector, cookie-only clone, no CDP exec and remote browser limits); U-B2 global agent config/trust versus per-launch flags; U-B3 Claude control transport; editor engine acceptance; provider usage meters; plugin Node adapter; own auth/relay/artifact/storage infrastructure; OAuth/token strategies; bundle id/signing identity; distribution/update/diagnostic endpoints; social/star/feedback behavior. `smthz.yaml` with `orca.yaml` fallback is already implemented, so the old filename decision is no longer a missing implementation. No xcode-select change is needed to audit or build with DEVELOPER_DIR.

## 5. Known defects and risks

| Finding | Current code / evidence | Status / owner |
|---|---|---|
| Bundled hook command targets GUI executable | scripts/package-app.sh copies SmthzApp to Contents/MacOS/smthz and smthzd beside it; C/Agents/AgentLaunch.swift defaults hooks to sibling smthz; no dedicated CLI is built/copied | Static wiring defect; standalone host+CLI works, packaged hook not exercised. N04 |
| Agent default preference is inert | SettingsPanes writes agents.defaultAgent; launch callers build an explicit AgentLaunchRequest and never read it | Open; N04 |
| Agent restart loses launch detail across app relaunch | A/Agents/AgentStatusModel.swift launches dict is memory-only; fallback preserves agent/cwd but not original prompt/args/permission | Open; N05 |
| Shortcut availability diverges from dispatch | 47 available; BrowserKeyRouter implements six unavailable ids with hard-coded chords; ExplorerFocusMonitor handles three more without checking available | Open; editor dimming/overrides inaccurate for those paths. N07 |
| Cleanup omits active-workspace blocker | CleanupRPC accepts activeWorktreeId; WorkspaceCleanupView does not pass it. Agent/editor/SSH blockers also not integrated | Open; N01; no destructive cleanup was run here |
| Setup terminal may be adopted into Default | A/Workspaces/WorktreeLifecycleModel.swift job completion versus A/ShellController.swift reconciliation; UI-WIRING WORKTREE-APP records the race | Open; N01 + #31 |
| Browser state/target scoping missing | BrowserTabStore app-global, nonpersistent and outside ShellModel; BrowserAutomation.resolve does not apply worktree target | Open; #13 |
| Profile lifetime and clone gap | BrowserAutomation.close detaches; ordinary BrowserTabStore/UI close does not. Deferred removal after UI close unverified; clone copies cookies only, no localStorage/IndexedDB/cache | Open; #11, #10; R-B10 implementation is narrower than experiment wording |
| Browser transport payload ceiling | Provider replies share framed RPC cap; screenshot/PDF base64 can exceed 1 MiB; no chunked transfer | Open; #10. B4 local fixture passing does not prove large pages |
| Browser public-API reductions remain | Trusted pointer input only for visible active tab; DOM snapshot, network/interception/headers/device/offline/media differ; exec unsupported; no remote host browser | #10, #12, #13, #16; owner acceptance required |
| Transcript and Codex core unreachable in product | ChatTranscriptEntryView and CodexAppServerClient have no app caller; transcript decoder omissions (Claude patches/pasted/images; Codex filtering differs) | #7, #4, #5, #6; fake Codex process only, no live model turn |
| Activity feed unreachable; stale notification copy | AttentionFeed has no caller; .activity = Mobile. NotificationsSettingsPane says delivery unavailable while AttentionModel schedules it; terminalBell unused | N10, #24; delivery/audio/Dock/persistence GUI unverified |
| Host reconnect | T/HostMonitorTests.monitorRecoversAcrossRealHostRestartAndTokenRotation tests real respawn/token rotation; current HostClient reconnects | Core regression fixed; no fresh auto-spawned app reconnect proof in this audit. #31 |
| Host restart ends processes; handshake/cancel semantics incomplete | smthzd closes sessions; HostService handshake/request.cancel bypass durable mutation journal | #23; D2/D12 policy still open |
| Replay at a different grid size | TERMINAL-BEHAVIOR P3 remains; T1 confirms same-size replay/response suppression, not all live-TUI/query states | #30 |
| Close immediately after launch | Earlier UI-WIRING startup/foreground-command confirmation race lacks a later explicit close-path acceptance record | Unverified residual; #31 |
| Concurrent full-suite flakes | Earlier SessionStream/.closed, PTY fd-count, descriptor durability and quiet-paste failures captured in wave ledgers; latest CHAT1 reports 661 tests ×5 green | Not reproduced here; retain logs if recurrence. No current failure claimed |
| Verification boundaries | IME/ZWJ/light/VoiceOver, groups drag, worktree composer/pwd/relaunch, file ops/search/palette, newer settings, notification delivery, real provider hooks and real Codex app-server are not all verified | #30/#31 and feature issues; current code is not GUI proof |
| Performance/distribution | No Orca baseline, stable identity/signature or update services; ad-hoc app packaging is real | #29, #28; streaming removes polling risk, does not supply measured latency |
| Earlier cosmetic/hygiene notes | CLI exit formatting now uses HostSessionExit.displayDescription; stub removed; prior hygiene docs report warnings addressed. Icon bust difference was not visually rechecked | Do not reopen resolved cleanup from stale text; remaining packaging/GUI review stays #28/#31 |

## 6. Recommended milestone order to 100%

1. **Close integration defects and verification gaps:** AGENT-LAUNCH-FINISH (packaged hook CLI/defaults), PROJECTS-UX (cleanup/adoption), KEYS-REMAINDER (browser override/availability), ATTENTION routing, BROWSER-MODEL/profile lifecycle. Run the existing real-app backlog on an unlocked desktop; preserve full logs.
2. **Complete the local developer loop:** owner editor-engine decision, EDITOR → VIEWERS/DIFF, GIT-REMAINDER and FILES-UX. Existing file/Git/worktree cores are foundations, not work to rebuild.
3. **Finish usable agent chat:** CHAT-WIRE and CHAT-CODEX around the tested components, then U-B3/CHAT-CLAUDE and CHAT-ACP; add HISTORY/ACCOUNTS, lifecycle/teams.
4. **Deliver orchestration runtime and automation:** worker spawning/control/observation and coordinator/federation after the store, then scheduler/prechecks/history/page. Complete CLI contracts alongside each backend.
5. **Finish browser behavior:** persistent scoped browser tabs/profiles, import wiring, resolve/accept public-WebKit reductions and implement design attachments after chat. Re-run browser fixture E2E with visible pages, large payloads, HTTPS and lifecycle checks.
6. **Remote execution:** SSH/Linux first, then authenticated own TLS/pairing/relay, remote ports/browser and VM environments. Infrastructure decisions remain explicit prerequisites.
7. **Providers and library:** all Git providers plus Linear/Jira task/check surfaces; own skills/MCP/sharing/plugins/artifacts/storage.
8. **Settings and remaining tools:** complete panes as each backend ships; onboarding/attention/engagement, speech/computer/emulators, persistence backup/exports and remaining menus/CLI.
9. **Distribution and measurement:** owner identity/sign/notarize/update/diagnostics decisions; establish Orca baseline before smthz comparisons, soak, and re-audit all checklists.

### First 10 work packages (ready to scope)

1. **N04 / AGENT-LAUNCH-FINISH:** dedicated hook CLI packaging and packaged fake-agent E2E; consume default agent/setup policy. Seek decisions only for actual global-config behavior.
2. **N01 / PROJECTS-UX:** pass active workspace into cleanup, fix setup-session adoption, then complete bounded group/navigation/checkpoint slices.
3. **N07 / KEYS-REMAINDER:** reconcile nine availability exceptions and route browser bindings through the effective registry; test override/menu/native-field behavior.
4. **N10 / ATTENTION:** add a dedicated Activity route, wire/test bell and Send Test, correct stale delivery text; real notification/Dock/relaunch acceptance.
5. **#13 / BROWSER-MODEL:** persist browser tab identity/URL/profile and integrate workspace/split selection without losing website stores.
6. **#11 / BROWSER-PROFILES:** fix UI-close detach/deferred cleanup, then connect profile and cookie-import UI; real-user data access only under a separately authorized test.
7. **#1 / EDITOR:** settle the documented engine gate, deliver durable read/write/editor slice, then viewers/diff.
8. **#7 + #4 / CHAT-WIRE/CODEX:** make transcript and tested Codex client reachable; composer/approval/interrupt/resume acceptance, without treating fake protocol tests as a live-provider run.
9. **#14 / ORCH-WORKERS:** bounded local supervised worker lifecycle before federation; preserve dispatch identity and ownership in real-process tests.
10. **#31 + #30 / GUI-VERIFY:** execute the exact pending checklist in UI-WIRING/TERMINAL-CONFORMANCE, recording what was seen and what remains; rerun full suites only when code changes or failures justify it.

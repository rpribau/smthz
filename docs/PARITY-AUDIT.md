# PARITY-AUDIT — what smthz still lacks to replicate Orca 1.4.238

Date: 2026-10-31. Author: worker `task_7e8528dc69b2` (research only; no code, build, test or app launch). Reference: `reference/orca-1.4.238` (abbreviated `R/`). smthz paths are relative to the repo root.

## 1. Method

| Step | What was done |
|---|---|
| Orca inventory | Enumerated `R/src/main/*` (≈110 service dirs), `R/src/renderer/src/components/*` (≈70 feature dirs), CLI specs `R/src/cli/specs/*` (**287 command paths**, grep of `path: [...]`), RPC methods `R/src/main/runtime/rpc/methods` (311 non-test files; ≥93 literal `method:` names, an undercount), keybinding registry `R/src/shared/keybindings/definitions-core-*.ts` (**91 actions**), settings panes `R/src/renderer/src/components/settings/*Pane.tsx` (**38 panes**), app menu `R/src/main/menu/register-app-menu.ts`, agent roster `R/src/shared/tui-agent.ts` (**47 agent ids**), and every heading of the user docs `R/docs/site/content/docs/**/*.mdx`. |
| smthz inventory | Listed all 96 Swift files (16,177 lines). Grepped host RPC switch (`HostService.swift`: 12 methods + `handshake` + `request.cancel`), CLI switch (`Sources/smthz/main.swift`: `ping run sessions write read kill attach` + `--version/--help/paths`), settings router (`SettingsView.swift:80-82`), keybinding registry (`Keybindings.swift`, 37 action ids), Git API (`GitService.swift`), file-write calls in Explorer, `VISUAL-ONLY` markers (31 files). |
| Docs cross-check | AGENTS.md, ROADMAP, PARITY, DESIGN, M3-PLAN, UI-SPEC/GAP/GAP2, UI-WIRING, HANDOFF read; claims spot-checked by grep (see §1.1). |
| Status rules | **DONE-real**: code path exists and reaches a real backend (host RPC, FileManager, git, UserDefaults) *and* AGENTS/UI-WIRING record a coordinator or worker run. **DONE-visual-only**: UI exists, backend stub/disabled (`VISUAL-ONLY`, disabled controls, "unavailable" toast). **PARTIAL**: some real behaviour, known missing sub-features. **MISSING**: no code. "unverified" = code exists but no recorded run. Nothing here was executed by this audit. |
| Size | S ≤ 1 worker-day, M 2–4 days, L 1–2 weeks, XL > 2 weeks (one Codex worker, including tests/verification). |
| Flags | **U** user decision, **I** external infra/accounts/credentials, **S** signing/notarization, **R** possible functional reduction (needs user acceptance), **D** deferred by already-agreed scope. |

### 1.1 Doc claims that did not match the code

- `Keybindings.swift` registry (37 of 91 actions) is only consumed by `LandingView.swift` for keycap display; real shortcuts are hard-coded SwiftUI `.keyboardShortcut` in `SmthzApp.swift`. No user override file is read (D8 not implemented).
- `tabReopenClosed` exists in the registry but nothing in `Sources/SmthzApp` handles it.
- Tab groups exist in `ShellModel.swift` (49 "group" refs) but `TabStripView.swift` has none: no group UI (A3 pending).
- Explorer is read-only (no `removeItem/moveItem/createFile/trashItem` in `ExplorerPanel.swift`); Source Control stage/unstage buttons are `enabled: false`.
- Terminal output is **polled** (`session.read`, `TerminalSessionView.swift:208`), not streamed; Orca pushes PTY data.
- `docs/ROADMAP.md` "Execution ownership" (Hermes only) and "Full Xcode is not installed" are stale vs AGENTS.md.
- Only `terminal` and `appearance` settings pages have bodies; every other sidebar entry routes to `SettingsUnavailableBody` (`SettingsView.swift:82`).

## 2. Feature inventory

Legend: status / size / flags. Evidence is a smthz file or the reason.

### 2.1 Terminal, panes, tabs, workspaces, windows

| Feature | Orca (R/) | smthz | Evidence | Size | Deps | Flags |
|---|---|---|---|---|---|---|
| Persistent PTY owner (daemon) | `src/main/daemon`, `src/main/pty` | DONE-real | `PTYSession.swift`, `SessionManager.swift`, `smthzd` | – | – | – |
| Sessions outlive UI / app quit | `docs/.../model/session-restore.mdx` | DONE-real | AGENTS A0/A1 e2e | – | – | – |
| Sessions after **host** restart (cold restore, respawn shells, scrollback) | `src/main/daemon`, `serve restore resume` | MISSING | D2/D12 open; children die with host | M | H2 | U (D2) |
| Host as launchd service | `macos-daemon-launchd.ts`, `serve service install` | MISSING (posix_spawn, D4 accepted until M11) | `HostLauncher.swift` | M | – | D |
| Emulation engine | xterm.js in `components/terminal-pane` | PARTIAL | SwiftTerm 1.99.1; alt screen, mouse modes, true colour, IME, Unicode width unverified | M | – | – |
| Output transport | push stream over IPC | PARTIAL (polling) | `TerminalSessionView.swift:208` | M | host RPC | – |
| OSC title / cwd | terminal-pane | DONE-real | `setTerminalTitle`, `hostCurrentDirectoryUpdate` | – | – | – |
| OSC 52 clipboard | `terminal.mdx#TUI clipboard` | PARTIAL, unverified | `clipboardCopy` delegate | S | – | – |
| Link actions (URLs, file paths → editor/browser, modifier routing) | `components/link-actions`, `BrowserTerminalLinkActionsSetting` | PARTIAL | URL open only (`requestOpenLink`) | M | editor, browser | – |
| Find in terminal | `terminal.search` | DONE-real | `TerminalFindBar.swift` | – | – | – |
| Copy terminal context | `terminal.mdx#Copy terminal context` | MISSING | – | S | – | – |
| Themes / Ghostty import / Warp import | `src/main/ghostty`, `src/main/warp-themes`, `GhosttyImportModal` | PARTIAL (built-in palette) / MISSING imports | `TerminalTheme.swift` | M | – | – |
| Shell integration, readiness, history (bash/zsh/fish) | `bash-prompt-command-composition.ts`, `fish-history*`, `runtime/terminal` | MISSING | `SessionEnvironment.swift` sets env only | M | – | – |
| Switch input source, native key bindings | `terminal.switchInputSource`, `terminal.mdx#Native key bindings` | MISSING | – | S | – | – |
| Tabs: create/close/rename/colour/pin/reorder/Ctrl-1…9/Ctrl-Tab | `components/tab-bar` | DONE-real | UI-WIRING rows 21–34 | – | – | – |
| Reopen closed tab, close all, next/prev same type | `tab.reopenClosed` etc. | PARTIAL | registry only, not wired | S | A5 | – |
| Non-terminal tab types (agent, browser, simulator, markdown) | `tab.newAgent/newBrowser/newSimulator/newMarkdown` | DONE-visual-only | disabled rows in `+` menu | – | M4/M5/M6/M10 | – |
| Pane splits, focus, equalize, expand | `model/tabs-panes-splits.mdx` | DONE-real | `LayoutSplitView.swift`, `TerminalPaneHost.swift` (A2) | – | – | – |
| Tab groups (incl. across worktrees, pinned boundaries) | `components/tab-group` | PARTIAL (core only) | `ShellModel.swift`; no UI | M | – | – |
| Multiple workspaces in sidebar | `components/sidebar` | PARTIAL | one "Default" card (`WorkspaceCardView.swift`) | M | M4 projects | – |
| Multiple windows, dashboard popout | `src/main/window`, `components/dashboard-popout` | MISSING | single `WindowGroup` | M | A4 | U (D3) |
| Floating terminal / floating workspace (max/min) | `components/floating-terminal`, `FloatingWorkspacePane` | DONE-visual-only (status chip) | `StatusBarView.swift:137` | M | A7 | – |
| Standalone terminal, plain SSH terminal | `components/standalone-terminal`, `plain-ssh-terminal` | MISSING | – | M | SSH | – |
| Resource Manager (memory, end, go-to, cleanup) | `terminal.mdx#Resource Manager`, `workspace-cleanup` | PARTIAL | `ResourceManagerPopover.swift`; no worktree cleanup | S | M4 | – |
| Close confirmations | `components/terminal-pane` dialogs | DONE-real | `Dialogs/*` | – | – | – |
| Quick commands | `components/terminal-quick-commands`, `QuickCommandsPane` | DONE-real (save/run round trip unverified) | `Tabs/QuickCommand*` | S | – | – |
| Windows shell, admin mode, WSL | `src/main/wsl`, `src/wsl-guest`, `windows` | MISSING | out of scope | – | – | D |

### 2.2 Projects, worktrees, Git

| Feature | Orca (R/) | smthz | Evidence | Size | Deps | Flags |
|---|---|---|---|---|---|---|
| Project/repo registry (add, list, set, folders, persistence) | `src/main/ipc/repos`, CLI `repo *`, `project *` | DONE-visual-only | `AddProjectDialog.swift` picker shows path only | M | host SQLite | – |
| Clone / create / SSH project | `project setup-clone/-create` | DONE-visual-only | disabled choices | M | SSH for remote | – |
| Worktree create (background, start-from picker, branch naming, emoji names, parent/child lineage) | `src/main/ipc/worktrees`, `model/worktrees.mdx`, `worktree-creation`, `workspace-emoji` | PARTIAL (core primitive only) | `GitService.addWorktree/removeWorktree`; composer creates a plain shell | L | registry | – |
| `orca.yaml` (setup/archive/commands/terminal defaults/issue commands) | `model/orca-yaml.mdx` | MISSING | – | M | worktree create | – |
| `.worktreeinclude`, shared dirs, sparse checkout | `components/sparse`, `src/shared/new-workspace` | MISSING | – | M | worktree create | – |
| Setup/archive hooks, per-repo hooks | `agents/hooks-memory.mdx` | MISSING | – | M | orca.yaml | – |
| Workspace delete/archive, preserved branches, cleanup | `workspace-cleanup` | DONE-visual-only | `DeleteWorkspaceDialog.swift` toast only | M | registry | – |
| Multi-repo project groups, folder workspaces | `src/main/project-groups` | MISSING | – | M | registry | – |
| Hibernation / sleeping workspaces | `agents/hibernation.mdx` | MISSING | disabled menu item | M | agents | – |
| Base ref, compare against upstream, keep main up to date, auto-rename branch | `GitPane`, `BaseRefPicker` | MISSING | – | M | – | – |
| Workspace sort/group/filter | sidebar options | PARTIAL | `WorkspaceOptionsMenu.swift` prefs, no multi-workspace effect | S | registry | – |
| Worktree history back/forward, navigate up/down, jump palette | `worktree.history.*`, `cmd-j` | PARTIAL | Jump palette real for sessions; no projects/tasks rows | S | registry | – |
| Unread/pin/mark read workspace | sidebar | PARTIAL (window-local, not persisted) | UI-WIRING row 59 | S | registry | – |
| Workspace checkpoints (card status from agents) | `cli/worktree-checkpoints.mdx` | MISSING | – | S | CLI | – |

### 2.3 Files, editor, diffs, Source Control, Checks

| Feature | Orca (R/) | smthz | Evidence | Size | Deps | Flags |
|---|---|---|---|---|---|---|
| File explorer browse | `editing/file-explorer.mdx` | DONE-real | `ExplorerPanel.swift` | – | – | – |
| Explorer ops (create, rename, delete, undo/redo, copy path, drag-drop, git decorations, download remote) | `fileExplorer.*` keybindings | MISSING | no write calls in `ExplorerPanel.swift` | M | – | – |
| Folder search (ripgrep) | `src/main/ripgrep`, `sidebar.search.toggle` | MISSING | – | M | rg | – |
| Go to File (Cmd-P) | `model/quick-open.mdx` | PARTIAL | listing real, open = toast (`GoToFilePalette.swift`) | S | editor | – |
| Code editor (autosave, multicursor, go-to, find/replace, minimap, word wrap, font, languages, conflict-safe writes) | `components/editor`, `editing/monaco.mdx`, `file-write-disk-precondition.ts` | MISSING | engine undecided (M1) | XL | M1 experiment | U, R? |
| Markdown editor (slash menu, links, TOC, front matter, tables, review annotations) | `editing/markdown.mdx` | MISSING | – | L | editor | – |
| Viewers: HTML, Mermaid, PDF, images, CSV/TSV, Jupyter | `editing/viewers.mdx`, `src/main/notebook` | MISSING | – | L | WebKit/PDFKit | – |
| Source Control status | `src/main/source-control` | DONE-real (read-only) | `SourceControlPanel.swift` | – | – | – |
| Stage/unstage/discard/commit/amend/push, AI commit message | `review/commit-push.mdx`, `CommitMessageAiPane` | MISSING (buttons disabled) | `SourceControlPanel.swift:153` | L | GitService writes; AI via agents | – |
| Diff viewer (combined diff, file tree, word wrap, whitespace, collapse unchanged) | `review/diff-viewer.mdx`, `editor/combined-diff` | MISSING (core `GitService.diff` only) | – | L | editor | – |
| Diff comments, annotate AI diff, send review notes to agent | `components/diff-comments`, `review/annotate-ai-diff.mdx` | MISSING | – | L | diff, agents | – |
| Conflicts / rebase / squash | `squash.*` RPC | MISSING | – | M | SC | – |
| Attribution of AI changes | `review/attribution.mdx` | MISSING | – | M | agents | – |
| Checks panel (CI) | `components/right-sidebar` | DONE-visual-only | `ChecksPanel.swift` | M | GitHub | I |
| Open in external editor (VS Code etc.) | `external-editor-launch.ts` | MISSING | – | S | – | – |

### 2.4 Agents

| Feature | Orca (R/) | smthz | Evidence | Size | Deps | Flags |
|---|---|---|---|---|---|---|
| Roster/detection of 47 TUI agents, CLI version probe | `src/shared/tui-agent.ts`, `agent-cli-version-probe.ts` | MISSING | – | M | – | – |
| Launch agent in tab with defaults/env/permissions/trust | `src/main/agent-launch`, `agent-trust-presets.ts`, `AgentsPane` | MISSING | – | L | roster, worktrees | – |
| Status hooks, state indicators, restart chip | `src/main/agent-hooks`, `model/agents-sessions.mdx` | MISSING | `AgentsPanel.swift` visual only | L | launch | – |
| Agent dashboard | `components/dashboard` | MISSING | – | M | hooks | – |
| Native structured chat (Claude, Codex, ACP; composer, questions, permissions, attachments, forks) | `src/main/native-chat`, `src/main/acp`, `agents/native-chat.mdx` | MISSING | – | XL | M1 control-path experiment | U, R? |
| Accounts + hot-swap (Claude, Codex, Cursor, Grok, Antigravity, MiniMax, OpenCode…) | `claude-accounts`, `codex-accounts`, `cursor-accounts`, `grok-accounts`, `AccountsPane` | MISSING | – | L | keychain | – |
| Usage / rate limits / estimated cost | `claude-usage`, `codex-usage`, `opencode-usage`, `muse-usage`, `rate-limits`, `stats` | MISSING | – | M | accounts | U (meters hidden?) |
| Session history / AI vault FTS search, resume | `ai-vault`, `ai-vault-search`, `agents/session-history.mdx` | MISSING | settings label only | L | – | – |
| Memory files | `src/main/memory` | MISSING | – | M | – | – |
| Subagents / teams, hand-off between agents | `claude-teams`, `agents/codex.mdx` | MISSING | – | M | launch | – |
| Agent awake (prevent sleep) | `agent-awake-service.ts` | MISSING | – | S | hooks | – |
| Generated tab titles, text generation | `src/main/text-generation` | MISSING | – | S | accounts | – |

### 2.5 Browser (WebKit)

| Feature | Orca (R/) | smthz | Evidence | Size | Deps | Flags |
|---|---|---|---|---|---|---|
| Browser pane: tabs, address bar, back/forward/reload, find, zoom, home page, search engine | `components/browser-pane`, `browser/overview.mdx` | MISSING | – | L | M1 WebKit gate | – |
| Worktree-scoped sessions, localhost labels, link routing | `BrowserLocalhostWorktreeLabelsSetting` | MISSING | – | M | ports, workspaces | – |
| Profiles, identity, cookie import, Google sign-in | `browser/profiles.mdx` | MISSING | – | L | WKWebsiteDataStore | R (Chromium cookie import) |
| Design mode / grab / annotate element → chat | `browser/design-mode.mdx` | MISSING | – | L | browser, chat | – |
| Automation CLI (~75 cmds: snapshot, click, fill, type, keypress, mouse, scroll, screenshot, pdf, eval, console, network, intercept, cookies, storage, viewport, geolocation, offline, headers, dialog, download/upload, capture) | `src/cli/specs/browser-*.ts`, `browser-client-automation-protocol.ts` | MISSING | – | XL | browser, CLI | R (interception, network log, device emulation via public WebKit) |
| Site permissions, downloads, viewport emulation, devtools | `BrowserSitePermissionsSetting`, `DevToolsPane` | MISSING | – | M | browser | R? |
| Remote/hosted browser for SSH workspaces | `BrowserClientHostedRemoteSetting` | MISSING | – | L | SSH | I |

### 2.6 Orchestration and CLI

| Family (Orca `orca …`) | Orca count | smthz equivalent | Status | Size | Flags |
|---|---|---|---|---|---|
| `status`, `host list/name`, `agent-context` | 4 | `ping`, `paths` | PARTIAL | S | – |
| `terminal create/list/read/send/close/stop/split/rename/set-pane-title/show/switch/wait` | 12 | `run/sessions/read/write/kill/attach` | PARTIAL (≈5/12) | M | – |
| `terminal-daemon status/restart` | 2 | none | MISSING | S | – |
| `worktree *`, `repo *`, `project *`, `reference *` | 25 | none | MISSING | L | M4 |
| `file open/diff/open-changed`, `search` | 4 | none | MISSING | M | editor |
| `orchestration *` (runs, tasks DAG, dispatch, workers, mail, ask/reply, gates, coordinator, federation) | 37 | none | MISSING | XL | agents |
| `automations *` | 7 | none | MISSING | L | scheduler |
| `account *`, `agent launch`, `agent hooks *` | 9 | none | MISSING | M | agents |
| `browser` family (tab/profile/identity/automation) | ≈90 | none | MISSING | XL | browser |
| `computer *` | 15 | none | MISSING | L | computer use |
| `emulator *` | 15 | none | MISSING | L | emulators |
| `linear *` / `jira *` | ≈45 | none | MISSING | L | I |
| `skills *`, `artifacts *`, `profile state *` | 13 | none | MISSING | M | I |
| `environment *`, `vm recipe doctor` | 12 | none | MISSING | L | I |
| `serve`, `serve service *`, `serve restore resume` | 5 | `smthzd` flags | PARTIAL | M | – |
| `speech openai-key *`, `diagnostics memory` | 4 | none | MISSING | S | I |
| CLI install into PATH / registration | `CliSection`, `src/main/cli` | none | MISSING | S | S |
| Host RPC surface | 311 method files (orchestration ≥92, agentSession ≥55, worktree 16 …) | 14 methods | PARTIAL (terminal subset) | – | – |

### 2.7 Automations

| Feature | Orca (R/) | smthz | Size | Flags |
|---|---|---|---|---|
| Schedules, timezones, missed-run grace, prechecks, session reuse, extra agent args, run history, per-host targets | `src/main/automations`, `src/shared/automation-schedules.ts`, `cli/automations.mdx` | DONE-visual-only (`Pages/AutomationsPage.swift`) | L | – |
| Settings pane | `AutomationsSettingsPane` | placeholder | S | – |

### 2.8 Integrations

| Provider | Orca (R/) | smthz | Size | Flags |
|---|---|---|---|---|
| GitHub: PRs/reviews, auto-merge, stacked PRs, issues, actions, tasks, API budget, item dialog, PR page | `src/main/github`, `components/github*`, `pull-request-page`, `review/github.mdx` | MISSING (Tasks page/Checks visual only) | XL | I (OAuth app or `gh`) |
| GitLab, Gitea, Bitbucket, Azure DevOps | `src/main/gitlab|gitea|bitbucket|azure-devops` | MISSING | L each ≈ M | I |
| Linear (issues, comments, relations, MCP-style write, agent skill) | `src/main/linear`, `LinearAgentSkillPane` | MISSING | L | I |
| Jira | `src/main/jira`, `review/jira.mdx` | MISSING | M | I |
| Task page / task sources | `components/task-page`, `TasksPane` | DONE-visual-only (`Pages/TasksPage.swift`) | M | I |

### 2.9 Settings pages (Orca 38 panes)

Real body in smthz: **Terminal** (PARTIAL, 5 disabled controls) and **Appearance** (PARTIAL: theme + sidebar prefs; no app-icon selector, chat contrast, usage toggles). Every other pane is a placeholder (`SettingsUnavailableBody`): Accounts, Advanced (+network/proxy), Agents, Artifacts, Automations, Browser, Browser Use, Commit Message AI, Computer Use, Developer Permissions, DevTools, Ephemeral VMs, Experimental, Floating Workspace, General (editor, workspace, updates, support, remote server updates), Git, Git Provider API Budget, Input, Integrations, Linear Agent Skill, Mobile Emulator, Mobile, Mobile Settings, Notifications, smthz Account (Orca Account), Orchestration, Privacy, Quick Commands (store exists, pane missing), Repository, Runtime Environments, Session History, Setup Guide, Share Skills, **Shortcuts** (editor with conflicts/layouts), SSH, Tasks, Voice. Settings search: visual only. Size: each pane S–M once its backend exists; Shortcuts M.

### 2.10 Notifications and attention

| Feature | Orca (R/) | smthz | Size | Flags |
|---|---|---|---|---|
| Agent-finished notifications, persistent bell, custom sounds, tuning | `src/main/notifications`, `notifications.mdx` | MISSING (permission request only, `OnboardingSteps.swift`) | M | – |
| Mark unread / activity feed | `components/activity`, `activity.mdx` | PARTIAL (window-local unread) | M | – |
| Dock badge/menu, tray | `src/main/dock`, `src/main/tray` | MISSING | S | – |
| Pet, stats, star nag, feature tips/wall, contextual tours | `components/pet|stats|star-nag|feature-tips|feature-wall|contextual-tours` | MISSING | M | U (star nag/social links) |

### 2.11 Mobile, pairing, relay

| Feature | Orca (R/) | smthz | Size | Flags |
|---|---|---|---|---|
| Pairing, relay, mobile web/app (chat, quick commands, tabs, account switcher, SC, browser view) | `mobile/`, `src/main/managed-server`, `mobile.mdx`, `mobileWeb.*` RPC | DONE-visual-only (`Pages/MobilePage.swift`) | XL | I, D (companion apps deferred per ROADMAP) |

### 2.12 SSH and remote hosts

| Feature | Orca (R/) | smthz | Size | Flags |
|---|---|---|---|---|
| SSH targets (host keys, passphrases, Kerberos, FIDO2, port forwarding, remote files/download, relay on Linux without toolchain, sessions across app close) | `src/main/ssh`, `ssh.mdx` | MISSING (status-bar chip visual only) | XL | – |
| Remote smthz servers (`serve`, access links, Tailscale, memory limit, remote updates) | `src/main/orcad`, `remote-servers.mdx` | PARTIAL foundation: `WebSocketTransport.swift` without TLS/auth | XL | I (relay/auth) |
| Linux execution host build | `ways-to-run.mdx` | MISSING (macOS-only APIs: `proc_pidinfo`) | L | – |
| Ports scanner + forwarding | `src/main/ports`, `workspace-ports*` | DONE-visual-only (`PortsPanel.swift`) | M | – |
| Ephemeral VMs / environments / recipes | `src/main/ephemeral-vm`, CLI `environment *` | MISSING | XL | I |
| Open remote workspace in VS Code | `ssh.mdx` | MISSING | S | – |

### 2.13 Skills, plugins, artifacts, profiles

| Feature | Orca (R/) | smthz | Size | Flags |
|---|---|---|---|---|
| Skills discovery/install/update/rollback, bundled guides (orca-cli, orchestration, computer-use, linear, emulator), MCP servers | `src/main/skills`, `skills/`, `skill-guides/`, `cli/skills.mdx` | MISSING | L | – |
| Skill sharing between hosts / cloud | `skill-cloud*`, `ShareSkillsSettingsPane` | MISSING | M | I |
| Plugins (manifests, panels, workers, catalog) | `src/main/plugins`, `components/plugin-catalog` | MISSING | XL | U (Node gate), R? |
| Artifacts publish/share, own account/profile/org storage | `src/main/artifacts`, `orca-profiles`, `cloud/` | MISSING | XL | I |

### 2.14 Speech, computer use, emulators

| Feature | Orca (R/) | smthz | Size | Flags |
|---|---|---|---|---|
| Dictation (local models + hosted transcription) | `src/main/speech`, `components/dictation` | MISSING | L | I (OpenAI key) |
| macOS computer use (AX tree, input, screenshots, helper, permissions) | `native/computer-use-macos`, `src/main/computer` | MISSING | L | S (TCC needs stable signature) |
| iOS Simulator / Android emulator panes + CLI | `src/main/emulator`, `components/emulator-pane` | MISSING | L | – (Xcode/simctl, adb) |

### 2.15 Updates, distribution, diagnostics

| Feature | Orca (R/) | smthz | Size | Flags |
|---|---|---|---|---|
| App bundle, icon, bundled host | `electron-builder`, `Casks/` | DONE-real (ad-hoc) | `scripts/package-app.sh` | – | – |
| Signed/notarized build, Homebrew cask | `install.mdx` | MISSING | M | S, U (bundle id) |
| Auto-update (+ remote host updates) | `src/main/updater` | DONE-visual-only (toast) | M | I (feed), S |
| Crash reporting, hang watchdog, diagnostics, telemetry + opt-out, privacy pane | `crash-reporting`, `hang-watchdog`, `diagnostics`, `telemetry`, `observability` | MISSING | M | I, U |
| Third-party notices | – | DONE | `THIRD-PARTY-NOTICES.md` | – | – |

### 2.16 Onboarding

| Feature | Orca (R/) | smthz | Size | Flags |
|---|---|---|---|---|
| Six-step onboarding, skip, reopen | `components/onboarding` | DONE-real | `Onboarding/*` | – | – |
| Agent/integration steps, setup guide, checklist | `components/setup-guide`, `SettingsSetupGuidePane` | DONE-visual-only | `OnboardingSteps.swift` | S | agents, integrations |
| Language step | i18n `src/main/i18n` | English only | – | – | D (accepted) |

### 2.17 Keyboard shortcuts and menus

| Feature | Orca (R/) | smthz | Size | Flags |
|---|---|---|---|---|
| 91 keybinding actions | `src/shared/keybindings` | PARTIAL: 37 ids in registry; ≈30 wired by hard-coded SwiftUI shortcuts | M | U (D7 accepted deviations) |
| User override file, conflicts, double-tap, keyboard-layout aware matching | `keybinding-file*.ts`, `keybindings-*` tests | MISSING | M | – |
| App menus (File/Edit/Appearance/View/Help, Check for Updates, Report Crash, Force Reload) | `src/main/menu` | PARTIAL | `SmthzApp.swift` (Host menu extra) | S | – |

### 2.18 Persistence and recovery

| Feature | Orca (R/) | smthz | Size | Flags |
|---|---|---|---|---|
| Shell layout/tab state, pending-create idempotency | `src/main/persistence`, `model/session-restore.mdx` | DONE-real | `ShellStateStore.swift`, `ShellController.swift` | – | – |
| Host journal, idempotent RPC, capability token | `runtime/rpc` | DONE-real | `EventJournal.swift`, `HostService.swift` | – | – |
| Projects/worktrees/settings persistence, backup, profile state rollback/exports | `persistence`, `profile state *` | MISSING | M | – |
| Durable file write / transaction lock | `durable-file-write.ts`, `file-transaction-lock.ts` | MISSING (needed by editor) | S | – |

### 2.19 Performance

No baseline exists for either app (AGENTS rule: measure Orca first). Known risks: polled terminal output, SwiftTerm paint cost, per-session scrollback I/O. Benchmarks: MISSING, size L (M11).

## 3. Percentage estimate

Method: per area, each row scored DONE-real = 1, PARTIAL = 0.5 × estimated share, DONE-visual-only = 0 functional / 1 visual, MISSING = 0; area result rounded. Overall = area results weighted by the estimated effort of that Orca area (weights in brackets, total 112; visual total excludes non-UI areas). These are judgment estimates, not measurements.

| Area [weight] | Functional | Visual |
|---|---|---|
| Terminal/panes/tabs/windows [8] | 55% | 70% |
| Projects/worktrees/Git [8] | 5% | 40% |
| Files/editor/diffs/SC [12] | 8% | 20% |
| Agents [14] | 0% | 10% |
| Browser [10] | 0% | 0% |
| Orchestration/CLI [8] | 4% | n/a |
| Automations [3] | 0% | 30% |
| Integrations [8] | 0% | 15% |
| Settings [4] | 6% | 25% |
| Notifications/attention [2] | 5% | 10% |
| Mobile/relay [4] | 0% | 20% |
| SSH/remote/ports/VMs [8] | 3% | 5% |
| Skills/plugins/artifacts [6] | 0% | 0% |
| Speech/computer use/emulators [6] | 0% | 0% |
| Updates/distribution [3] | 10% | n/a |
| Onboarding [1] | 50% | 80% |
| Shortcuts/menus [2] | 35% | 50% |
| Persistence/recovery [3] | 40% | n/a |
| Performance [2] | 0% | n/a |
| **Overall** | **≈ 8%** | **≈ 20%** |

Reading: the main window chrome (sidebar, tab strip, terminal panes, right sidebar shell, status bar) is visually close to Orca (~75% for that screen alone), but most of Orca's surface lives behind it (editor, diffs, agents, chat, browser, integrations) and is not built.

## 4. Gap list as work packages

Lanes: **A** and **B** = the two Codex workers allowed at once. Effort in worker-days (wd).

| # | WP | Contents | Deps | Lane | Effort | Flags |
|---|---|---|---|---|---|---|
| 1 | FIX-HOSTRECONNECT | App stuck on "Host unreachable" after host respawn | – | A | 1–2 | – |
| 2 | H5-STREAM | Push PTY output (`session.subscribe`) replacing polling | – | B | 3–4 | – |
| 3 | A3-GROUPS | Tab-group UI on existing model; reopen-closed; close-all | – | A | 3 | – |
| 4 | A5-KEYS | Full 91-action registry, app applies registry, override file (D8), menu parity | – | B | 3–4 | – |
| 5 | T1-CONFORMANCE | Alt screen, mouse, true colour, IME, OSC 52, Unicode width, copy context, input source switch; tests + checklist C1–C15 | 2 | A | 3–4 | – |
| 6 | M4-REGISTRY | Host-owned projects/repos/folders (SQLite), `smthz repo/project` CLI, sidebar cards per workspace | – | B | 4–5 | – |
| 7 | M4-WORKTREE | Worktree create/delete/archive, start-from, branch naming, orca.yaml-equivalent (`smthz.yaml`, U: name), setup/archive hooks, .worktreeinclude, sparse | 6 | A | 8–10 | U (config file name) |
| 8 | A4-WINDOWS | Multiple workspaces live, multiple windows (D3), floating terminal (A7), A6/A8 hardening | 6 | B | 5 | U (D3) |
| 9 | M4-SCWRITE | Stage/unstage/discard/commit/amend/push, branch ops, conflicts | 6 | B | 5 | – |
| 10 | M1-EDITOR | Editor engine experiment (TextKit 2 vs WebKit+Monaco vs native) with evidence | – | A | 3 | U, R? |
| 11 | M4-FILES | Explorer ops, ripgrep search, Go to File open, durable writes, external editor | 10 | A/B | 5 | – |
| 12 | M4-EDITOR | Editor surface + markdown editor + viewers (PDFKit, images, CSV, HTML, Mermaid, notebooks) | 10, 11 | A | 15–20 | – |
| 13 | M4-DIFF | Diff viewer, combined diff, file tree, review comments | 12 | B | 8–10 | – |
| 14 | M5-ROSTER | Agent detection for 47 ids, launch into tabs with defaults/env/trust, `smthz agent launch` | 7 | A | 5 | – |
| 15 | M5-HOOKS | Status hooks, state indicators, restart chip, dashboard, Agents panel, notifications, hibernation, awake | 14 | B | 8 | – |
| 16 | M5-ACCOUNTS | Accounts/hot-swap (Keychain), usage/rate limits, cost stats | 14 | A | 8 | U (meters) |
| 17 | M5-HISTORY | Session history + FTS search/resume, memory files | 14 | B | 5 | – |
| 18 | M1/M5-CHAT | Native chat experiment then implementation (Claude, Codex, ACP) | 14 | A | 20+ | U, R? |
| 19 | M6-BROWSER | WebKit pane, profiles, link routing, downloads, permissions, design mode | M1 WebKit gate | B | 15–20 | R (cookie import, devtools) |
| 20 | M6-AUTOMATION | Browser automation CLI on WKWebView public APIs; document every gap | 19 | B | 10–15 | R |
| 21 | M8-ORCH | Orchestration runs/tasks/DAG/dispatch/mail/ask/gates/workers + CLI | 14, 15 | A | 15–20 | – |
| 22 | M8-AUTOMATIONS | Scheduler, prechecks, history, session reuse + CLI + page | 21 | B | 8 | – |
| 23 | M7-SSH | SSH targets via OpenSSH, remote host bootstrap, port forwarding, remote files, Linux host build | 2 | A | 20+ | – |
| 24 | M7-REMOTE | Authenticated TLS WebSocket, access links, pairing/revocation, relay | 23 | B | 15 | I, U |
| 25 | M7-PORTS | Port scanner, forwarding, ports panel | 23 | A | 3 | – |
| 26 | M8-VM | Ephemeral VMs/environments/recipes | 24 | – | 10+ | I |
| 27 | M9-INTEGRATIONS | GitHub (gh/OAuth), GitLab, Gitea, Bitbucket, Azure, Linear, Jira, Tasks page, Checks panel | 6 | A/B | 25+ | I |
| 28 | M9-SKILLS | Skills discovery/install/update, bundled guides for `smthz`, MCP servers | 21 | – | 5 | – |
| 29 | M9-PLUGINS | Plugin system (Node gate) | U | – | 15+ | U, R |
| 30 | M9-ARTIFACTS | Artifacts/profiles/sharing on own storage | 24 | – | 10+ | I |
| 31 | M10-SPEECH | Dictation local + hosted | – | – | 8 | I |
| 32 | M10-COMPUTER | Computer-use helper (AX/CG), permissions, CLI | signing | – | 10 | S |
| 33 | M10-EMULATORS | iOS Simulator (simctl) and Android (adb) panes + CLI | – | – | 10 | – |
| 34 | M10-SETTINGS | Remaining 36 settings panes, settings search, Shortcuts editor | as backends land | – | 10 total | – |
| 35 | M10-ATTENTION | Notifications/sounds, activity, dock/tray, pet/stats/tips/tours | 15 | – | 5 | U (star nag) |
| 36 | M11-DIST | Real bundle id, signing/notarization, update feed, crash/diagnostics, telemetry opt-in, CLI install | – | – | 5–8 | S, I, U |
| 37 | M11-PERF | Orca baseline then smthz benchmarks, soak | 2 | – | 5 | – |
| 38 | M2-REMAINDER | Host-restart session recovery (D2/D12), `handshake`/`request.cancel` idempotency, replay-size race, launchd (D4) | – | – | 5 | U (D2) |
| 39 | MOBILE | Mobile web/companion apps | 24 | – | XL | D, I |

Items requiring the user or outside resources before work can finish: real bundle id; signing identity/Apple Developer account; `xcode-select` switch; own auth/relay/artifact/skill-cloud servers and their hosting; OAuth apps or token strategy for GitHub/GitLab/Gitea/Bitbucket/Azure/Linear/Jira; OpenAI key (speech); update feed and crash/telemetry endpoints; Node acceptance for plugins; WebKit gaps vs Chromium (cookie import from Chrome, CDP-style network interception, device emulation, devtools APIs) — each is a potential **functional reduction** needing explicit acceptance; editor engine choice; native-chat control path for Claude; name of the per-repo config file (`orca.yaml` equivalent); multiple-window model (D3); host-restart behaviour (D2); "ORCA"/smthz landing title, star nag, social links, usage meters. Already accepted/deferred: English only, Windows/WSL, companion mobile apps, D1, D4, D7.

## 5. Known defects and risks (from AGENTS.md / UI-WIRING.md)

| Defect / risk | Source | Status |
|---|---|---|
| After SIGTERM + respawn of the app-spawned host (pong OK), app stays "Host not running"/"Host unreachable"; Try again does not recover | AGENTS A2 section | Open; root cause **not verified** by this audit (HostMonitor rebuilds a client and reloads the token per poll, so suspect HostController/ShellController retained error state) |
| Flaky `SessionManagerTests` / `ScrollbackDescriptorDurabilityTests` on the first run after worker builds | AGENTS UI waves 6/8 | Hardened in H4, not reproduced since; logs never captured |
| First close immediately after injecting a command raced shell startup (no running-command prompt) | UI-WIRING §Limits | Open |
| `handshake`/`request.cancel` outside durable idempotency; cancel may race a committed result | AGENTS open issues | Open |
| Replay-size race | TERMINAL-BEHAVIOR P3 | Open |
| Children die when the host restarts (no recovery) | D12 | Open (M2 remainder) |
| Not verified: `smthz attach`, SIGWINCH after UI resize, job control, vim/less/htop, mouse reporting, selection/copy, true colour, `clear`/Ctrl-L visually, session selection by real click, quick-command save round trip, inline rename commit, Stop/Restart Host menu by coordinator, hover states, light/dark on every surface | AGENTS, UI-WIRING | Open |
| Icon: flat bottom edge on the bust vs reference | AGENTS C3 section | Cosmetic, open |
| Warnings: EventJournal unused `withUnsafeBytes`, PTYSession deprecated `init(cString:)`, StatusBarView missing Combine import | AGENTS backlog, UI-WIRING | Open |
| Cleanup: `exited(signal(9))` formatting, `SmthzCore.swift` stub, `main.swift` indentation, stale `docs/orchestration-scripts/` paths, scripts using `pkill -x SmthzApp` | AGENTS | Open |
| Stale docs: ROADMAP execution/Xcode lines, PARITY ledger all "Not started" | this audit §1.1 | Open (docs) |
| Performance unknown; terminal polling | this audit | Risk |
| WebKit and native-chat feasibility unproven (M1 gates) | ROADMAP M1 | Risk: could force reductions |

## 6. Recommended milestone order to 100%

1. **Finish M3** (WP 1–5, 8): reliable host reconnect, streamed output, groups, full keys, terminal conformance, windows/floating.
2. **M4 local developer loop** (WP 6, 7, 9, 10–13): projects, worktrees, SC writes, files, editor, diffs. This is the largest functional unlock after terminals.
3. **M5 agents** (WP 14–18): roster/launch/hooks first (TUI agents work in terminals today), accounts/usage/history, then native chat.
4. **M8 orchestration + automations** (WP 21–22), then **CLI parity** for every family built so far.
5. **M6 browser** (WP 19–20) after the WebKit gate; record each reduction for user acceptance.
6. **M7 remote** (WP 23–25, 38): SSH, Linux host, remote servers, ports; needs relay/auth decisions.
7. **M9** integrations, skills, artifacts, plugins (infra- and decision-bound).
8. **M10** speech, computer use, emulators, attention, all settings panes.
9. **M11** distribution/signing/update, parity ledger audit, benchmarks.

### First 10 work packages (ready to hand out)

1. **WP-FIX-HOSTRECONNECT (Lane A, S).** Reproduce: package the app, open with `-SmthzStateDirectory /tmp/smthz-rc`, wait for "Local host connected", `kill -TERM` the app-spawned `smthzd`, wait for the respawn and confirm `smthz ping --socket <state>/…` answers. Expected: status returns to connected within one monitor interval and tabs re-bind to surviving/exited sessions; Try again must recover too. Find why `HostController`/`ShellController`/`HostMonitor` keep the error state (check retained `HostClient`, cached capability token, lifecycle state machine not leaving `.unreachable`, throttle window). Fix in `Sources/SmthzApp/HostController.swift`, `ShellController.swift` and, if needed, `Sources/SmthzCore/HostMonitor.swift`/`HostLauncher.swift`; add a core test that kills and restarts a real `smthzd` and asserts the monitor yields `.running` again. No `Package.swift` change; full suite ×3.

2. **WP-H5-STREAM (Lane B, M).** Add host RPC `session.subscribe {id, fromCursor}` that pushes output frames (absolute cursor, bytes, truncated flag, exit event) over the existing Unix socket with back-pressure and a bounded per-subscriber queue; keep `session.read` for compatibility. `HostClient` gets an `AsyncThrowingStream`; `TerminalSessionView.swift` switches from polling to the stream, resubscribing from its last cursor after reconnect (works with WP 1). Files: `HostService.swift`, `SessionManager.swift`, `HostClient.swift`, `UnixSocketTransport.swift` (only if needed), `TerminalSessionView.swift`, new `SessionStreamTests.swift`. Tests: ordering, no loss across reconnect, slow consumer, session exit, 1 MiB frame cap. Measure and report input-to-echo latency before/after (no budget claim).

3. **WP-A3-GROUPS (Lane A, M).** Expose the existing `ShellModel` tab groups in the UI per `docs/M3-PLAN.md` WP-A3 and Orca `R/src/renderer/src/components/tab-group`: group headers in `TabStripView.swift`, create/rename/colour/collapse/ungroup, drag tabs between groups, pinned boundaries, persistence through `ShellStateStore`. Also wire `tab.reopenClosed` (keep a bounded closed-tab stack in `ShellController`, restoring title/colour/cwd and re-creating the session), `tab.closeAll`, next/previous same type. Only `Sources/SmthzApp/*` plus core tests if a model command is missing (then also update stale C2 tests). Verify in the real app with a private host.

4. **WP-A5-KEYS (Lane B, M).** Port all 91 actions from `R/src/shared/keybindings/definitions-core-1..4.ts` into `Keybindings.swift` (ids, titles, groups, scopes, default chords, conflict groups; unimplemented actions marked `available: false`), apply D7 deviations, read a user override file `<state-dir>/keybindings.json` (D8) with parse errors surfaced, and make the app dispatch shortcuts and menu labels from the registry instead of hard-coded `.keyboardShortcut`. Menus: add Force Reload equivalent, Check for Updates (stub), Report Crash (stub) per `R/src/main/menu/register-app-menu.ts`. Tests: defaults, conflicts, override parsing, digit index. Terminal-scope bindings must not swallow keys TUIs need (follow `window-shortcut-policy.ts`).

5. **WP-T1-CONFORMANCE (Lane A after WP 2, M).** Work through `docs/TERMINAL-BEHAVIOR.md` C1–C15 against the real app: alternate screen (vim/less/htop), mouse reporting, selection/copy, true colour, IME/marked text, wide/emoji glyphs, OSC 52 copy (gated by a setting), SIGWINCH after pane resize, job control (Ctrl-Z/fg), Ctrl-L/`clear`. Implement missing pieces in `TerminalSessionView.swift`/`TerminalPaneHost.swift`: "Copy terminal context" (Orca `terminal.mdx`), `terminal.switchInputSource`, file-path link detection (open in Finder until the editor exists). Deliver a checklist table with evidence (screenshots, `stty size` output) appended to `docs/TERMINAL-BEHAVIOR.md`.

6. **WP-M4-REGISTRY (Lane B, M).** Host-owned project registry: SQLite tables (projects, repos, folders, project groups) in `smthzd`'s state dir, RPC `project.add/list/remove/update`, `repo.list/show/setBaseRef`, CLI `smthz repo add|list|show`, `smthz project list`. App: `AddProjectDialog` persists the chosen folder (detect Git via `GitService.repository`), sidebar shows one card per project/workspace with real sort/group/filter, Jump palette lists projects, unread/pin persisted. Plain folders must work without Git. Reference: `R/src/main/ipc/repos`, `R/src/cli/specs/repo.ts`, `project.ts`. Tests with real temp repos; no deletion of user files.

7. **WP-M4-WORKTREE (Lane A, L).** Worktree lifecycle per `R/docs/site/content/docs/model/worktrees.mdx` and `orca-yaml.mdx`: create in background with progress (start-from branch/PR ref picker, branch naming with prefix, emoji names), parent/child lineage, setup/archive hooks, per-repo config file (name needs a user decision; parse Orca's keys), `.worktreeinclude` copy with budget, shared directories, optional sparse checkout, delete/archive with preserved-branch warning, Resource Manager cleanup. RPC `worktree.create/list/remove/set/show`, CLI `smthz worktree …`. Composer creates a real worktree and opens a terminal in it. Tests on real repos, including failure rollback.

8. **WP-A4-WINDOWS (Lane B, M).** Per `docs/M3-PLAN.md` WP-A4/A6/A7/A8 and decision D3 (ask the user before starting if still open): multiple windows each with its own workspace selection and persisted frame, workspace switching keeps sessions bound, floating terminal panel (NSPanel, toggle shortcut, status chip real), floating workspace maximize/minimize, close confirmations for windows, and the A8 hardening pass (restore without duplicate work across windows). Files under `Sources/SmthzApp` and `ShellStateStore` schema bump with migration test.

9. **WP-M4-SCWRITE (Lane B after WP 6, M).** Extend `GitService.swift` with stage/unstage (file and hunk), discard (with confirmation), commit/amend, push/pull/fetch with upstream, branch create/switch/delete, stash, merge/rebase conflict state; enable the disabled controls in `SourceControlPanel.swift` (commit box, staged/unstaged lists, ahead/behind, sync button). Reference `R/src/main/git`, `R/src/main/source-control`, `review/commit-push.mdx`. AI commit message stays disabled until agents exist. Real temp-repo tests for every operation including failure paths (hooks rejecting, no upstream, conflicts). Never run git write commands on the smthz repo itself.

10. **WP-M1-EDITOR (Lane A, S–M, research + prototype, no product wiring).** Decide the editor engine with evidence: (a) native TextKit 2 + tree-sitter, (b) WKWebView hosting Monaco (allowed: isolated renderer, state in Swift), (c) existing Swift editor packages (license check). Measure on 1 MB / 50k-line files: open time, scroll/typing latency, multi-cursor, find/replace, minimap, syntax highlighting breadth, IME, accessibility, memory. Check Orca behaviours in `R/docs/site/content/docs/editing/monaco.mdx` and `markdown.mdx`. Deliver `docs/EDITOR-ENGINE.md` with a recommendation and the list of Orca editor behaviours each option cannot meet (each one a possible reduction for the user to accept). Prototype code lives only in a scratch target outside `Package.swift`.

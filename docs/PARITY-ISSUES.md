# PARITY-ISSUES — current audit crosswalk

Updated: **2026-10-31**, re-audit revision 2. Source: read-only `gh issue list --state open --limit 100 --json number,title,labels,body` for [rpribau/smthz](https://github.com/rpribau/smthz), **32 open issues (#1–#32)**. All entries were read, including bodies and labels. This document proposes coordinator actions only; **no issues, labels or Git state were modified**. Work-package ids match PARITY-AUDIT §4; Nxx ids below are proposals, never real GitHub numbers and never inserted into parity-status.json.

## Every open GitHub issue

| Number | Exact current title | Area id(s) | Audit work package(s) | Current assessment |
|---|---|---|---|---|
| [#1](https://github.com/rpribau/smthz/issues/1) | Editor engine and file editing (Monaco in WKWebView) | editor, files, persistence | EDITOR | Open; engine acceptance and durable editor flow still absent. |
| [#2](https://github.com/rpribau/smthz/issues/2) | Markdown editor and file viewers | editor | VIEWERS | Open; no in-app viewers/markdown editor. |
| [#3](https://github.com/rpribau/smthz/issues/3) | Diff viewer, combined diff and review comments | editor, git | DIFF | Open; Git diff text exists, visual diff/review do not. |
| [#4](https://github.com/rpribau/smthz/issues/4) | Agent chat: Codex structured transport UI | chat | CHAT-CODEX | Core now delivered and fake-tested; retain UI scope. |
| [#5](https://github.com/rpribau/smthz/issues/5) | Agent chat: Claude structured chat | chat | CHAT-CLAUDE | Open; U-B3 decision still required. |
| [#6](https://github.com/rpribau/smthz/issues/6) | Agent chat: ACP agents | chat | CHAT-ACP | Open; no generic ACP transport. |
| [#7](https://github.com/rpribau/smthz/issues/7) | Transcript view wired into agent tabs | chat, history | CHAT-WIRE | Standalone transcript/decoders delivered; app toggle/composer/discovery absent. |
| [#8](https://github.com/rpribau/smthz/issues/8) | Agent accounts, hot-swap and usage | accounts | ACCOUNTS | Open; accountId currently unsupported, meters still a decision. |
| [#9](https://github.com/rpribau/smthz/issues/9) | Agent session history and search | history | HISTORY | Partial foundation only: JSONL tailing is not catalog/FTS/resume. |
| [#10](https://github.com/rpribau/smthz/issues/10) | Browser: app-side automation executor | browser, cli | BROWSER-REDUCTIONS | Stale implementation status: executor/E2E delivered; narrow to reductions/remaining coverage. |
| [#11](https://github.com/rpribau/smthz/issues/11) | Browser: profiles and cookie import wiring | browser | BROWSER-PROFILES | Partially stale: profile CLI now wired; import/settings UI still absent. |
| [#12](https://github.com/rpribau/smthz/issues/12) | Browser: design mode | browser | BROWSER-DESIGN | Open; no design/annotation/agent attachment surface. |
| [#13](https://github.com/rpribau/smthz/issues/13) | Browser tabs: persistence and splits | browser, terminal | BROWSER-MODEL | Open; app-global browser store has no ShellModel persistence/splits. |
| [#14](https://github.com/rpribau/smthz/issues/14) | Orchestration: workers, dispatch and coordinator loop | orchestration, cli | ORCH-WORKERS | Store/19 CLI verbs complete; workers/coordinator/federation/UI absent. |
| [#15](https://github.com/rpribau/smthz/issues/15) | Automations: scheduler, prechecks and history | automations, cli | AUTOMATIONS | Open; only placeholder page. |
| [#16](https://github.com/rpribau/smthz/issues/16) | SSH targets and remote hosts | remote, files, cli | SSH-LINUX | Open; SSH/Linux/bootstrap/remote files absent. |
| [#17](https://github.com/rpribau/smthz/issues/17) | Remote access: authenticated TLS WebSocket, pairing and relay | remote, mobile, cli | REMOTE-AUTH | Open; loopback WebSocket is not authenticated remote access. |
| [#18](https://github.com/rpribau/smthz/issues/18) | Ports panel: scanner and forwarding | remote | PORTS | Open; Ports panel has no scanner/forwarder. |
| [#19](https://github.com/rpribau/smthz/issues/19) | Integrations: GitHub and GitLab | integrations, onboarding, cli | PROVIDERS-GIT | Open; title omits three providers named in its body. |
| [#20](https://github.com/rpribau/smthz/issues/20) | Integrations: Linear and Jira | integrations, onboarding, cli | PROVIDERS-ISSUES | Open; no provider clients/credentials. |
| [#21](https://github.com/rpribau/smthz/issues/21) | Skills, plugins and artifacts | library, cli | LIBRARY | Open; broad umbrella should enumerate MCP/sharing/own storage. |
| [#22](https://github.com/rpribau/smthz/issues/22) | Multiple windows and floating terminal | windows, projects | WINDOWS | Partly stale: multiple host workspaces/layouts now exist; independent windows/floating remain. |
| [#23](https://github.com/rpribau/smthz/issues/23) | Host restart session recovery | persistence, cli | RECOVERY | Open; restart behavior/idempotency/launchd incomplete. |
| [#24](https://github.com/rpribau/smthz/issues/24) | Settings: remaining panes | settings, shortcuts | SETTINGS | Stale count if treated as nearly empty: 10 bodies, 9 with some real behavior. |
| [#25](https://github.com/rpribau/smthz/issues/25) | Computer use helper | tools, cli | COMPUTER | Open; no computer helper/runtime. |
| [#26](https://github.com/rpribau/smthz/issues/26) | iOS Simulator and Android emulator panes | tools, cli | EMULATORS | Open; no simulator/adb integration. |
| [#27](https://github.com/rpribau/smthz/issues/27) | Speech and dictation | tools, cli | SPEECH | Open; no speech/model/key backend. |
| [#28](https://github.com/rpribau/smthz/issues/28) | Real bundle identifier, signing, notarization and update feed | distribution, cli | DISTRIBUTION | Open; ad-hoc package is complete, distribution services are not. |
| [#29](https://github.com/rpribau/smthz/issues/29) | Performance baseline versus Orca | performance | PERF | Open; no Orca baseline. |
| [#30](https://github.com/rpribau/smthz/issues/30) | Terminal conformance gaps | terminal, persistence | TERMINAL-CONFORMANCE | Update with T1 successes and narrower residual conformance list. |
| [#31](https://github.com/rpribau/smthz/issues/31) | GUI verification backlog | terminal, windows, projects, git, files, agents, chat, browser, settings, attention, onboarding, shortcuts, integrations, automations, mobile | GUI-VERIFY | Open; broaden to all explicitly unverified wave 10–17 GUI paths. |
| [#32](https://github.com/rpribau/smthz/issues/32) | Mobile companion | mobile | MOBILE | Accepted deferral; retain visible parity gap. |

## Stale, overlapping, mislabelled or underspecified issues

None is proved fully delivered, so **no unconditional closure is recommended**. Coverage by an umbrella does not mean its individual acceptance criteria have been met.

| Issue(s) | What to change |
|---|---|
| #10 | Rename to “Browser automation: public-WebKit reductions, residual RPCs and robustness”. Replace “executor in progress” with the delivered provider/executor and recorded 88/88 ×2 result. Track the 25 reduced commands and exec explicitly; include R-B1..B12, large reply chunking, actual HTTPS/cross-origin/visible-page tests, profile clone semantics, certificates/screencast/client file-channel/network-tunnel RPC differences. Add existing label **needs decision** for reductions; do not call them accepted. Keep actual SSH transport under #16/#17. |
| #11 | Rename to “Browser profile/import UI and cookie/lifetime completeness”. Profile list/create/delete/show/set/clone now work through CLI/executor; cookie importers have no app caller. Require per-tab/settings UI, UI-close detach/deferred removal, safe import/apply/replace semantics, real Keychain/FDA checks and explicit CHIPS/public-suffix/domain/Google limitations. Keep **needs decision**. |
| #4 | Remove “core client in progress”: Codex app-server core is delivered, generated/version-gated at 0.164.x and fake-process tested. Retain reachable structured UI, live conformance, approvals/questions, interrupt/resume and end-to-end streaming as acceptance. |
| #4 + #7 | Share one Chat/Terminal surface integration task. #7 owns PTY transcript discovery/read-only/live-tail/composer plumbing; #4 owns structured Codex session/turn/approval behavior. Their repeated toggle requirement is overlap, not evidence that either issue is a duplicate. |
| #5 + #6 + #7 + #9 | Keep separate: Claude control transport, ACP transport, transcript surface and history catalog/FTS/resume are different gaps. Decoder existence does not close any whole issue. Explicitly track Claude edit-patch/pasted/image decoding and Codex transcript filtering in #7. |
| #14 | Replace the “store/CLI slice in progress” note with delivered runs/tasks/DAG/mail/ask/gates/reset and 19 CLI verbs. Explicit remaining acceptance: worker-start/control/read/list/release/retention, real injection/observation, coordinator lifecycle, mutation request receipts, remote authority/federation and usable run/task/worker UI. This is too broad for one worker spec; split bounded follow-ups without duplicating the delivered store. |
| #22 | Remove “multiple live workspaces” from wholly missing work; host catalog and per-workspace shell layouts now exist. Keep independent-window ownership/persistence, dashboard popout, floating terminal/workspace and standalone-terminal surface; keep D3 decision until actually resolved. Add live workspace/relaunch GUI verification to #31. |
| #24 | Update acceptance to **29 remaining placeholder reference panes**, partial controls in the 10 existing bodies and full row/value search. Sidebar/page-name filtering is not full settings search. Link Shortcuts behavior to #39 and inert agent/default/notification/privacy controls to their backend issues. Correct Settings text saying notification delivery is unavailable. |
| #19 | Rename to “Git provider integrations: GitHub, GitLab, Gitea, Bitbucket and Azure DevOps”; title currently omits three providers already in the body. List PRs/reviews/issues/checks/tasks/API budget and per-provider credential strategy. Labels are otherwise appropriate. |
| #21 | Keep as a tracking umbrella or split skills/MCP/share, plugins and artifacts/own storage into separate issues. The body is too vague to verify all original scope; explicitly require discovery/install/update/rollback, bundled guides, MCP, host/cloud sharing, plugin consent/catalog/panels/workers and own artifact/account/profile/org storage. State-backup/profile export belongs to #46, not browser profiles. |
| #30 | Retain replay-size P3, IME (real Japanese/Chinese), complex ZWJ/BiDi, light mode/VoiceOver, mouse drag/SGR wheel/Shift override, reflow/momentum and newer T1b GUI checks. Remove old “unverified” claims for clear/Ctrl-L, SIGWINCH split/zoom, Ctrl-Z/fg, vim/less/top, true colour, basic selection/copy, OSC52/replay suppression and session tab click: T1 records passes. Theme imports/shell integration are #41, not completed by conformance checks. |
| #31 | Expand from the old short list to A3 group drag/reopen/restore, full shortcut/editor actions, Add Project clone/create, worktree composer/setup/adoption/cleanup, Explorer mutation/undo/drag/search/palette, new settings, browser profile/lifecycle/visible automation, attention notification/audio/Dock/relaunch and real provider hooks. Record specific observations; build/screenshot of one shell cannot close the whole backlog. |
| #23 | Keep host-session recovery/D2-D12, handshake/cancel semantics and launchd. Do not reintroduce the old core reconnect/token-rotation bug: a real-host regression test now exists. GUI auto-spawn/recovery remains #31. Replay-size P3 stays #30; coordinated state export/backup is #46. |
| #28 | Keep signing/notarization/update/CLI registration/crash/diagnostics; add cask/install/update rollback and explicit own telemetry/feedback endpoints/consent. Ad-hoc app/host/icon packaging already exists. Distinguish the packaged-hook executable defect #36 from general PATH installation. Keep **needs decision**. |
| #1 + #3 | Define editor E0–E7/durable writes under #1 and visual diff/review under #3. Git text diff alone does not deliver either surface. #1 is also the eventual target for file/terminal line-column routing; #35 owns current external-editor/terminal launch actions. |
| #8 | Keep **needs decision** for usage meters; name which provider account/hot-swap/usage behaviors ship. No account backend exists, so do not shrink the issue based on a Settings label. |
| #15, #16, #17, #18, #20, #25, #26, #27, #29 | Still valid. Add explicit corresponding CLI/settings/UI acceptance and record credentials/infra prerequisites where applicable. Transport scaffolding, provider glyphs and parsed recipe counts do not satisfy them. |
| #32 | Keep deferred companion scope explicit in body and parity metrics. **area: remote** is the closest existing label; no “area: mobile” label exists. Deferral is not implementation and is not a reason to apply **wontfix** without a new owner decision. |

No missing label names were invented. Available proposal labels are from the existing set: `area: shell`, `area: host`, `area: editor`, `area: agents`, `area: browser`, `area: orchestration`, `area: remote`, `area: integrations`, `area: distribution`, `parity`, `bug`, `needs decision` (and the standard GitHub labels). There is no exact duplicate that can safely be closed from code evidence alone.

## Proposed new issues for uncovered remaining work

These fill gaps that the current open issue bodies do not cover. Each body is three lines; the coordinator can create/split them and then replace proposal references with real issue numbers. Existing backend issues remain linked rather than duplicated.

### #33 — Complete workspace groups, navigation, checkpoints and cleanup integration

- Labels: `area: shell`, `area: host`, `parity`
- Area id(s): `projects`; audit WP: `PROJECTS-UX`

```text
Finish project-group CRUD/collapse/reorder, workspace sort/group/filter, lineage/parent navigation, Jump project rows and history/index shortcuts.
Expose persisted checkpoint comments/status on cards and host-owned sparse presets; pass activeWorktreeId to cleanup and add backend-specific blockers as those features land.
Verify create→setup tab→switch→relaunch plus bulk cleanup in the real app; keep protected workspaces out of default deletion.
```

### #34 — Finish Git base comparison, squash, AI commit messages and attribution

- Labels: `area: editor`, `area: host`, `parity`
- Area id(s): `git`; audit WP: `GIT-REMAINDER`

```text
Wire branchCompare/base selection into Source Control and finish branch auto-rename plus squash/conflict workflows.
Connect AI commit generation and AI-change attribution when the agent transport exists.
Use real temporary repositories and exercise conflict/amend/push error paths in the app.
```

### #35 — Finish file opening and Explorer launch actions

- Labels: `area: editor`, `area: shell`, `parity`
- Area id(s): `files`; audit WP: `FILES-UX`

```text
Add selected external-editor routing (VS Code/Cursor/default) and enable Open in Terminal with a cwd-owned shell action.
Replace interim default-app opening with editor line/column routing when #1 lands; retain explicit executable reveal behavior.
Exercise Explorer edits/undo/drag, Search and Go to File under #31; remote download remains #16.
```

### #36 — Fix bundled agent hook CLI and apply agent launch defaults

- Labels: `area: agents`, `bug`, `parity`
- Area id(s): `agents`; audit WP: `AGENT-LAUNCH-FINISH`

```text
Bundle/select a dedicated smthz CLI for hooks: the current sibling smthz executable is the GUI app, not the hook parser.
Consume agents.defaultAgent and setup wait-for-setup policy; finish per-launch trust/config behavior without changing global agent configuration.
Test a packaged fake agent end to end, then record real Claude/Codex version and hook conformance without assuming fake argv proves provider support.
```

### #37 — Implement agent dashboard, workspace sleep and awake lifecycle

- Labels: `area: agents`, `area: shell`, `parity`
- Area id(s): `agents`; audit WP: `AGENT-LIFECYCLE`

```text
Build the agent dashboard, hibernation/sleep/resume lifecycle and prevent-sleep assertions while agents work.
Preserve/restore launch context for restart chips across app relaunch and distinguish done from generic live workspace state.
Verify sessions, resources and assertions are released correctly on close, exit and host reconnect.
```

### #38 — Implement agent teams, handoff and generated titles

- Labels: `area: agents`, `parity`
- Area id(s): `agents`; audit WP: `AGENT-TEAMS`

```text
Promote captured child hook metadata into subagent/team rosters and an actual handoff workflow.
Add generated tab titles/text-generation paths with the chosen provider/account controls.
A claude-agent-teams launch id or OSC terminal title does not satisfy these behaviors.
```

### #39 — Finish shortcut dispatch, overrides, layout matching and menus

- Labels: `area: shell`, `parity`
- Area id(s): `shortcuts`; audit WP: `KEYS-REMAINDER`

```text
91 ids exist, but only 47 are available in the registry; six browser and three Explorer actions bypass that availability model.
Unify browser shortcuts with effective overrides/menu labels, implement the remaining 35 actions as backends land, and finish double-tap/layout-aware matching.
Complete menu/New Window behavior and record native-field/TUI/recorder/reset interaction checks.
```

### #40 — Complete local CLI commands and semantic compatibility

- Labels: `area: orchestration`, `area: host`, `parity`
- Area id(s): `cli`; audit WP: `CLI-REMAINDER`

```text
Add missing terminal show/switch/split/rename/pane-title/wait/stop, daemon status/restart, host context/name/list and app-open paths.
Complete project setup/reference and file/search CLI families, then expose other backends through their linked parity issues.
Audit flags, selectors, errors and JSON output against all 287 reference paths; aliases and callable routes are not full wire compatibility.
```

### #41 — Finish terminal shell integration, imports and link routing

- Labels: `area: shell`, `parity`
- Area id(s): `terminal`; audit WP: `TERMINAL-REMAINDER`

```text
Implement bash/zsh/fish readiness/history integration and Ghostty/Warp theme import.
Route URL/file links to the chosen browser/editor with modifier and line/column behavior; finish native input policy.
Keep IME/ZWJ/mouse/reflow/VoiceOver, Copy Context and input-source GUI acceptance in #30/#31.
```

### #42 — Complete attention feed, bell notifications and delivery verification

- Labels: `area: agents`, `area: shell`, `parity`
- Area id(s): `attention`; audit WP: `ATTENTION`

```text
Wire AttentionFeed into a dedicated Activity destination; .activity currently opens Mobile.
Implement background terminal-bell delivery, notification tests/tuning and remaining tray behavior; fix stale Settings delivery copy.
Exercise notifications/sounds under Focus, Dock navigation, read state and attention.json relaunch persistence.
```

### #43 — Implement engagement surfaces and decide social prompts

- Labels: `area: shell`, `needs decision`, `parity`
- Area id(s): `attention`; audit WP: `ENGAGEMENT`

```text
Track pet/stats, feature tips/wall and contextual tours separately from working notifications.
Decide whether the GitHub star prompt ships and provide smthz-owned feedback/social links before wiring them.
Do not treat sidebar labels or unavailable toasts as implemented screens.
```

### #44 — Implement runtime environments and ephemeral VM recipes

- Labels: `area: remote`, `needs decision`, `parity`
- Area id(s): `remote`; audit WP: `VM-ENVIRONMENTS`

```text
Add environment/VM provisioning, status/update/rollback/recovery/stop and recipe execution/doctor, with per-host ownership.
SmthzConfig currently counts environment recipes without executing them.
Choose infrastructure and credential boundaries before integrating a real VM provider; retain #16/#17 as remote prerequisites.
```

### #45 — Wire onboarding agent, integration and setup-guide steps

- Labels: `area: shell`, `area: agents`, `parity`
- Area id(s): `onboarding`; audit WP: `ONBOARDING`

```text
Replace disabled onboarding agent choices with the existing detected roster and apply the selected default to launch.
Connect provider setup to #19/#20 and add a persisted setup-guide checklist/reopen route.
Verify first launch, skip and reopen without overwriting existing settings.
```

### #46 — Add state backup and profile export/rollback

- Labels: `area: host`, `parity`
- Area id(s): `persistence`; audit WP: `PERSISTENCE`

```text
Persisted shell/workspace/settings data now exists, but coordinated backup and profile-state exports/rollback do not.
Define an own-state export/restore boundary and test interrupted/corrupt/future-version restore without importing Orca state.
Conflict-safe durable editor writes stay in #1 and host-restart session behavior stays in #23.
```

## Functional-gap coverage check

All **26** areas are below 100% functional under the audit checklist. Every area has existing and/or proposed implementation coverage below; #31 is verification coverage and is not used as a substitute for missing implementation. `parity-status.json` lists only existing issue numbers; proposals stay in this document until the coordinator creates them.

| Area id | Existing implementation issues | Proposed implementation issues | Verification / residual scope |
|---|---|---|---|
| terminal | #30 (conformance), #13 (browser tab kind) | #41 | #31; newer context/input-source/clipboard settings GUI |
| windows | #22 | — | #31; standalone SSH additionally #16 |
| projects | #22 (window portion) | #33 | #31; registry/worktree host core already delivered |
| git | #3 (diff/review portion) | #34 | #31; actual source-control remainder not covered by #3 alone |
| files | #1 (editor handoff), #16 (remote files) | #35 | #31; local ops/search backend already delivered |
| editor | #1, #2, #3 | — | engine/edits/viewers/diff/review |
| agents | — | #36, #37, #38 | #31; no existing agent lifecycle implementation umbrella |
| chat | #4, #5, #6, #7 | — | live provider + reachable UI |
| accounts | #8 | — | provider credentials and meters decision |
| history | #7, #9 | — | catalog/FTS/resume/memory |
| browser | #10, #11, #12, #13 | — | update #10/#11 acceptance as above; #31 GUI |
| orchestration | #14 | — | real workers/coordinator/federation/UI |
| cli | #14–#17, #19–#21, #23, #25–#28 (their command families) | #40 | exact flags/results/contracts still need comparison |
| automations | #15 | — | scheduler/history/prechecks/page/CLI |
| integrations | #19, #20 | — | all providers/tasks/checks; no services yet |
| settings | #24 | #39 (shortcut semantics) | partial existing panes plus 29 placeholders |
| attention | — | #42, #43 | #31; delivered transitions/Dock are only a slice |
| mobile | #32; #17 prerequisite | — | accepted deferral, no companion backend |
| remote | #16, #17, #18 | #44 | SSH/Linux/auth/ports/VMs |
| library | #21 | — | enumerate MCP/sharing/plugins/own storage in issue update |
| tools | #25, #26, #27 | — | helpers/model/emulator runtimes |
| distribution | #28 | #36 (bundled hook CLI) | identity/signature/feed/diagnostics/PATH |
| onboarding | #19, #20 (provider setup dependency) | #45 | #31; default-agent/setup-guide wiring |
| shortcuts | #24 (editor/pane) | #39 | #31; dispatch/override/layout/menu scope |
| persistence | #1 (conflict-safe writes), #23 (host recovery) | #46 | #30 replay-size; backup/export distinct from corruption backup |
| performance | #29 | — | Orca baseline before comparative claims |

Accepted English-only and Windows/WSL exclusions are shown in the audit but generate no new issue. Browser reductions, unknown signing/infra choices and live-agent compatibility remain explicit decisions/verification gaps; this audit accepts none on the owner's behalf.


# UI-29 wiring

Implemented 2026-10-25; state ownership updated by WP-A0. ShellController now applies the SmthzCore ShellCommand/ShellState model, executes host effects in a background actor, and persists the layout and bindings through ShellStateStore. Package.swift, SmthzCore, Theme, reference and icon were not edited by A0.

## Entry points

“Real” means a local action or an existing host RPC. “Stub” means a reachable, clearly unavailable surface with no simulated backend mutation. Existing disabled controls remain disabled.

| Entry point | Result | Status |
|---|---|---|
| App launch; automatic host recovery | Bundled `smthzd` via HostLauncher, default `autoStartHost=true`; authenticated probe before spawning, three attempts per 60 seconds | Real; disabled whenever `SMTHZ_SOCKET` is present |
| `-SmthzStateDirectory <path>` | Shell persistence and host endpoint both use the selected directory | Real; `SMTHZ_SOCKET` overrides the socket only |
| Host → Status | Current connection/lifecycle detail in a native alert | Real |
| Host → Start Host | Ensure running; unreachable/authentication/protocol errors never cause a spawn | Real |
| Host → Stop Host… / Restart Host… | Native confirmation lists running sessions, then HostLauncher authenticated shutdown with process-identity-verified fallback; Restart explicitly starts a replacement | Real; explicit Stop suppresses automatic relaunch for the current app lifetime |
| Host → Start Host Automatically | UserDefaults `autoStartHost`, default true | Real; independent of quit, which preserves host sessions |
| Host → Show Host Log | Open host log using the system default application | Real routing; not exercised |
| Host version mismatch | Status text and warning symbol; manual Restart requires confirmation | Real; never automatically restarts a live host |
| Host unreachable / failed / throttled | Status bar text, symbol and detail; Host menu exposes log and retry | Real; shared across windows |
| App quit / last window close | Flush shell state; detached host and sessions continue | Real; quit exercised for A1 |
| Cmd-T; tab `+` → New Terminal | `session.create`, select returned session, return from Settings/destinations | Real |
| Tab `+` search → existing tab | Select session and display its replayed output | Real |
| Tab `+` agent/browser/emulator/Markdown rows | Visible disabled choices with unavailable tooltips | Stub: M4/M5/WebKit/editor |
| Cmd-W; tab close; exited-terminal Close | `session.foreground`, pinned/running confirmation when required, then `session.close`; remove closed tab locally | Real |
| Pinned/running confirmation Cancel or Escape | Leave session open | Real |
| Confirmation “Don't ask again” | Existing persisted confirmation preference | Real |
| Tab context Close Others | Bulk confirmation; close unpinned candidate sessions only | Real |
| Tab context Pin/Unpin | Persisted model pin state; Cmd-W can explicitly confirm pinned closure | Real |
| Tab double-click / Change Title; Cmd-R | Persisted custom tab title; explicit rename takes precedence over persisted OSC pane title | Real |
| Tab Color | Persisted model colour retained through switching, reordering and relaunch | Real |
| Copy Tab ID | Pasteboard plus success/error SmthzToast | Real |
| Drag tab | Apply model moveTab, preserve the selected session, persist tab order | Real |
| Ctrl-1…9 | Select tab in displayed order | Real |
| Ctrl-Tab | Switch to previous recent visible tab | Real; no separate recent-switcher overlay |
| Tab split/move/equalize/expand controls | Wired to ShellController pane commands (A2); menu items not clicked by coordinator, only keyboard splits verified | Real: M3 A2 |
| Command button | QuickCommandsMenu with search, Global/Default workspace scope | Real |
| Quick commands Add/Edit/Copy/Delete | Existing shared store, editor/deletion dialogs, UserDefaults persistence | Real |
| Quick command Run | `session.write` with the configured text and optional CR | Real |
| Terminal context Quick Commands submenu | Saved commands execute through the terminal's serialized write stream; Add opens shared editor | Real |
| Terminal OSC title/directory | Update tab title/hover directory, file palette root and right-sidebar root; user title wins | Real |
| Terminal right-click Copy/Select All/Paste/IDs/Clear/Reset | Existing emulator/pasteboard actions | Real |
| Terminal context Set Title / pane IDs / split controls | Wired to the owning pane (A2); menu clicks not exercised by coordinator | Real: M3 A2 |
| Cmd-F in terminal | Existing terminal find bar, previous/next, case and regex options | Real |
| Cmd-K; Terminal menu Clear Screen | Clear local emulator without sending a shell command to a running program | Real |
| Terminal log replay (app relaunch, new controller for a running session) — T1 | History is fed with emulator query replies dropped (`FocusingTerminalView.send(source: Terminal)`), replay end read via `session.read` past the end | Real: verified in the app (before: `2R1R65;20;1c12;2$y` typed into the prompt after relaunch; after: none). Not exercised: a TUI still waiting for a reply at relaunch |
| OSC 52 clipboard writes — T1 | `TerminalClipboardPolicy`: on by default (`terminal.allowOsc52Clipboard`), blocked during replay, 96 KiB cap, reads (`52;c;?`) never answered | Real: write, read denial, setting off (launch-argument domain) and replay block verified in the app (control build without the fence overwrote the clipboard). Settings toggle row is owned by the settings lane |
| Option as Alt "auto" — T1 | `TerminalOptionKey`: Alt only on ABC/US input sources, follows input-source changes; "off" composes dead keys | Real at terminal creation and on input-source change (Option-B word-back on ABC, Option-E dead key with `off` verified). `TerminalSettingsModel.apply` still sets `optionAsAlt != "off"`; not exercised with a real IME or a non-US layout |
| First pane focus (Landing → Cmd-T) — T1 | Focus requested before the pane reaches a window is granted in `viewDidMoveToWindow` | Real: verified (typing right after Cmd-T from Landing reaches the new session) |
| Exit overlay Restart | Model restartPane creates a replacement session with the original executable/arguments and current directory/grid; stable tab identity retains title/colour/pin/order | Real |
| Cmd-J; sidebar Search; View → Open Worktree Palette | Jump palette populated with open sessions, Default workspace, actions and Settings pages | Real |
| Jump palette Open Tab / Default workspace | Select target / return to workspace | Real |
| Jump palette New Terminal / toggle sidebars / Settings row | Dispatch corresponding action, including requested settings page | Real |
| Jump palette projects/tasks | No fabricated project/task rows | Stub: M4/providers |
| Cmd-P; View → Go to File | Bounded file scan under selected session cwd | Real listing |
| File palette Open | Informational toast “File editor — Not available yet”; no external application opens | Stub: editor |
| Cmd-N; sidebar New workspace; landing Create workspace; project header `+` | NewWorkspaceComposer, preselecting the active (or header's) Git project | Real (WP-M4-WORKTREE-APP); see that section |
| Composer Create with no project | Create host shell; existing Create more behaviour retained | Real fallback (only when no Git project is registered) |
| Composer Add project / Agent settings | AddProjectDialog / Settings → Agents | Real routing; backends stub |
| Sidebar / landing Add project; onboarding Add project | AddProjectDialog | Real routing |
| Add Project Browse folder | NSOpenPanel → `repo.scanNested` → `repo.add` (Git repo or plain folder), or the nested-import view (`projectGroup.importNested`, group or separate, "Add folder only") | Real (WP-M4-REGISTRY); see that section for what was exercised |
| Add Project create/clone/SSH | Create new project (`repo.create`, optional `git init`) and Clone from URL (`repo.clone` job, progress, cancel) are real forms; SSH and the remote host picker stay disabled | Create/Clone real (WP-M4-REGISTRY); SSH stub until M7 |
| Default workspace select; Reveal active workspace | Return to Default workspace | Real; one card only |
| Workspace Update/inline rename, Pin, Mark Read/Unread | Window-local card state | Real presentation state |
| Workspace Open in Finder / Copy Path / Copy Worktree Name | Selected cwd and pasteboard actions | Real |
| Workspace Remove Workspace / hover delete | Worktree cards: DeleteWorkspaceDialog → `worktree.remove` (WP-M4-WORKTREE-APP). Default workspace: unavailable toast | Real for worktrees; Default workspace stub |
| Workspace sleep/status/parent; project icon/group/remove/settings | Project header menu: Remove Project is real (`repo.remove`, refused with a toast while terminals run inside it, files never deleted). Card menu: Edit details/parent, Remove from Parent, Repository Settings, Review Preserved Branches real (WP-M4-WORKTREE-APP); Sleep, Move to Status, Open Parent, project icon/group entries disabled | Partly real; Sleep/status stub |
| Workspace options menu | Existing locally persisted sort/group/filter settings | Real preference; multiple-workspace effects deferred |
| Sidebar activity / board | Existing visual activity empty state / board button state | Stub: agents/board backend |
| Tasks nav/provider glyphs | SmthzTasksPage | Stub: providers; glyph route opens Tasks, provider selection remains local to page |
| Automations nav | SmthzAutomationsPage | Stub: scheduler; no fake runs |
| smthz Mobile nav | SmthzMobilePage | Stub: own relay/auth/mobile app |
| Destination close button / Escape | Return to workspace | Real |
| Cmd-,; sidebar Settings; menu Settings | Settings → Appearance | Real routing |
| Help → Keyboard Shortcuts (sidebar and app menu) | Settings → Shortcuts | Real deep link to the Shortcuts editor (WP-SETTINGS-SHORTCUTS) |
| Settings Appearance / Terminal | Existing persisted theme and terminal controls | Real where already supported; other controls disabled |
| Settings › Shortcuts editor (`Settings/ShortcutsPane.swift`) | 91-action registry grouped like Orca; Find shortcuts (title/id/group/keys) + page search; status filters All/Modified/Unassigned/Conflicts with counts; record (⎋ cancels), add another, remove, disable/enable, reset one, Reset All (menu, confirmed); conflict refusal with deliberate pairs (`KeybindingOverrideFile` + `KeybindingRegistry.conflictingActions`); digit rows shown as 1–9; unavailable actions dimmed "Not available yet"; "Not from terminal" badge for chords the terminal keeps; diagnostics list; file menu Open with Default App / VS Code / Cursor / Reveal in Finder / Reload from Disk | Real: writes `<state-dir>/keybindings.json` atomically and reloads `SmthzKeybindings.shared` (menus, keycaps, monitor). Verified in the app: pane renders 91 rows; editing the file updated View › Switch worktree to ⇧⌘K and the row to "Modified". **Not exercised in the GUI:** recorder click + capture, add/remove/disable/reset buttons, Reset All, file menu, Esc while recording (the window Escape monitor may close Settings first). Double-tap modifier bindings and "Shortcuts in Terminal" policy are VISUAL-ONLY |
| Settings › Terminal: GPU Acceleration, Color Contrast (+ target), Cursor Opacity, Scroll Speed Normal, OSC 52 clipboard writes, Ask Before Closing Running Terminals | `TerminalSettingsModel.apply` (SwiftTerm `setUseMetal`, `minimumContrastRatio` auto 4.5/3, caret alpha, `scrollSensitivity`); close confirmation = inverse of `confirmations.skipRunningTerminal` | Real preferences; terminal values reach terminals open at change time only (surfaces do not call `apply` on creation, terminal lane). "Allow TUI Clipboard Writes (OSC 52)" toggles `terminal.allowOsc52Clipboard` (read by `TerminalClipboardPolicy`). Fast/TUI scroll, padding, divider, other copy/paste/mouse rows, opacity/blur stay VISUAL-ONLY. Not exercised in the GUI (shared UserDefaults domain) |
| Settings › Appearance: UI Zoom stepper, Titlebar App Name, Show Status Bar, Workspace Card Layout | `shell.uiZoom`, `shell.showTitlebarAppName`, `shell.showStatusBar`, `sidebar.cardLayout` (same keys the shell already reads) | Real preferences; card layout has no compact rendering yet. Not exercised in the GUI |
| First launch, `onboarding.completed` absent/false | Six-step onboarding; completion saved on Finish | Real gate |
| Help Onboarding / Getting Started | Reopen onboarding without erasing saved completion | Real |
| Onboarding Language/Appearance/Notifications | English selection, real theme, explicit notification permission request | Real; notification request not exercised |
| Onboarding Agent/Integrations | Existing disabled choices and unavailable copy | Stub: agents/accounts/providers |
| Onboarding skip | Existing skip confirmation → project step | Real |
| Help Explore smthz | Return to workspace landing | Real local route |
| Help Send Feedback / Check for Updates | Informational unavailable toast | Stub: no feedback/update service |
| Help Restart smthz | Existing bundled-app relaunch action | Real existing action; not exercised |
| Cmd-B / Cmd-L; title/sidebar buttons | Persisted left/right sidebar visibility | Real |
| Cmd-Shift-E / G / I; activity icons | Open right sidebar and select Explorer / Source Control / Ports | Real routing |
| Explorer / Source Control | Active cwd; existing FileManager and read-only GitService panels | Real |
| Right sidebar Agents / Checks / Ports / Attached worktrees | Existing empty states and controls | Stub: agents/providers/scanner/M4 |
| Right activity bar Top/Side | Existing persisted placement | Real |
| Status Resource Manager | HostMonitor session list and measured process memory; live PTY count | Real |
| Resource Manager Go to terminal | Select existing model tab or explicitly adopt the corresponding host record, including an exited record; leave Settings/destination | Real |
| Resource Manager End → confirm | `session.close`, hide its tab, host snapshot reconciles status | Real |
| Status visibility context menu / View Show Status Bar | Existing persisted visibility preferences | Real |
| Status Ports / SSH / floating controls | Existing unavailable controls/empty-state UI | Stub: scanner/SSH/M3 A7 |
| View title-name/sidebar-button preferences; title-name context Hide App Name | Existing AppStorage preferences | Real |
| Cmd-= / Cmd-minus / Cmd-0 | Existing whole-interface zoom commands | Real |
| Escape with overlay/settings/destination, including AppKit terminal focus | Window-scoped key monitor dismisses top surface / returns to workspace; does not swallow ordinary terminal Escape | Real |

## Changes outside the two primary files

All are in Sources/SmthzApp and expose/connect integration hooks:

- `TabStripView.swift`: optional bulk-close, colour-change and copy-result closures forwarded to tab items. Old adapter remains source-compatible but ShellView now owns the actual composition.
- `Settings/SettingsView.swift`: `initialPage` parameter for deep links.
- `Slots/RightSidebarSlot.swift`: consume ShellController.rootURL, including terminal directory callbacks.
- `Slots/StatusBarSlot.swift`: optional selection callback, centralized model close, live session count.
- `Terminal/TerminalContextMenu.swift`: saved-command submenu and Add action; write callback.
- `TerminalSessionView.swift`: connect submenu writes/Add notification and receive window session-specific clear notifications.

Primary changes: `ShellView.swift` composes/routes all surfaces and confirmations; `ShellController.swift` replaces the deleted `WorkspaceModel.swift` and owns durable shell state, model commands and serialized host effects. Tab titles, colours, pins, order, MRU/selection and bindings persist in `<state-dir>/shell-state.json`; `-SmthzStateDirectory <path>` overrides the default Application Support directory. Saves debounce by 250 ms, with synchronous termination flush and a mandatory pre-create flush. Pending create/restart parameter records beside the state file preserve exact request parameters across interrupted replies and are removed after a durable binding. Workspace pin/unread flags and runtime OSC directories retain their previous in-memory presentation semantics.

## Verification

- `SMTHZ_SCRATCH_PATH=.build-ui29 scripts/package-app.sh debug`: passed, packaged ad-hoc signed app.
- Final full-suite runs: **211 tests / 19 suites passed three times**, 6.269 s, 6.332 s, 6.077 s. Logs retained in `/tmp/ui29/test1.log` through `test3.log`.
- Used private `.build-ui29/debug/smthzd --socket /tmp/ui29/h.sock --journal /tmp/ui29/j.db`; app opened with SMTHZ_SOCKET pointing there.
- Cmd-T created a real host session; idle Cmd-W closed it without a prompt. With a confirmed running `sleep 100`, Cmd-W displayed Stop running command; Cancel left it running. Pinned close and bulk-close dialogs were opened. Ctrl-3 selected the third session. Cmd-J opened and Escape dismissed the palette after the window-scoped fix.
- Resource Manager End displayed “End zsh?” with the exact session pid; confirming changed that host record from running to exited. No host RPC was mocked.
- Fresh-default onboarding appeared; Finish reached the shell. Appearance Dark changed the live UI. Help → Keyboard Shortcuts reached the existing Shortcuts placeholder. Tasks, Automations, Mobile, file palette, composer, Add Project, quick-command editor, terminal/tab/workspace menus and find bar were opened.
- Screenshots captured with `screencapture` are in `docs/ui29-screenshots/`. Light and dark captures are a tour across surfaces, not every surface in both themes. Captures from earlier passes document their opened surfaces; the final native quick-command submenu, pinned confirmation, Shortcuts deep link and resource End confirmation were checked visually.
- Build warnings (EventJournal unused withUnsafeBytes, StatusBarView missing Combine import, `Selector("cut:")` in SmthzApp, non-Sendable StoreDiagnostics) fixed 2026-10-31 by WP-HYGIENE, build/tests only; the app was not launched for that change. Remaining: SwiftPM "114 unhandled files" warning (needs `Package.swift`).

## Limits and follow-up checks

No pixel-by-pixel Orca parity claim. Not all hover states, zoom steps, reordering, colours, every shortcut, OSC callback, terminal restart, copy/paste, search matches, modal Return behaviour or sidebar Git repository states were exercised. The AX set-value attempt in the quick-command editor changed native field values but did not enable Save, so an actual UI save/run round trip is **not verified**; the shared store and write paths are connected, not claimed tested end to end. A bounded scan of the home cwd reached its ceiling before producing file matches; scan ordering belongs to UI-23. The native terminal submenu also receives macOS's automatic AutoFill menu addition.

A0 resolves automatic reappearance of closed, host-retained exited records: reconciliation only adopts unattached running sessions. A bound tab can still show its exited session, and Resource Manager can explicitly reopen an exited record. Foreground confirmation observes a point-in-time host verdict; the first immediate close after injecting sleep raced shell command startup and closed before the running-command prompt, while the later check after sleep was established correctly prompted. No backend changes were made to address that race.

The app used for the earlier tour was no longer running when work resumed; there was no new matching crash report, so the cause of exit is unproven. Final packaging and host checks were repeated. The private app/host processes and sessions were stopped at cleanup; the temporary build scratch directory was removed, and build/smthz.app remains available.


## WP-A0 verification (2026-10-25)

- Rebuilt and packaged with `SMTHZ_SCRATCH_PATH=.build-a0 scripts/package-app.sh debug`; Xcode toolchain, separate scratch path, no package or core changes.
- Private host: `.build-a0/debug/smthzd --socket /tmp/a0/h.sock --journal /tmp/a0/j.db`. App: `open -n --env SMTHZ_SOCKET=/tmp/a0/h.sock build/smthz.app --args -SmthzStateDirectory /tmp/a0/state`.
- Fresh state → Cmd-T → quit/relaunch retained session `9a82e2c9-45d8-44a9-9fca-27177166031f`, without increasing the host's session count. The state contained one tab/pane/binding and the restored terminal showed its prompt.
- Clicked Close on the idle tab: host record became exited and durable tab disappeared. Quit/relaunch showed zero tabs with the exited record still retained by the host.
- Simulated a committed create whose reply was lost by replacing its binding with its actual journaled pending request ID. Relaunch rebound `e240c013-5ce6-45fd-a01b-f4aac1e98659`, cleared pending state, and left the complete host session list unchanged. This was an explicit state fixture, not a claim of crashing at the exact reply boundary.
- That fixture also set a custom title/purple colour/pin; the restored app rendered all three. Restart from the exit overlay retained the tab/pane IDs and presentation while replacing the bound session.
- Created a separate `/bin/cat` through the real CLI; HostMonitor adopted it, Ctrl-2 selected it, and the exit overlay restarted it as `/bin/cat` (confirmed with `ps`), rather than zsh. Completed create parameter files were removed.
- Evidence: `/tmp/a0/before.png`, `final-restored.png`, `closed-relaunch.png`, `pending-restored.png`, `restarted.png`, `cat-restarted.png`; full logs and fixture states are retained under `/tmp/a0`. No command was typed into another app.
- A0 adds no core logic/tests. The concurrent H3 worker expanded the suite from 254 to 268 tests. Full results and captured pre-existing/concurrent failures are recorded in `/tmp/a0/report.md`; the full first failure logs were sent to the coordinator.
- This is a focused state-ownership verification, not a repetition of the full UI-29 tour. Inline rename AX set-value changed the displayed draft but did not commit through synthetic Return, so an actual rename/save round trip remains unverified. All existing quick-command, palette, confirmation, settings and terminal hooks remain connected; their earlier UI-29 verification limits above still apply.


## WP-A1 host integration (2026-10-25)

`HostController.swift` owns one process-wide HostLauncher and lifecycle monitor. The bundle resolves `smthzd` using `Bundle.main.url(forAuxiliaryExecutable:)`, with a sibling-binary fallback when unbundled. `package-app.sh` builds both products and copies the host before ad-hoc deep signing, retaining the existing scratch-path, resources and icon compilation behavior.

Minimal hooks outside the primary A1 files: `ShellController.swift` resolves its socket through the shared endpoint configuration; `Slots/StatusBarSlot.swift` forwards lifecycle text/detail/symbol; `StatusBarView.swift` accepts that optional symbol. `SmthzApp.swift` only adds the Host menu command set, and `ShellView.swift` only passes the shared lifecycle status owner to its existing status item.

Focused acceptance evidence and full logs are in `/tmp/a1/`: bundled host executable and deep signature verified; fresh `/tmp/smthz-a1` host answered ping in 0.542 seconds with one matching process; connected status screenshot `connected.png`; the host retained a real `/bin/sleep 300` session after app quit; Stop Host confirmation `stop-confirm.png` listed a live session, and confirmation removed host/child and socket. `SMTHZ_SOCKET=/tmp/a1-private/h.sock` with an absent external host started nothing and disabled lifecycle actions (`private-host-menu.png`). No terminal text was typed into any application.

Test results and concurrent scrollback-test changes are detailed in `/tmp/a1/report.md`; A1 changes no core or test files. These checks do not claim the full M3 verification matrix, a visual mismatch/throttle fixture, or a launchd service.

Final A1 sheet checks additionally verified that Cancel preserved host PID 93500 and sleep PID 94944; confirmed Restart replaced the host with PID 95077 and ended that child; confirmed Stop left no host. See `/tmp/a1/menu-check.log`, `restart-cancel-final.png`, `restart-confirm-final.png`, and `stop-confirm-final.png`. Confirmation refreshes session inventory before presentation and explicitly warns when only a cached inventory is available. Baseline suite run passed 268 tests; subsequent concurrent scrollback changes grew it to 274 with a stale `HostLifecycleTests.swift:172` fixed-size assertion still failing, and one additional transient descriptor assertion in run 4. Full logs were delivered to the coordinator; three final green runs are still required after the concurrent test update.

### WP-A3 groups (2026-10-31, shell lane)

| Entry point | Behaviour | Verification |
|---|---|---|
| Tab context menu → New Group from Tab | Creates a model group; a sole tab names its current group | Core command tests; GUI pending (desktop locked) |
| Group header / context menu | Collapse/expand, rename, colour, ungroup; state saved by ShellStateStore | Disk save/load test, backward-compatible metadata decode; GUI pending |
| Drag tab onto group header / Move Tab Here menu | Moves across groups, collapses empty source, preserves pinned boundary | Core movement/pinned tests; drag GUI pending |
| Reopen Closed Tab / Close All / Close Others / next and previous | Bounded core closed stack, fresh host session via effects; bulk close preserves pinned tabs and asks confirmation | Existing snapshot/cwd/title/colour tests; private GUI Cmd-T created 2 sessions; reopen/close GUI pending |

A3 isolated build passed; initial full suites passed 278 tests twice. The third run picked up a parallel host test (279 total) and failed its executable discovery, reported to the coordinator. Group menus, screenshots and app relaunch restore were not proved: loginwindow became frontmost; coordinator authorized continuing A5 without those GUI checks.

### WP-A5 keybinding registry (2026-10-31, shell lane)

| Entry point | Behaviour | Verification |
|---|---|---|
| File/View/Tabs/Terminal/Other Actions menus | All 91 reference actions retain ids, titles, groups, scopes, default chords and explicit conflict groups; 43 actions wired, 48 unavailable and disabled | Build + metadata/default/scope/conflict tests; GUI pending |
| `<state-dir>/keybindings.json` | JSON object from action id to chord string array; `[]` unbinds; reload on app activation; malformed records keep the previous/default action binding; malformed JSON falls back to defaults; diagnostics log and toast | File-read/parse/unbind/conflict tests |
| Tab/pane event monitors and numeric selectors | Effective registry handles each alternate chord, Ctrl-Tab and 1–9; digit override expands 1–9; ordinary Ctrl-letters and Option-as-Meta are left to the TUI | Pure policy/digit tests; GUI TUI check pending |
| Landing and create/context menus | Keycaps and menu equivalents read effective bindings; unavailable workspace-navigation hints hidden | Build; GUI pending |
| Native edit fields | Standard copy/paste/select-all bindings retained in native fields; effective terminal bindings used in terminal menus | Build; GUI pending |
| D7 | Cmd-N reserved for New Window (disabled until A4), Cmd-Shift-N composer, Cmd-T shell, Cmd-=/-/0 change terminal font size | Core defaults checked; GUI pending |
| View → Force Reload | Native equivalent restarts host observation/reconciliation; terminal sessions stay host-owned | Build; GUI pending |
| Help → Check for Updates / Report Crash | Explicit unavailable alerts until service backends exist | Build; GUI pending |

Only the two pre-A5 Cmd-T shell creations were seen in the private app before the desktop locked. **Every A5 wired action below remains unexercised in the real app**, including overrides and menu enablement; coordinator explicitly accepted this verification gap for later manual testing:

- `worktree.quickOpen`
- `app.settings`
- `app.forceReload`
- `worktree.palette`
- `workspace.create`
- `view.tasks`
- `sidebar.left.toggle`
- `sidebar.right.toggle`
- `sidebar.explorer.toggle`
- `sidebar.sourceControl.toggle`
- `sidebar.checks.toggle`
- `sidebar.ports.toggle`
- `zoom.in`
- `zoom.out`
- `zoom.reset`
- `tab.newTerminal`
- `tab.close`
- `tab.closeAll`
- `tab.rename`
- `tab.reopenClosed`
- `tab.nextSameType`
- `tab.previousSameType`
- `tab.nextAllTypes`
- `tab.previousAllTypes`
- `tab.previousRecent`
- `tab.nextTerminal`
- `tab.previousTerminal`
- `tab.selectByIndex`
- `tab.openQuickCommandsMenu`
- `terminal.copySelection`
- `terminal.selectAll`
- `terminal.paste`
- `terminal.search`
- `terminal.clear`
- `terminal.focusNextPane`
- `terminal.focusPreviousPane`
- `terminal.equalizePaneSizes`
- `terminal.expandPane`
- `terminal.setTitle`
- `terminal.clearPaneTitle`
- `terminal.closePane`
- `terminal.splitRight`
- `terminal.splitDown`

`TerminalSessionView.handleShortcut` received the coordinator-authorized small change from hard-coded Cmd-F/Cmd-K checks to registry matches; no host/streaming code was changed by this lane. `LayoutSplitView` changes are confined to its shortcut helper. The registry retains unavailable backend actions for future implementation rather than dispatching placeholder shortcuts.

Final shell-lane verification: build and `scripts/package-app.sh debug` passed with `/tmp/smthz-shelllane` as the only scratch path. Two of three final full-suite runs passed **291 tests** (17.845 s, 16.924 s); the third failed only `SessionStreamTests.disconnectAndReconnectResumeFromConsumedCursor` (`Caught error: .closed`, 0.784 s), owned by the parallel host/stream lane. The coordinator copied the full failure logs and explicitly authorized finishing this lane without waiting for that fix; the required three consecutive full-suite passes are therefore **not achieved**. Eight shell-lane tests were added (`@Test` on each); all shell/group/keybinding tests passed in the final runs. Package.swift, .gitignore and protected directories were untouched by this lane; no git write commands were used. Final app was packaged but not launched while the desktop was locked; private app/host were stopped and own scratch/state/logs removed.

## WP-M4-0 HOSTCORE — 2026-10-31

| Entry / component | State | Exercised |
|---|---|---|
| `HostService` → `HostRouter` read/mutation/job classes | Real; auth/version/64-pending admission remain ahead of routing; reads bypass host/journal locks, writes retain canonical request-id replay; immediate mutations and background jobs share a repository gate | Read journal emptiness, concurrent terminal write during a 3 s job (<100 ms), repository serialization, 64-request cap, deadline killing Git, typed/raw error detail |
| `job.get`, `job.cancel`, `job.list` → `HostJobs` | Real; bounded 1,000-event/256 KiB log, sequence filtering, progress, 15-minute finished-job retention; stop cancels and waits for worker threads | Same jobId on request retry, conflicting params, queued cancellation, real Git/helper process-group cancellation, bounded logs |
| `<state-dir>/workspace.sqlite` → `WorkspaceStore` | Real schema v1; WAL, foreign keys, locked transactions/bound helpers, `user_version` migration, canonical paths, validated lineage helper, interrupted-operation reconciliation | Empty → v1, reopen v1 with preserved rows, future-version rejection, rollback/FK restrictions/concurrent access, lineage cycle/cross-repo refusal, creating/removing → failed/remove_failed + hostRestarted |
| `GitService.run` | Real `userContext` / `isolatedRead`, optional stdin and per-call timeout, streaming stderr/progress, typed authentication error; Foundation child group verified before signalling | Temp-global identity commit vs isolated failure, hooks and stderr, stdin hashing, timeout/cancellation, recorded progress strings; no network Git operations exercised |
| `WorkspaceSelectors` | Real id/path/name/branch/current/active resolver, canonical longest-prefix path match, ambiguity candidates, default repo from cwd | Unit tests including repo-selector restrictions and explicit-repo error |
| CLI common hook, `--json`, `job list/get/cancel/wait` | Real JSON envelopes and raw host detail; polling wait prints phases and sends job.cancel on Ctrl-C, exit 130 | Private real host ping/session lifecycle/job.list; controlled socket-server CLI wait/Ctrl-C check observed job.cancel and exit 130 |
| `RepoRPC`, `WorktreeRPC`, `GitWriteRPC`, `FilesRPC`, `CleanupRPC`; CLI `RepoCommands`, `WorktreeCommands` | **Stubs** for later M4 owners; unregistered RPCs / command stubs return unknownMethod | No domain CRUD, worktree lifecycle, Source Control or Files UI claimed |

Extension contract: register handlers with `router.register(method, methodClass:repository:handler:)`; repository closures must resolve the canonical repository identity (including when params contain a worktree path). Job-class handlers validate synchronously, call `router.jobs.submit(repository:work:)`, and return jobId; job work uses its `HostJobContext.processControl` and event callback. Immediate Git handlers use `HostRequestContext.processControl` and cancellation checks. Store extensions compose bound `execute`/`query` calls within `transaction`, canonicalize paths before writing, and use `setLineage` for lineage changes. `HostClient.rawCall` preserves the complete payload; `callWithDetail` throws a detailed error while existing `call` keeps its original error API.

Added **25 `@Test` tests** in HostRouterTests, HostJobTests, WorkspaceStoreTests, GitRunModeTests and WorkspaceSelectorTests. Coordinator-approved existing-test migrations: HostServiceTests `hostPing`, `hostIdempotency`, `hostDifferentRequestIDs`, `hostConcurrentIdempotency`, `hostJournalFailures`, `hostSocketRoundTrip`; RPCHardeningTests `versionAndAuthenticationFailBeforeJournal`, `idempotencyBindsCanonicalParamsAndMethodAcrossRestart`, `queuedRequestCancellationAndDeadlineUseIndependentSocket`; HostMonitorTests fixture request counting (the stop-test assertions remain intact). Journal-kind/payload/replay/failure assertions moved from ping reads onto session.resize mutations; blocking queue-test workers use dedicated Threads and the new gate test explicitly signals its attempted gate.

Final verification: **build passed; 369 tests passed five consecutive times on the frozen final code** (21.085 s, 24.252 s, 31.845 s, 30.566 s, 23.120 s; final10–final14). This includes the 292-test starting baseline, 25 HOSTCORE additions, and 52 additions from the parallel CONFIG lane. Private-host ping/session/job.list JSON e2e passed, as did CLI wait/Ctrl-C against a controlled socket server; all HOSTCORE temporary test fixtures were removed and the private host exited with its socket removed. HOSTCORE did not edit Package.swift or protected paths; the parallel CONFIG lane changed the package for Yams. No GUI checks were attempted in this host-only work package; real network credentials/remotes, submodules/LFS, and wall-clock expiry of the 15-minute job-retention period were not exercised. One earlier full run had `SessionStreamTests.orderedBinaryOutputAndExitWithReadCompatibility` report `.closed`; its full log was copied by the coordinator, the stream implementation itself is unchanged, and no root cause has been established. A separate new-test scheduling failure was corrected with the explicit Thread/gate-start signal; the subsequent required five-run sequence covers all streaming tests as well.

HOSTCORE cleanup: its `/tmp/smthz-hostcore-sol` build/state/log/server directory was removed after verification; no HOSTCORE host/Git/CLI processes remained. A separately owned `/tmp/smthz-t1/debug/smthzd` process (pid 26069) was observed and left untouched.

## WP-M4-SCWRITE — 2026-10-31

Supersedes the "Explorer / Source Control" row above for Source Control: the panel no longer calls `GitService` for status; every Git read and write goes through host `git.*` RPC. Only the work tree top level is still discovered in-process (`GitService.repository(at:)` on the active cwd).

| Entry point | Behaviour | Status |
|---|---|---|
| Host `git.status/upstreamStatus/branchCompare/diff/history/branches/stashList/checkIgnored` (read) | `GitWriteRPC.swift` + `GitSourceControl.swift`; status adds upstream, ahead/behind, `operation` (merge/rebase/cherryPick/revert from git-dir markers) | Real, tested |
| Host `git.stage/unstage/stageAll/unstageAll/discard/commit/abortMerge/abortRebase/continueOperation/createBranch/switchBranch/deleteBranch/stash/stashPop/stashApply/stashDrop/appendGitignore` (mutation, repo gate) | userContext Git (identity, hooks, credential helpers); paths via NUL pathspec file on stdin; untracked discard refused without `includeUntracked` (`untrackedRefused`); hook failure → `gitFailed` with hook stdout+stderr in `detail`; amend of a commit on any remote-tracking ref → `amendPushedCommit` unless `confirmPushedAmend` | Real, tested |
| Host `git.push/pull/fetch/sync` (job) | Push sets upstream on first push; rejection → `pushRejected`, never retried with force; force only as explicit `forceWithLease` (+ optional `expectedRemoteCommit`); credential prompts → `authenticationRequired` | Real, tested against local bare remotes and a local 401 HTTP server only |
| Root acceptance (`GitWriteRPC.acceptRoot`) | **Interim (coordinator decision A, 2026-10-31)**: `worktreePath` accepted if registered (repos.path/worktrees.path → gate key = repo id) or if it canonicalizes to the exact top level of a non-bare work tree (gate key `gitdir:<common dir>`); subdirectories, files, plain folders, bare repos refused. Switch to registered-only once REGISTRY app wiring registers every root | Real, tested |
| `HostClient+Git.swift` | Typed calls, mutations with the 30 s ceiling, `gitStartJob` + `waitForJob` (250 ms `job.get` polling) | Real, tested over a socket |
| Source Control panel: sections Merge Conflicts / Staged / Changes / Untracked | Header actions (Unstage all, Discard all, Delete all, Stage all, Mark all resolved), row hover actions and context menu | Real; e2e exercised Stage All (primary), Discard all, Delete all. Row hover buttons and context menu not clicked |
| Commit box (`SourceControlCommitBox.swift`) | Multi-line `TextEditor`, ⌘↩ commits while it has focus; primary button Stage All Changes → Commit → Publish Branch / Push / Pull / Sync by state | Real; e2e walked Stage → Commit (⌘↩) → Push. Pull/Sync/Publish states not clicked in the app |
| ⋯ menu | Commit, Commit (Amend) with pushed-amend confirmation alert, Push, Pull, Fetch, Sync, Force Push with Lease (only when ahead>0 and behind>0), Stage/Unstage all, Stash (with/without untracked), Pop stash, Create Branch… (alert), Switch Branch submenu; "Generate Commit Message with AI" disabled until M5 | Wired; **not exercised in the app** (host methods are tested) |
| Conflict banner | Merge/rebase in progress → Abort and Continue (Continue disabled while conflicts remain) | Wired; not exercised in the app |
| Failure banner | Error title + selectable Git output (hook output, rejection) + pull hint for `pushRejected` | Wired; not exercised in the app |
| Discard dialog (`Dialogs/DiscardChangesDialog.swift`) | Panel overlay; "Discard" for tracked, "Delete … cannot be undone" for untracked | Real; both variants seen and confirmed in the app |
| Status refresh | After every action, plus a **3 s status poll while the panel is visible** (interim until `fs.changes` from WP-M4-FILES) | Real; an edit made in a session appeared without manual refresh |
| Branch row `branch → base` with `+added −removed` chip | Host `git.branchCompare` exists; the panel shows only `↑ahead ↓behind` vs upstream (no base ref until REGISTRY exposes repo base refs) | **Not wired in UI** |
| View as tree, Notes | Unchanged (tree toggle has no effect yet; Notes VISUAL-ONLY) | Stub |

Tests: **15 new `@Test` in `GitSourceControlTests`** (suite `.serialized`: its real Git processes otherwise starve timing-sensitive host tests run alongside). Covers stage/unstage single, 5,000-path pathspec file, non-ASCII and glob-like names, unstage before first commit, discard tracked vs untracked, commit identity from a temp global config, pre-commit hook failure output, amend and pushed-amend guard, first push with upstream then second push, rejected push not forced, force-with-lease stale vs matching, fetch/pull fast-forward, pull conflict + abort merge, rebase abort/continue, `authenticationRequired` from a local 401 server and fast failure on `http://127.0.0.1:1`, root acceptance rule (registered, unregistered top level, subdirectory, symlink, plain folder, bare, missing, relative), path escapes (`..`, absolute, `.git/`, symlinked directory) and symlink leaf, branches/stash/gitignore/check-ignore/history, branch compare/diff, typed client over a socket.

Git 2.54 quirks under the always-on `--literal-pathspecs`: `ls-files` has no `--pathspec-from-file`, `check-ignore` rejects literal magic (replaced by `ls-files --others --ignored`), and `stash push --include-untracked` saves untracked files but leaves them in the work tree (the stashed files are cleaned explicitly, only when `refs/stash` moved).

E2E (private host from the scratch build, app copy with `SMTHZ_SOCKET` + private state dir, temp repo with a local bare remote): a session ran `echo … >> README.md; echo new > notes.txt` → panel listed both → **Stage All Changes** → typed message + ⌘↩ → commit with the user's global identity → **Push** → `git -C bare.git log` showed the commit. Screenshots in `build/scwrite-evidence/` (ignored). Not run: real network remotes/credential helpers, LFS/submodules, GPG signing, pre-push hooks, the ⋯ menu, conflict/failure banners, light mode.

## WP-M4-REGISTRY — 2026-10-31

| Entry / component | State | Exercised |
|---|---|---|
| Host `repo.list/show/add/update/remove/reorder/searchRefs/baseRefDefault/gitUsername`, `repo.scanNested` (job), `repo.clone` (job, `userContext` Git, destination lock, removes only the directory it created), `repo.create` (`RepoRPC.swift`, `WorkspaceStore+Repos.swift`, `NestedRepoScan.swift`) | Real. `repo.add` canonicalizes paths and creates the main-checkout `worktrees` row (`is_main=1`); same path again → `alreadyKnown`. `repo.remove` refuses `hasLiveSessions` (running sessions whose cwd is inside the repo or its worktrees) unless `force`; never touches files | `RepoRegistryTests` (11 tests) + CLI e2e on a private host. Nested scan reduction: per-folder `.gitignore` rules are **not** applied (fixed skip lists, depth/limit/timeout as Orca). `repo.gitUsername` drops the `gh` probe (M4-D7). Network clones and credential prompts not exercised (local bare repo only) |
| Host `projectGroup.list/create/update/delete/moveProject/importNested`, `folderWorkspace.list/create/update/delete`, `hostSettings.get/set` | Real (defaults per M4-D4: `~/smthz/workspaces`, nested, `git-username` prefix) | Unit tests only; no app UI for group create/rename/colour/delete or folder workspace creation yet |
| `Sources/smthzd/main.swift` (coordinator-approved 2-line edit) | `RepoRPC.register` moved after the `SessionManager` so `repo.remove` sees live session cwds | Unit test with a live `/bin/cat` session inside the repo (refused, then allowed after close) |
| CLI `smthz repo list|add|show|set|set-base-ref|search-refs`, `smthz project list` (`RepoCommands.swift`) | Real; repo selectors `id:`/`path:`/`name:` (bare `/…` = path, bare word = name) | Private host e2e: add twice (`alreadyKnown:true`), list, set-base-ref valid + invalid (`invalidRef`, exit 1), search-refs, set external visibility, show, project list, host restart → repo and base ref still listed |
| CLI `sessions`/`read` exit display | `exited(signal 9 (SIGKILL))` via `HostSessionExit.displayDescription`; codes unchanged (`exited(0)`); wire format unchanged | Private host: `kill -9` of a session child → `smthz sessions` prints `exited(signal 9 (SIGKILL))` |
| Sidebar = "Local host" (default workspace) + one header per project + one card per workspace (main checkout; linked worktrees appear when `worktree.list` exists) + project groups' folder workspaces (`ShellView.swift`, `Workspaces/WorkspaceCatalogModel.swift`, 2 s polling) | Real | Real app (private host + state dir, AX-driven): headers alpha/beta with "primary · main" cards |
| Switching cards (`ShellController.activateWorkspace`, active key persisted as the window record) | Real: tab strip/panes switch per `WorkspaceKey` (`worktree:<id>`, `folder:<id>`, `home`); an empty project workspace opens a shell in the project folder; Explorer/Source Control/Go to File root = active project root (default workspace still follows the terminal cwd); unattached host sessions are adopted into the workspace whose root contains their cwd | Real app: alpha → shell with `pwd` = alpha path, Explorer lists `README-alpha.md`; beta → separate session, Explorer `README-beta.md`. Quit + relaunch: alpha restored active with its replayed history, beta kept its own tab, same two host sessions (no duplicates). Screenshots in `build/registry-evidence/` (ignored) |
| Add Project dialog Browse / nested import / Clone / Create (`Dialogs/AddProjectDialog.swift`, `Dialogs/NestedImportDialog.swift`) | Real code paths | **Not exercised in the GUI**: the dialog and Clone form rendered (screenshot), but keyboard focus kept moving to other workers' smthz windows, so no URL/name could be typed and NSOpenPanel was not driven. The host side of each flow is covered by tests |
| Not done in this WP | Sort/group/filter from `WorkspaceOptionsMenu`, pin/unread persistence through `worktree.set` (WORKTREE-HOST method), project-group dialogs (create/rename/colour/collapse/delete UI), drag-reorder of repos, nested group headers in the sidebar (grouped repos show the group name as subtitle), Jump palette project rows, card "N sessions" detail for project cards (the branch row is shown instead) | Stub / follow-up |

Tests: **11 new `@Test` in `RepoRegistryTests`** (suite `.serialized`: unserialized, its blocking host calls starved the cooperative pool and broke 3 timing-sensitive HOSTCORE/WebSocket tests in the full run). Full suite **395 tests passed 3 consecutive runs** (384 without this WP, including other lanes' additions).

## WP-M4-WORKTREE-HOST — 2026-10-31

| Entry / component | State | Exercised |
|---|---|---|
| `WorktreeRPC.swift`, `WorkspaceStore+Worktrees.swift`, `HostClient+Worktrees.swift` | Real: list/show/resolve/suggestName/prefetchBase/create/set/import/remove/ps/preservedBranches/deletePreservedBranch/approveHooks. Main rows protected; metadata and lineage persist; external checkouts reconciled at registration and on listing, default hidden with repo show/hide and per-row overrides | 25 `@Test` in `WorktreeLifecycleTests`; private-host CLI list/show/current/set/ps exercised. Prefetch endpoint itself not exercised separately (remote fetch exercised through create with a local bare remote) |
| `WorktreeCreator.swift`, `GitWorktreeOps.swift` | Real: resolveBase/resolveName/add/sparse/materialize/persist/setup/defaultTabs phase events and Git stderr/progress, collisions and retired generated names, config-only username prefixes, existing-branch checkout, sparse directories/presets, containment checks, pending job id. New refs are compare-and-created with `update-ref` before `worktree add`, equivalent to `-b --no-track` without claiming an externally raced branch; rollback removes only the exclusively created directory and deletes its ref only if its head still matches | Tests cover bases/branches/commits/local remote, prefixes/suffixes/retirement/reuse, sparse checkout, outside-root symlink refusal, cancellation during a post-checkout hook, and preserving pre-existing branches. Progress phase order asserted; percentage progress parsing uses the existing GitService parser |
| `WorktreeMaterializer.swift` | Real: primary-checkout YAML shared directories, Settings shared paths, and `.worktreeinclude`; gitignored inputs only, existing destinations preserved, destination symlink escape refused. Settings paths clone privately or fall back to a symlink; YAML dirs symlink; includes clone then byte-copy fallback with 2 GiB/50,000-entry limits and warnings; top-level source symlinks copy targets, nested links remain links | Tests: ignored `.env` independent copy, YAML symlink, tracked/missing/glob inputs, lowered entry budget, destination symlink escape. Non-APFS byte-copy fallback and a real 2 GiB input were not exercised |
| `SetupRunner.swift` | Real: shared SHA-256 trust per repo/kind; local/shared/run-both policies, ask refusal before Git changes, destination-revision setup config, primary-checkout archive config, executable Git-private runner with `set -e`, Setup session/environment and Orca aliases only for `orca.yaml`; default-tab commands returned only with trust/run policy | Tests: trust refusal/approval, `set -e`, environment, `orca.yaml` compatibility, local-only policy, separately trusted default tabs. No real network, interactive scripts, or agent startup (M5) exercised |
| `WorktreeRemover.swift` | Real: main/locked/dirty gates; archive session before close/delete, 10-minute cap and explicit failure waiver; cwd-scoped session close; Git remove; merged/squash-merged branch cleanup or preserved-branch record; row/lineage cleanup. Archive via `worktree.set` uses the same hook gate | Tests: clean/dirty/forced, locked, failed archive then waiver, unmerged and pre-existing branch preservation, explicit preserved-branch deletion, live-session close, archive metadata gate. Actual 10-minute timeout and squash-merge cleanup were not exercised |
| Host restart and external worktrees | Real: interrupted creates fail with `hostRestarted`; completed removals finish branch/row cleanup, incomplete removals remain failed. No automatic setup/materialization replay | Private-host E2E killed `smthzd` during a slow add, restarted it, observed `failed`/`hostRestarted`, then removed it. Tests also cover external discovery/import/pruning and interrupted removal lineage cleanup |
| CLI `worktree list/show/current/create/set/rm/ps`, aliases `remove/delete` | Real: selectors, repo inference, inherited cwd lineage, setup/parent/comment flags, bare booleans, read/unread, limits, job wait/progress/errors; `--activate`/`--run-hooks` persist `revealRequested` on the worktree wire row (app consumption is WORKTREE-APP). Coordinator-authorized hook edits: `CLICommon.swift` boolean parsing and `smthzd/main.swift` passes the existing SessionManager | Private-host E2E: `create --name ':rocket: fix login'` → `e2e-user/rocket-fix-login`, list paths equal `git worktree list`, current inside checkout, metadata/ps, archive failure exit 1 despite force, explicit waiver succeeds; host stopped and socket removed. Ctrl-C CLI path and reveal activation in the app were not driven |
| Deferred decisions / app | M4-D7 uses Git config only; users depending solely on `gh` login receive no prefix. M4-D9 implements external show/hide only; provider/source classification remains deferred. These are the planner-recommended possible reductions delegated in the task | No app files changed and no GUI exercised in this WP; worktree composer/setup-tab/reveal/Review Branches UI remains WORKTREE-APP |

Verification: **25 new tests; 433 tests passed serially twice** (`swift test --no-parallel`; latest linked bundle 96.573 s, prior serial run 93.555 s), including parallel FILES additions. Three consecutive full passes were not completed: the coordinator accepted this evidence and explicitly requested completion without waiting for FILES. Private-host CLI E2E passed twice, including a real SIGKILL during add; host/socket cleaned. The initial concurrent runs exposed FILES brace-glob assertions (fixed by its author) and a HostRouter deadline timing assertion (coordinator-authorized test hardening now checks deadline plus scheduling margin, child termination and absent journal entry); the latest concurrent run had only the existing PTY whole-process descriptor-baseline assertion failing while other suites opened descriptors. The latest full app build was blocked by FILES-owned ExplorerPanel compile errors; this lane's core, CLI, host and test products compiled/linked, and its latest linked test bundle passed via `--skip-build --no-parallel`. No Package.swift or app files changed in this WP.

## WP-M4-FILES — 2026-10-31

| Entry / component | State | Exercised |
|---|---|---|
| Host `fs.list/stat/exists/createFile/createDir/rename/copy/trash/restore/importExternal/changes/searchEngine/jobResults`, jobs `fs.listFiles`, `fs.search` (`FilesRPC.swift`, `FileOperations.swift`, `FileListing.swift`, `FileSearch.swift`, `FileWatcher.swift`) | Real. Root = registered repo/worktree/folder-workspace path, or (interim, like `git.*`) the exact Git top level; subfolders and unregistered plain folders refused. Paths root-relative; `..`, absolute, `.git/…` and symlinked parents leaving the root → `pathOutsideRoot`. Never overwrites (`O_EXCL`, `RENAME_EXCL`, `COPYFILE_EXCL`); delete = `FileManager.trashItem` (never `rm`), `fs.restore` only accepts items inside a Trash. Mutations journaled + per-root gate. Job results paged (≤ 5,000 items / ~600 KiB per `fs.jobResults`). `fs.read`/`fs.write` stay unregistered (M4-EDITOR) | `FileOperationsTests` (7) + `FileSearchTests` (7, one over a real Unix socket through `HostClient+Files`) |
| Search engine chain (M4-D3) | `Contents/Resources/rg` next to `smthzd` → `rg` on PATH (+ `/opt/homebrew/bin`, `/usr/local/bin`, since an app-launched host has a minimal PATH) → `git grep` in Git roots → in-process scan. **No rg is bundled or downloaded; `scripts/package-app.sh` untouched (bundling a pinned rg is the user's decision).** Orca args/limits ported: 2,000 matches, 15 s, 5 MiB files, 500-unit line clamp, include/exclude globs with brace expansion for git/in-process, "Find in Folder" scope | Tests run every case on git grep + in-process; ripgrep cases ran with `SMTHZ_TEST_RG` pointing at an rg 14.1.1 binary (none on PATH here, so a default `swift test` skips them) |
| `fs.changes` | FSEvents per root (file events, 0.1 s latency), 10,000-path ring buffer, idle close after 60 s, global cursor → stale/restarted/dropped = `overflow` | External write reported < 2 s (test); overflow and idle close (test) |
| Explorer (`RightSidebar/ExplorerPanel.swift`, `ExplorerUndoStack.swift`; root = Git top level of the active cwd or the project folder via `Slots/RightSidebarSlot.swift`) | Real through host: New File/New Folder (inline name), Rename (inline, Enter/Esc), Delete → Trash (folders confirmed), Duplicate, Copy / Copy Path / Copy Relative Path, Reveal in Finder, Find in Folder (→ Search panel scoped), Add to .gitignore, Stage / Discard (confirmed) for changed rows, drag from Finder = import copy, drag inside tree = move, undo/redo of the last 50 ops (⌘Z/⇧⌘Z and ⌘⌫/⌥⌘C/⌥⇧⌘C only after a click inside the Explorer and outside text fields; also in the ⋯ menu), Git colours (U/M/A/D/R/!) + dimmed ignored rows (`git.checkIgnored`), live refresh polling `fs.changes` every 1 s. Roots the host refuses (not a project, host down) list read-only with a banner. **Open in Terminal is VISUAL-ONLY (disabled)**: no ShellController entry point opens a tab at a cwd | **Not exercised in the GUI** (desktop locked, see below) |
| Search panel (`RightSidebar/SearchPanel.swift`, new right-sidebar item after Explorer, also the Explorer "Contents" mode) | Real: `fs.search` job, 300 ms debounce, new query cancels the previous job (`job.cancel`), case / whole word / regex toggles, include/exclude fields, folder scope chip, results grouped by file with match highlight, counts and "results limited" note | **Not exercised in the GUI** |
| ⌘⇧F / View › Show Search (`ShellView.swift`, `SmthzApp.swift`, `Keybindings.swift` availability; coordinator-approved hook edits) | `sidebar.search.toggle`, `fileExplorer.undo/redo` now `available: true` | Build + registry tests only |
| Go to File ⌘P (`Palette/GoToFilePalette.swift`) | Real: host `fs.listFiles` for the Git top level / registered folder (tracked first, then gitignored rows marked "ignored"; no 10,000 cap), local bounded scan when the host refuses; ranking = recent files (per root, last 50, UserDefaults) + fuzzy score; filename-first rows | Listing/paging tested (6,005 paths, two pages); palette **not exercised in the GUI** |
| Opening files (M4-D8, **INTERIM** until M4-EDITOR) | `InterimFileOpener`: executables, scripts, apps, bundles, packages, disk images and unknown types → Reveal in Finder; documents (text, images, PDF, media, office, JSON/XML/YAML…) → default app. Labelled in the palette footer, Search summary and Explorer menu ("Open with Default App" / "Reveal Executable in Finder") | Not exercised |

Verification: build OK (app + host + tests, Xcode toolchain, own scratch path). New tests: **14** (`FileOperationsTests` 7, `FileSearchTests` 7). Full suite 433/434 tests: passes, but not 3 consecutive times: `PTYSessionTests.twentySessionsDoNotLeakDescriptors` (process-wide fd count) failed in 2 of 3 runs **even with both FILES suites skipped** (`--skip`), and `SessionDurabilityTests.replaysMoreThanFourMiBFromDiskAndAfterTeardown` failed once; neither touches FILES code. **GUI checks not done**: the app copy launched with a private host and a registered private repo, but the screen was locked (`CGSSessionScreenIsLocked`, loginwindow) before a window could be driven: Explorer New File/Rename/Delete/⌘Z, ⌘⇧F, ⌘P and the external-touch refresh were not seen on screen. The 38k-file ⌘P E2E was not run (paging tested with 6,005 paths).

## WP-AG3a AGENT-STATUS-CORE — 2026-10-31

Pure SmthzCore, nothing wired yet: no host RPC (`agent.hook`, `agent.status.list`), no `SessionManager` scanning, no `smthz hook` command and no UI use these types until AG3b/AG4.

| Entry / component | State | Exercised |
|---|---|---|
| `Agents/ProgramStatusScanner.swift` | Real: OSC 7501 grammar ported from Orca `protocol.ts` (states/kinds/id/progress/app/base64 `msg`/`title` caps) and stateful `osc-scanner.ts` (carry across chunks, 4096-byte sequence cap, BEL/ST/CAN/SUB, OSC 133;A prompt-start, RIS). `scan(_:replaying:)` returns events + `queryDetected` + the reply bytes (`ProgramStatusProtocol.queryReply`, verbatim from `protocol.ts`), reply nil while replaying. Deviation: partial-marker carry window is 8 bytes (longest marker) instead of Orca's 7, so `ESC]133;` split before `A` is not lost | Tests only: split at every byte offset + byte-at-a-time of a sample stream, offsets, cap, abort, parse table, replay suppression |
| `Agents/AgentHookPayload.swift` | Real: stdin JSON decode (≤ 1 MiB, object only, `hook_event_name`), session/transcript/cwd/tool/tool_use_id/prompt/source/agent_id/trigger, tool-input preview (subset of Orca's per-tool keys + fallback keys, 160 chars), prompt 200 chars. Event→state for Claude (13 events) and Codex (9 events incl. `Interrupt`) per Orca `claude-events.ts`/`codex-state.ts`, simplified: child (subagent/teammate) events carry metadata only, no child roster; StopFailure → `error`; SessionStart(startup/resume/clear) and SessionEnd → `idle` | Tests only (synthetic payloads; no payload from a real `claude`/`codex` run) |
| `Agents/AgentStatusStore.swift` | Real value type: per-session hook record + OSC record set (256-record LRU, clear subtree, end-program on prompt-start/exit keeps done/error, reset on RIS). Precedence ported from `hook-precedence.ts`: hook wins unless OSC disagrees and hooks were silent ≥ 2 min, or another app reports after the hook agent is done. States `idle/working/blocked(kind)/done/error`. Not persisted, no subscribe stream (AG3b) | Table test (28 transitions) + metadata/row tests |
| `Agents/ClaudeHookSettings.swift` | Real: `json(command:timeoutSeconds:)` builds the `--settings` document for the 13 Claude events (matcher `*` on the 4 tool events, timeout 10 s like Orca), `hookCommand(executablePath:)` shell-quotes the path. Writing the file (0600) and passing `--settings` is AG2 | Tests parse the JSON; not passed to a real `claude` |

Verification: 23 new `@Test` (scanner 9, payload 6, store 5, settings 3). The shared tree's `SmthzApp` target did not compile at verification time because of another worker's in-progress files (`Workspaces/WorktreeLifecycleModel.swift`), so the suite ran from a private copy of the package with the app target removed: 488 tests passed 3 consecutive runs (includes AG1's 21 new tests).

## WP-M4-WORKTREE-APP — 2026-10-31

Files: `Dialogs/NewWorkspaceComposer.swift`, `Dialogs/DeleteWorkspaceDialog.swift`, new `Dialogs/EditWorkspaceDialog.swift`, `Dialogs/SetupApprovalDialog.swift`, `Dialogs/PreservedBranchesDialog.swift`, `Dialogs/RepositorySettingsSheet.swift`, new `Workspaces/WorktreeLifecycleModel.swift`; edits to `Sidebar/WorkspaceCardView.swift`, `Sidebar/WorkspaceContextMenu.swift`, `Sidebar/WorkspaceStatusSlot.swift`, `ShellController.swift`, `ShellView.swift`; new pure logic `Sources/SmthzCore/WorkspaceComposerLogic.swift` and tests `WorktreeAppLogicTests.swift` (10 unit + 4 host-contract tests that run the composer/delete params through the real `worktree.*`/`repo.searchRefs` RPC on temp repos).

| Entry point | Behaviour | Status |
|---|---|---|
| Composer Project combobox | Git projects of the catalog, search, "Add a new project" pinned first | Real |
| Composer Name | Placeholder shows `worktree.suggestName`; empty name sends it with `nameWasGenerated`; trailing `:partial` shows up to 6 emojibase suggestions, click inserts `:code: ` | Real |
| Create From Name / Branch | Name: optional start-from ref (`repo.searchRefs`; tags → `commit`, else `base`). Branch: pick a local branch (checked out as-is when free, `startFrom.kind=branch` + `branchName`) or a remote branch (`remote-branch`, local name = leaf) | Real |
| Create From Smart / GitHub / GitLab / Linear / Jira | Tabs shown, Create disabled with "Not available yet" | VISUAL-ONLY until M9 |
| Composer Advanced | Branch name, Note (`comment`), Start from, Parent worktree (same project), Setup (repository default / run / skip), Sparse checkout directories (validated: no absolute, `..`, `.git`) and presets | Real; **sparse presets are stored in app UserDefaults per repo**, because the host has no `sparsePreset.*` methods yet (`presetId` is sent but unused by the host) |
| Composer Create / Create more | `worktree.create`; validation errors shown inline; the composer closes when the job starts (stays open, fields reset, new suggested name with Create more) | Real |
| Composer Run on / Agent | Unchanged | VISUAL-ONLY (M7 / M5) |
| Setup approval dialog | `setupDecisionRequired` → Run / Skip resubmits with `setup`; `untrustedCommand` → preview of the shared command from the primary checkout's `smthz.yaml`/`orca.yaml`, SHA-256 shown, Trust → `worktree.approveHooks` then resubmit; Skip setup | Real (host contract tested); dialog not seen on screen |
| Sidebar card progress | Phase label (§8.3), percent (phase index + Git `Updating files` counter in `add`), Cancel → `job.cancel` via `waitForJob`; status slot spinner | Real; Cancel not exercised against a real slow checkout |
| Card failure row | "Create failed" + Retry (clears the failed row with `worktree.remove` force/no hooks/**branch kept**, re-issues the original params with a new request id) and Delete; rows failed by `hostRestarted` (no params in memory) retry with name + repo only | Real |
| Main area while creating/failed | Pending panel (phase, progress, Cancel / Retry, Delete) instead of the terminal | Real |
| Job success | Worktree becomes the active workspace (`worktree:<id>` layout, own tabs, Explorer root), a shell opens in the new path, one tab per `defaultTabs` (command typed after the shell starts), setup session adopted by cwd and titled "Setup" | Real code path; **not driven in the GUI**. Known race: if the host monitor sees the setup session before the layout exists it is adopted into the Default workspace |
| `smthz worktree create --activate` | App sees `revealRequested`, clears it (`worktree.set`) and selects the workspace | Real; not exercised |
| Inline rename / Pin / Mark Read-Unread (worktree cards) | `worktree.set` displayName / pinned / unread; folder cards use `folderWorkspace.update` | Real |
| Edit Workspace Details (card menu, Set/Change Parent) | Name, note, parent (`worktree.show` lineage, `parentId`/`noParent`; cycle → inline error) | Real |
| Delete Workspace dialog | Dirty warning (`worktree.show` clean), running-terminal count, "Also delete the branch", "Run the archive script", Don't ask again; `worktreeDirty` → Force Delete, `archiveHookFailed` → Delete Anyway (`allowFailedArchiveHook`); layout of the deleted worktree is dropped | Real (host contract tested for dirty/preserve/keep branch). Multi-select delete: dialog takes N targets but the sidebar has no multi-selection yet |
| Review N Branches | Opens after a delete returns `preservedBranch` and from the card menu; checkbox list, Delete → `worktree.deletePreservedBranch` (`git branch -D`), Keep All | Real |
| Repository Settings (card menu) | `repo.show`/`repo.update`: name, badge colour, base ref (invalid → inline error), setup run policy, command source, local setup/archive scripts, shared paths, external worktree visibility | Real |
| Not done in this WP | Children chip/collapse in the sidebar (needs lineage on `worktree.list`), Jump palette "Create worktree" row, Open Parent Worktree, card multi-select, `wait-for-setup` agent policy (M5) | Stub |

Verification: build OK; full suite **492 tests ×3 pass** (434 baseline + 14 of this WP + other workers' Agents tests). An earlier version of the host-contract fixture polled jobs with `Thread.sleep` and starved timing-sensitive suites (`WebSocketTransportTests`, `HostRouterTests` deadline, `PTYSessionTests` descriptor count) in 3 of 3 runs; it now polls with `Task.sleep`. **No GUI check was done**: the desktop was locked (`CGSSessionScreenIsLocked = true`) for the whole session, so composer/progress/dialog rendering, terminal-in-new-path (`pwd`), setup tab output, Review Branches after a real delete and tab persistence per worktree across app restart remain to be verified in the real app.


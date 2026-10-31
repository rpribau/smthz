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
| Exit overlay Restart | Model restartPane creates a replacement session with the original executable/arguments and current directory/grid; stable tab identity retains title/colour/pin/order | Real |
| Cmd-J; sidebar Search; View → Open Worktree Palette | Jump palette populated with open sessions, Default workspace, actions and Settings pages | Real |
| Jump palette Open Tab / Default workspace | Select target / return to workspace | Real |
| Jump palette New Terminal / toggle sidebars / Settings row | Dispatch corresponding action, including requested settings page | Real |
| Jump palette projects/tasks | No fabricated project/task rows | Stub: M4/providers |
| Cmd-P; View → Go to File | Bounded file scan under selected session cwd | Real listing |
| File palette Open | Informational toast “File editor — Not available yet”; no external application opens | Stub: editor |
| Cmd-N; sidebar New workspace; landing Create workspace; project header `+` | NewWorkspaceComposer | Real presentation |
| Composer Create with no project | Create host shell; existing Create more behaviour retained | Real fallback; project/worktree creation stub |
| Composer Add project / Agent settings | AddProjectDialog / Settings → Agents | Real routing; backends stub |
| Sidebar / landing Add project; onboarding Add project | AddProjectDialog | Real routing |
| Add Project Browse folder | Existing NSOpenPanel; display selected path only | Real picker; project persistence stub |
| Add Project create/clone/SSH | Visible disabled choices | Stub: M4/remote hosts |
| Default workspace select; Reveal active workspace | Return to Default workspace | Real; one card only |
| Workspace Update/inline rename, Pin, Mark Read/Unread | Window-local card state | Real presentation state |
| Workspace Open in Finder / Copy Path / Copy Worktree Name | Selected cwd and pasteboard actions | Real |
| Workspace Remove Workspace / hover delete | DeleteWorkspaceDialog; confirming only emits unavailable toast | Stub: M4; never deletes files |
| Workspace sleep/status/parent; project icon/group/remove/settings | Existing disabled menu choices | Stub: M4 |
| Workspace options menu | Existing locally persisted sort/group/filter settings | Real preference; multiple-workspace effects deferred |
| Sidebar activity / board | Existing visual activity empty state / board button state | Stub: agents/board backend |
| Tasks nav/provider glyphs | SmthzTasksPage | Stub: providers; glyph route opens Tasks, provider selection remains local to page |
| Automations nav | SmthzAutomationsPage | Stub: scheduler; no fake runs |
| smthz Mobile nav | SmthzMobilePage | Stub: own relay/auth/mobile app |
| Destination close button / Escape | Return to workspace | Real |
| Cmd-,; sidebar Settings; menu Settings | Settings → Appearance | Real routing |
| Help → Keyboard Shortcuts (sidebar and app menu) | Settings → Shortcuts | Real deep link; existing page body is unavailable |
| Settings Appearance / Terminal | Existing persisted theme and terminal controls | Real where already supported; other controls disabled |
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
- Existing build warnings include EventJournal unused withUnsafeBytes and StatusBarView missing explicit Combine import; no out-of-scope warning cleanup was attempted.

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

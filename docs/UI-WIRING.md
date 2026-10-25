# UI-29 wiring

Implemented 2026-10-25. The shell uses the existing HostMonitor/HostClient APIs and window-local presentation state; it does not bind ShellModel/LayoutTree. Package.swift, SmthzCore, Theme, reference and icon were not edited.

## Entry points

“Real” means a local action or an existing host RPC. “Stub” means a reachable, clearly unavailable surface with no simulated backend mutation. Existing disabled controls remain disabled.

| Entry point | Result | Status |
|---|---|---|
| Cmd-T; tab `+` → New Terminal | `session.create`, select returned session, return from Settings/destinations | Real |
| Tab `+` search → existing tab | Select session and display its replayed output | Real |
| Tab `+` agent/browser/emulator/Markdown rows | Visible disabled choices with unavailable tooltips | Stub: M4/M5/WebKit/editor |
| Cmd-W; tab close; exited-terminal Close | `session.foreground`, pinned/running confirmation when required, then `session.close`; remove closed tab locally | Real |
| Pinned/running confirmation Cancel or Escape | Leave session open | Real |
| Confirmation “Don't ask again” | Existing persisted confirmation preference | Real |
| Tab context Close Others | Bulk confirmation; close unpinned candidate sessions only | Real |
| Tab context Pin/Unpin | Window-local pin state; Cmd-W can explicitly confirm pinned closure | Real |
| Tab double-click / Change Title; Cmd-R | Rename locally; explicit rename takes precedence over OSC title | Real |
| Tab Color | Window-local colour retained through switching/reordering | Real |
| Copy Tab ID | Pasteboard plus success/error SmthzToast | Real |
| Drag tab | Update window-local tab order | Real |
| Ctrl-1…9 | Select tab in displayed order | Real |
| Ctrl-Tab | Switch to previous recent visible tab | Real; no separate recent-switcher overlay |
| Tab split/move/equalize/expand controls | Visible unavailable controls where their component exposes them | Stub: M3 A2 |
| Command button | QuickCommandsMenu with search, Global/Default workspace scope | Real |
| Quick commands Add/Edit/Copy/Delete | Existing shared store, editor/deletion dialogs, UserDefaults persistence | Real |
| Quick command Run | `session.write` with the configured text and optional CR | Real |
| Terminal context Quick Commands submenu | Saved commands execute through the terminal's serialized write stream; Add opens shared editor | Real |
| Terminal OSC title/directory | Update tab title/hover directory, file palette root and right-sidebar root; user title wins | Real |
| Terminal right-click Copy/Select All/Paste/IDs/Clear/Reset | Existing emulator/pasteboard actions | Real |
| Terminal context Set Title / pane IDs / split controls | Disabled until pane ownership exists | Stub: M3 A2 |
| Cmd-F in terminal | Existing terminal find bar, previous/next, case and regex options | Real |
| Cmd-K; Terminal menu Clear Screen | Clear local emulator without sending a shell command to a running program | Real |
| Exit overlay Restart | Create replacement host session; transfer local title/colour/pin/order to new ID | Real |
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
| Resource Manager Go to terminal | Reopen/select corresponding session tab and leave Settings/destination | Real |
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
- `Slots/RightSidebarSlot.swift`: consume WorkspaceModel.rootURL, including terminal directory callbacks.
- `Slots/StatusBarSlot.swift`: optional selection callback, centralized model close, live session count.
- `Terminal/TerminalContextMenu.swift`: saved-command submenu and Add action; write callback.
- `TerminalSessionView.swift`: connect submenu writes/Add notification and receive window session-specific clear notifications.

Primary changes: `ShellView.swift` composes/routes all surfaces and confirmations; `WorkspaceModel.swift` owns temporary tab presentation, serialized create/write/close operations and replacement-session reconciliation. Rename/colour/pin/order/closed state is window-session memory, not durable shell persistence (M3 C4).

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

After app restart, host-retained exited records can reappear as tabs because durable shell state is deferred. Foreground confirmation observes a point-in-time host verdict; the first immediate close after injecting sleep raced shell command startup and closed before the running-command prompt, while the later check after sleep was established correctly prompted. No backend changes were made to address that race.

The app used for the earlier tour was no longer running when work resumed; there was no new matching crash report, so the cause of exit is unproven. Final packaging and host checks were repeated. The private app/host processes and sessions were stopped at cleanup; the temporary build scratch directory was removed, and build/smthz.app remains available.

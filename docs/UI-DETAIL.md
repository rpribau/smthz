# UI-DETAIL — exhaustive inventory of Orca 1.4.238's main window, for smthz

Status: research inventory, 2026-10-24, task `task_d8d02d940cb2` (second, deeper UI pass). Complements `docs/UI-SPEC.md` (tokens, geometry, decisions); this file lists **every visible control and behaviour**, area by area. The diff against smthz and the new work packages are in `docs/UI-GAP2.md`.

## How to read this file

- **Source paths** are relative to `reference/orca-1.4.238/src/renderer/src/components/` unless they start with `app-shell/`, `hooks/`, `shared/` (= `src/shared/`) or `i18n/`.
- **Evidence tags.** Every table or list carries a tag in its heading. `[verified from source]` means every row was read in the file named (label text from the `translate(key, 'English default')` call or from `i18n/locales/en.json`, icon from the `lucide-react` import used at that spot, size from the Tailwind class). Rows that are not fully verified carry their own `[inferred]` tag, and the reason. Nothing here was checked against a running Orca (no Orca window was on screen; the smthz app was screenshotted, see UI-GAP2 §0).
- **Naming rule.** Labels are given with the product renamed: wherever Orca says "Orca" the smthz label says **smthz** (e.g. "Orca Mobile" → "smthz Mobile", "Restart Orca" → "Restart smthz", "Orca CLI" → "smthz CLI", "Remote Orca Servers" → "Remote smthz Servers"). Where the original wording matters it is quoted as `Orca: "…"`. Our type prefix is `Smthz*` (`SmthzTheme`, `SmthzMetrics`, `SmthzFont`, `SmthzIcon`, `SmthzTooltip`, `SmthzDialog`, `SmthzToast`).
- **Sizes**: CSS px = pt. Tailwind `size-3` = 12, `size-3.5` = 14, `size-4` = 16, `size-5` = 20; `icon-xs` button = 24². Icon names are Lucide component names (`FolderPlus` = file `folder-plus.svg`).
- **Shortcuts** are the macOS defaults from `shared/keybindings/definitions-core-*.ts` (`Mod` = ⌘). Full table in §15.

---

## 1. Window chrome and title band [verified from source]

Sources: `app-shell/TitlebarLeftControls.tsx`, `app-shell/TitlebarMainStrip.tsx`, `app-shell/AppWorkspaceShell.tsx`, `right-sidebar/index.tsx`. Geometry is in UI-SPEC §2–3.

| # | Control | Label / tooltip | Icon | Size / style | State / trigger |
|---|---|---|---|---|---|
| 1.1 | Traffic lights | — | native | x 16, centre y 18 | always |
| 1.2 | App name | "smthz" (Orca: "Orca"); aria "Application menu" | — | 12/600, h 24, px 6 | right-click → menu with one item **"Hide App Name"**; setting `showTitlebarAppName` (also in View menu "Show Titlebar App Name") |
| 1.3 | Sidebar toggle | tooltip "Toggle sidebar (⌘B)" | `PanelLeft` 16 | `.sidebar-toggle` padding 4×8, radius 4 | click toggles left sidebar; ⌘B |
| 1.4 | Back | tooltip "Go back (⌥⌘←)" | `ArrowLeft` 12 | compact toggle | disabled (45 % opacity) when no history; workspace history; hidden in Settings |
| 1.5 | Forward | tooltip "Go forward (⌥⌘→)" | `ArrowRight` 12 | same | same |
| 1.6 | Overflow (narrow) | — | `MoreHorizontal` | — | `TitlebarLeftControls` imports it for the collapsed cluster [inferred: only shown when the cluster does not fit] |
| 1.7 | Collapse pane | "Collapse pane" | `Minimize2` 14 | `.titlebar-icon-button` p 4, mr 8 | only while a pane is expanded (⌘⇧↩ toggles) |
| 1.8 | Right sidebar toggle | tooltip "Toggle right sidebar (⌘L)" | `PanelRight` 16 | floats top-right of centre column when the right sidebar is closed; inside the right sidebar header when open | ⌘L |
| 1.9 | Window drag | — | — | title band, sidebar header, tab strip, right header | double-click zooms [inferred: macOS default] |

## 2. Left sidebar

### 2.1 Navigation block (`sidebar/SidebarNav.tsx`, `SidebarTaskNavButton.tsx`, `SetupGuideSidebarEntry.tsx`, `sidebar-nav-controls.tsx`) [verified from source]

Container `px-2 pt-2 pb-1`, rows gap 2. Row: radius 8, px 8 py 6, 13/500 tracking-tight, icon 16 (stroke 1.75 inactive / 2.25 active), text `fg/60`, icon `fg/30`, hover `fg/8`, active `worktree-sidebar-accent`.

| Row | Label | Icon | Visible by default | Extras |
|---|---|---|---|---|
| Search | "Search"; aria "Search worktrees and browser tabs" | `Search` | always | fill `fg/5`; on hover/focus shows keycaps for `worktree.palette` (⌘J) at 9 pt; click opens the jump palette (§9.1) |
| Onboarding checklist | "Onboarding checklist" | Orca logo glyph (custom) | while onboarding incomplete | context menu "Hide from sidebar" |
| Tasks | "Tasks" | `List` | yes (`showTasksButton`) | hover reveals provider buttons: `Github` "Open GitHub tasks", `Gitlab` "Open GitLab tasks", Linear glyph "Open Linear tasks", Jira glyph "Open Jira tasks" (14 pt); context menu "Hide from sidebar" |
| Artifacts | "Artifacts" | `Files` | no (`showArtifactsButton`) | context menu "Hide from sidebar" |
| Skills | "Skills" | `BookOpen` | no (`showSkillsButton`) | same |
| Automations | "Automations" | `CalendarClock` | yes | same |
| Agent dashboard | — | — | experimental flag only | lazy entry |
| smthz Mobile | "smthz Mobile" (Orca: "Orca Mobile") | `Smartphone` | yes | pill **"New"** (bg primary, 10/600, px 6, rounded-full) until first visit; once a device is paired, a ghost `icon-xs` button `EyeOff` 14 "Hide from sidebar" (tooltip above); context menu "Hide from sidebar" |

Context menu for every hideable row: one item `EyeOff` 14 **"Hide from sidebar"**.

### 2.2 Section header (`sidebar/SidebarHeader.tsx`, `sidebar-header-actions.tsx`, `SidebarWorkspaceOptionsMenu.tsx`) [verified from source]

`mt-2 h-8 px-2`. Title "Projects" (group by Project, the default) or "Workspaces" (other group-bys), 12/600 `muted-foreground/80`, truncating. Right cluster gap 4, all ghost `icon-xs` 24², glyph 14 stroke 2.25, tooltips below (offset 6):

| Button | Tooltip / aria | Icon | Behaviour |
|---|---|---|---|
| Activity | "View activity" / pressed: "Turn off activity view" | `Bell` | toggles the sidebar body between workspaces and **Agents list** (§2.7); pressed = `bg-primary/15 text-primary`. First time for migrated users a popover (w 288, radius 14, p 14, `Sparkles` 16) "Agents are easier to find" / "Your Agents view is now a dedicated sidebar tab. Your activity and filters are preserved." / button "Got it". |
| Workspace options | "Workspace options" / "Workspace options ({n} active)" | `SlidersHorizontal` | dropdown §2.3; hidden while the Agents body is shown (its own options button is portalled in) |
| Add project | "Add project" | `FolderPlus` | opens Add Project dialog (§10.2) |
| New workspace | "New workspace" + muted "⌘N" | `Plus` | opens New workspace composer (§10.1); ⌘N / ⌘⇧N |

### 2.3 Workspace options menu (`sidebar/workspace-options-menu-items.tsx`, `sidebar-workspace-option-items.ts`, `shared/workspace-view/workspace-view-options.ts`, `SidebarFilter.tsx`) [verified from source; section placement inside the menu partly inferred]

Sections (labels verified; order of the last three [inferred]):

| Section | Options (default **bold**) |
|---|---|
| Sort by | Name · Agent Activity ("Agents that need attention, then most recent activity.") · **Recent** · Project · Manual ("Drag workspaces to arrange them within each group.") |
| Project order | **Manual** ("Drag projects to arrange them") · Recent ("Most recent workspace activity") |
| Group by | None · Status · PR · **Project** |
| Show (card properties, checkboxes) | GitHub ticket · Linear issue · Jira issue · PR/MR link · Automation · Notes · Ports · Agent activity · Host |
| Filters (switch rows) | Hide sleeping (+ nested "Except default branch") · Hide default branch · Hide automation-created · Hide CLI-created · Hide detached HEAD · Hide other-client workspaces |
| Card layout [inferred placement] | Detailed · Compact |
| Agent activity layout [inferred placement] | Compact · Full list |
| Host scope [inferred placement] | "Show every host", "Configured SSH", "Project SSH", "Default for new projects", "Project server" |

A separate filter popover (`SidebarFilter.tsx`, `ListFilter`) offers the same filters plus a **Projects** checklist ("Select all", "Clear", search "Search projects...", "No projects match", SSH badge, footer "Reset filters", "Add project"); trigger tooltip "Filter workspaces" / "Edit filters ({n} active)".

### 2.4 Workspace list rows (`sidebar/worktree-list/rows/*`, `worktree-card-*.tsx`, `WorktreeCardStatusSlot.tsx`, `StatusIndicator.tsx`) [verified from source]

**Project header** (`SectionHeader.tsx`, `repo-header-project-actions.tsx`): h 28, sticky. Left: project icon box 16² (repo icon glyph 14 in the project colour; user-changeable "Change Project Icon"), label 13/600 line 16 truncate, optional host label, fork indicator, folder-path status (`FolderX`), scan-failed warning (`TriangleAlert`, tooltip "Worktree scan failed for {name}", "Retry scan", "Copy diagnostics"). Right, **revealed on hover** (20² buttons, width animates from 0): `Ellipsis` 14 "Project actions" → menu; `Plus` 12 "Create workspace for {name}". Always: collapse chevron 20² `ChevronDown` 14, rotated −90° when collapsed, hover `accent/70`. Icon + title is the drag handle (grab cursor) to reorder projects.

Project actions menu: `SlidersHorizontal` "Project Settings" · `Shapes` "Change Project Icon" · `Eye` worktree-visibility item (label depends on state) · `FolderTree` "New group from project" · `FolderInput` "Move to group" ▸ (group names) · `CircleX` "Remove from group" (when grouped) · — · `Trash2` **"Remove Project"** (destructive).

Project-group header (when groups exist): `Ellipsis` "Group actions for {name}" → "Rename group", "Delete group"; `Plus` "Create workspace for {name}".

**Workspace card** (detailed layout): margin-left 4, radius 10, 1 pt border, `pt-1.25 pb-1.5`.

| Part | Detail |
|---|---|
| Status slot (left, 20² box) | One of: green dot 8 (`emerald-500`, agent done/active); grey dot 8 (`neutral-500/40`, inactive); `AgentWorkingSpinner` 8 in 12 box (working, yellow); `Activity` 12 `agent-working` (monitoring); red dot 6 (failed); muted dot 6 (interrupted); `AgentQuestionIcon` 12 orange (permission / asking); **`Moon`** (sleeping); **`GitBranch`** (quiet, branch identity); PR review icon (quiet, has PR); **filled amber bell** 13 when unread — hover swaps to an outline `Bell` 12 to mark read. Tooltip = status label (e.g. "Sleeping", "Branch"). |
| Title row | optional repo chip; host glyph `Server` 12 / `ServerOff` 12 destructive ("SSH disconnected", "{host} disconnected"); title 13 leading 20, semibold when unread; badges "primary" (tooltip "Primary worktree (original clone directory)"), "sparse" ("Partial checkout. Files outside these paths are not on disk."); auto-name failure `AlertCircle` "rename failed" ("Auto-name failed. Click to see details."); right: `Star` 12 amber-400 filled when pinned; hover-revealed `Trash2` 14 "Delete workspace" (hover `destructive/10`) |
| Meta row | 11 pt muted, leading none: repo chip (badge mark + lowercase name, 10/600, `bg-accent`, radius 4), host context badge, branch name (11 pt, not mono) or folder name (mono 11, tooltip path), detached-HEAD badge, conflict badge (`GitMerge` 10 amber, "Merge"/"Rebase"…), prompt-cache timer, right: linked items/ports icons |
| Metadata badges | `CircleDot`/`Link2`/`StickyNote`/`CalendarClock`/`SquareTerminal` icons: "Workspace notes", "Created by automation", "Created by smthz CLI", "Linked issue #{n}", "Linked Jira {key}", "Linked Linear {id}", "Linked {kind} #{n}", "Show {count} linked reviews and tasks"; PR state badges (`CircleCheck` / `CircleDot` / `CircleX` / `Clock` / `GitMerge`: "State: Open/Closed/Merged/Draft") |
| Ports badge | `Plug` "{n} live {ports}" → popover "Live Ports": rows with `ExternalLink` "Open in Browser", `Copy` "Copy {addr}", `Trash2` "Stop Process" |
| Inline agents | compact agent rows under the card, `ChevronDown` "Collapse {name}" / "Expand {name}" |
| Hover card | rich detail card on hover (`WorktreeCardHoverIdentityHeader.tsx`, `WorktreeCard*DetailSection.tsx`): identity header, linked issue/PR/automation/CLI sections, notes [verified files; layout not enumerated] |
| States | hover, active, multi-selected, sleeping dim, deleting (pill "Deleting…" + `LoaderCircle`, 50 % + grayscale), "Delete failed", "Queued for deletion", disconnected 60 % (UI-SPEC §4.3) |
| Interactions | click = open; double-click title = inline rename (`WorktreeTitleInlineRename.tsx`: "Rename workspace", emoji picker "Emoji", spinner while saving, toast "Failed to rename workspace."); drag = reorder / nest under another card / drop on a board status lane; ⌘⇧↑/↓ previous/next workspace; ⌘1…9 select by index |

**Pending row** (`PendingWorktreeRow.tsx`): `Loader2` "Creating workspace…", `X` "Cancel" (aria "Cancel worktree creation"), `AlertTriangle` on failure.

**Empty list** (`worktree-list/listing/EmptyState.tsx`): "No workspaces found" + `CircleX` button "Clear Filters".

**Drop affordance** (`sidebar/index.tsx`): dashed card over the list when dragging a folder: `FolderPlus` 20 (or `Loader2` busy), 14/500 label, 12 muted description, border ring/70 or destructive/70.

Banners that can appear above the list: severed / stalled terminal-daemon banners, "Local Git toolchain scan" banner, setup-script prompt card above the toolbar [verified file names; copy not enumerated].

### 2.5 Workspace context menu (`sidebar/WorktreeContextMenuView.tsx`, `WorktreeStatusMenuItems.tsx`, `WorkspaceSleepMenuItems.tsx`, `WorktreeRowOpenInSubMenu.tsx`, `WorktreeOpenInMenu.tsx`, `WorktreeDeveloperMenu.tsx`) [verified from source]

Right-click on a card. Order:

1. Label "Workspace" (11/500 muted)
2. `Pencil` "Update" (opens the workspace meta dialog: name, notes, links [inferred: handler name `handleRename`, dialog `edit-meta`])
3. `Kanban` "Move to Status" ▸ (board lanes) / multi-select "Move Statuses To" ▸
4. —
5. `FolderOpen` "Open in" ▸ (Finder, editors…, "Customize apps..."; SSH: "Local only", "Remote SSH" hints)
6. `Copy` "Copy Path"
7. `Copy` "Copy Worktree Name"
8. —
9. `Pin` "Pin" / `PinOff` "Unpin"
10. `Bell` "Mark Unread" / `BellOff` "Mark Read"
11. — `FolderPlus` "New group from project", `FolderInput` "Move to group" ▸, `CircleX` "Remove from group" (project rows only)
12. — `FolderTree` "Set Parent Worktree..." / "Change Parent Worktree...", `Workflow` "Open Parent Worktree", `Unlink` "Remove from Parent"
13. — Developer ▸ (`CodeXml`): `SquareParking` "Park terminal" (dev builds)
14. `Moon` sleep item [inferred label "Sleep": the tooltip text is verified, the item label key was not read] ("Close all active panels in this workspace to free up memory and CPU."), "Sleep with Descendants ({n})"
15. — `Trash2` **"Delete Worktree"** (destructive, shortcut ⌘⇧⌫) / "Remove Workspace" (folders) / "Remove Project from smthz" / "Delete with Descendants…" / disabled "Primary worktree — can't be deleted. Remove the project instead." / "Deleting…"

### 2.6 Bottom toolbar (`sidebar/SidebarToolbar.tsx`, `SidebarSettingsHelpMenu.tsx`, `ScrollToCurrentWorkspaceToolbarButton.tsx`) [verified from source]

`border-t px-2 py-1.5`, all ghost `icon-xs`, glyph 14, tooltips above.

| Button | Tooltip | Icon | Behaviour |
|---|---|---|---|
| Settings | "Settings" + keycaps of `app.settings` (none by default; ⌘, comes from the app menu) | `Settings` | opens Settings page |
| Help | "Help" | `CircleHelp` | dropdown (w 208, opens upward): `Keyboard` "Keyboard Shortcuts" (opens Settings › Shortcuts) · — · `MessageSquareText` "Send Feedback" (feedback dialog) · "Milestones" (when available) · `School` "Onboarding" · `BookOpen` "Docs" ↗ · `ScrollText` "Changelog" ↗ · — · `Github` "GitHub" ↗ · "Discord" · "X" · — · `RefreshCw` "Check for Updates" · — · `RotateCw` "Restart smthz" (→ "Restarting smthz…", error toast "Couldn't restart smthz.") |
| Reveal active workspace | "Reveal active workspace" | `Crosshair` | scrolls the list to the active card |
| Workspace board | "Workspace board" / "Close workspace board"; one-time hint "Workspace board moved to the bottom bar" (12 s) | `Kanban` | `secondary` variant while open; opens the Kanban drawer over the workspace area (`WorkspaceKanbanDrawer*.tsx`: status lanes, search field, settings menu) |

### 2.7 Agents body (`sidebar/SidebarAgentsList.tsx`) [verified file; layout not enumerated]

Shown when the Bell is pressed: search "Filter..." / "Search", read filter, group-by, per-workspace agent rows with state dots. Options button portalled into the header.

### 2.8 Resize and collapse [verified from source]

12 pt hit area on the right edge, 1 pt line `ring/50` hover / `ring` + `bg-ring/10` while dragging; width 220–500. Collapsing (⌘B) sets width 0 and the 36 pt header floats over the tab strip.

## 3. Tab strip and tab groups

### 3.1 Strip (`tab-group/TabGroupPanel.tsx`, `tab-bar/tab-bar-surface.tsx`) [verified from source]

Row h 32, `bg-card`, bottom border, `pr-1.5`. Left to right: (spacer for the collapsed sidebar header) · tab bar (flex 1): `ChevronLeft` 14 "Scroll tabs left" (h 24 w 20, only when clipped and strip ≥ 260) · tabs (flex `0 1 auto`, horizontal scroll, fade masks) · `ChevronRight` 14 "Scroll tabs right" · **`Plus` 14 "New tab" button 28², `ml-2`, directly after the last tab** · (free space) · action cluster: **Command** button (§3.5) and, with split groups only, **Pane Actions** (`Ellipsis` 16, 28², aria "Pane Actions", menu: `X` "Close split pane", destructive). Unfocused group: action cluster 50 % until hover; unfocused group body opacity 0.95.

### 3.2 Tab (`tab-bar/SortableTab.tsx`, `TerminalTabLeadingIcon.tsx`, `tab-width-rules.ts`) [verified from source]

Width 180 (220 when window ≥ 1280), min 72; 12 pt; leading icon 12 (shell tile, agent icon, or unread state: filled amber bell "Unread agent completion"); `Pin` 12 when pinned; title (terminal title / agent name / user title); `Minimize2` 12 "Collapse pane" when expanded; close `X` 12 in 16² "Close tab {title}" (hover-revealed; always shown on the active tab). Active: fill fg 6 %, 2 pt foreground bottom bar. Unread: `amber-500/10` wash. **Tab colour**: a coloured marker from the context menu (§3.3). Double-click or ⌘R = inline rename ("Rename tab {title}"). Middle-click closes (unless pinned). Drag reorders; drag onto the body edge splits ("New split" drop overlay `TabGroupDropOverlay.tsx`). Hover card after a delay (`TabHoverCard.tsx`: kind "Terminal"/"Browser"/"Editor", title, cwd/agent [inferred contents]).

### 3.3 Tab context menu (`tab-bar/SortableTabContextMenu.tsx`, `TerminalTabSplitMenuSection.tsx`, `TabWorkspaceLayoutMenuSection.tsx`, `CopyTabIdMenuItem.tsx`, `CloseSplitPaneMenuItem.tsx`) [verified from source]

1. `PanelRightClose` "Split terminal right" ⌘D
2. `PanelBottomClose` "Split terminal down" ⌘⇧D
3. `Columns2` "Move Tab to Split" ▸ `ArrowRight` Right / `ArrowLeft` Left / `ArrowDown` Down / `ArrowUp` Up (when groups exist) [verified file; placement in this menu inferred]
4. — `SquareTerminal` "Continue with Terminal Agent" / "Continue in Chat UI" (agent tabs only)
5. session-surface switch items (agent tabs only)
6. — `Pin` "Pin Tab" / `PinOff` "Unpin Tab"
7. `Copy` "Copy Tab ID" (toasts "Tab ID copied" / "Could not copy tab ID")
8. — `X` "Close" ⌘W (disabled when pinned) · `ListX` "Close Others" (disabled with one tab) · `X` "Close split pane" (split groups only)
9. — `Pencil` "Change Title" ⌘R
10. Label "Tab Color" + swatch items: None, Blue, Purple, Pink, Red, Orange, Yellow, Green, Teal, Gray

Bulk close confirmation dialog: "Close other tabs?" / "Close tabs to the right?" / "Close tabs to the left?" / "Close all editor tabs?", body "The selected tabs will be closed. Pinned tabs will stay open.", button "Close tabs".

Browser-tab and editor-tab context menus exist too (`BrowserTab.tsx`: Duplicate Tab, Pin/Unpin Tab, Close, Close Others, Open In Browser; `EditorFileTabContextMenu.tsx`: Rename, Pin/Unpin Tab, Close, Close Others, Close All Editor Tabs, Open Markdown Preview, Copy Path, Copy Relative Path).

### 3.4 New-tab menu (`tab-bar/TabBarCreateEntry.tsx`, `tab-bar-static-create-menu.tsx`, `TabBarCreateEntryRow.tsx`, `tab-create-entry-copy.ts`) [verified from source]

Dropdown w 288, radius 11, border `border/80`, p 4, shadow `0 16px 36px rgba(0,0,0,.24)`. Top: an **omnibox** input h 36, 12 pt, placeholder **"Search open tabs, history, files, URLs, agents…"**. Static rows (icon 16 muted, shortcut right-aligned):

| Row | Icon | Shortcut |
|---|---|---|
| "New Terminal" (or "New Terminal: {shell}" per shell profile; Windows adds WSL / Git Bash / CMD Prompt / PowerShell) | `TerminalSquare` | ⌘T |
| agent rows "Launch agent" (installed agents, default agent ⌥⌘T) | agent icons | ⌥⌘T for default |
| "New Browser Tab" | `Globe` | ⌘⇧B |
| "New Mobile Emulator" / "Go to Mobile Emulator" ("Open the existing emulator tab.") | `Smartphone` | ⌥⌘⇧E |
| "New Markdown" | `FilePlus` | ⌘⇧M |
| "Open Markdown..." | `FileText` | ⌘⇧O |

Typing turns rows into results: "Switch to tab", "Open page", "Launch agent", "Search {query}", "Open URL", "Open file", "Create file" (icons `Search`, `Globe`, `FileText`, `FilePlus`, `GitCompare`, `Loader2`); empty prompt "Choose an action.".

### 3.5 Quick commands (`tab-bar/TabBarQuickCommandsButton.tsx`, `TabBarQuickCommandsMenu.tsx`, `TabBarQuickCommandItem.tsx`, `terminal-quick-commands/*`) [verified from source]

Button: `Play` 14 + "Command" (12/500, hidden under 480 pt), h 28 px 6 radius 8; tooltip "Save a quick command for this repo" when empty. Menu: search "Search quick commands...", rows "Run: {label}" with hover actions `Copy` "Copy {label}", `Pencil` "Edit {label}", `Trash2` "Remove {label}" (confirm "Delete "{label}"?" / "This quick command will be removed from your saved list."), groups Global / Project, empty "No commands" / "No commands match", footer `Plus` "Command" / "Command on {host}" (add). Add/Edit dialog "Add Quick Command" / "Edit Quick Command" ("Saved items appear in the tab bar menu for one-click run."): Action toggle "Terminal Command" | "Agent Prompt"; Label (placeholder "Start dev server"); Command (placeholder "npm run dev") or Prompt + Agent picker; switch "Append Enter — run immediately" ("Submit immediately instead of only inserting text."); Advanced ▸ Scope Global / Project; footer "Cancel", "Save".

### 3.6 Recent tab switcher (`tab-bar/RecentTabSwitcher.tsx`) [verified from source]

Ctrl-Tab: overlay "Switch tabs" listing recent tabs with kind icons (`TerminalSquare`, `Globe2`, `FileText`, `GitCompare`).

## 4. Terminal pane

### 4.1 Terminal context menu (`terminal-pane/TerminalContextMenu.tsx`) [verified from source; per-item icon mapping inferred from the imported icon set]

1. "Copy" ⌘C (`Copy`) · "Select All" ⌘A (`TextSelect`) · "Paste" ⌘V (`Clipboard`)
2. "Quick Commands" ▸ (`Play`): "Insert", groups Global / project, "No quick commands", `Plus` "Add Quick Command…", "Add to {project}…"
3. agent panes: `MessageSquarePlus` "Hand Off to Another Agent", `GitFork` "Fork Agent Session…", `ClipboardCopy` "Copy Context", `MessageSquare`/`SquareTerminal` "Continue in Chat UI" / "Continue with Terminal Agent"
4. — "Split Terminal Right" ⌘D (`PanelRightClose`) · "Split Terminal Down" ⌘⇧D (`PanelBottomClose`) · "Equalize Pane Sizes" (`PanelsTopLeft`, with splits) · "Expand Pane" / "Collapse Pane" ⌘⇧↩ (`Maximize2`/`Minimize2`, with splits)
5. — "Set Title…" (`Pencil`) · "Clear Pane Title" (`X`, when titled) · "Copy Session ID" (agent) · "Copy Terminal ID" (`Copy`) · "Copy Pane ID" (`Copy`)
6. — "Close Pane" ⌘W (`X`, destructive, with splits)
7. — "Clear Screen" (`Eraser`, ⌘K) · "Reset Terminal" (`RotateCcw`)

### 4.2 Pane title bar (`terminal-pane/TerminalPaneHeaderOverlay.tsx`) [verified from source]

Shown when a pane has a title (Set Title…). 24 pt, mono 13 (UI-SPEC §6). Title text (double-click → input, placeholder "Pane title", aria "Edit pane title: {t}"), centre drag handle on hover, right actions 12 pt icons: `MessageSquarePlus` "Hand Off to Another Agent" (agents), `SquareTerminal` "Show terminal" (chat panes), `SquareSplitVertical` "Split Terminal Right", `X` "Close Pane" (or "Close tab" for a single pane), `X` "Remove title".

### 4.3 Find bar (`TerminalSearch.tsx`) [verified from source]

⌘F in a terminal: floating bar top-right: input "Search...", `CaseSensitive` "Case sensitive", `Regex` "Regex", match counter / "No results", `ChevronUp` "Previous match", `ChevronDown` "Next match", `X` "Close".

### 4.4 Pane overlays and banners [verified from source]

| Overlay | Copy | Controls |
|---|---|---|
| Process exited (`TerminalProcessExitOverlay.tsx`) | "Terminal exited" / "The shell process ended with exit code {code}. Its output is preserved." | `X` "Close", `RotateCw` "Restart" |
| Restoring (`TerminalRestoringPlaceholder.tsx`) | `Loader2` "Restoring terminal…" | — |
| Sleeping (`TerminalSleepingPaneOverlay.tsx`) | `Moon` "Sleeping — click to resume" (+ reasons: host load, too many agents…) | `Play` "Resume", "Resume automatic restores" |
| Error toast in pane (`TerminalErrorToast.tsx`) | reattach / reconnect messages ("Reconnecting this terminal — its output is being re-established…") | "Retry", "Restart daemon", "Open new terminal" |
| SSH reconnect (`TerminalSshReconnectOverlay.tsx`) | "SSH connection required" / "SSH connection failed" / "SSH host removed" | Connect, "Remove workspace" |
| Remote runtime banner | "Reconnecting to remote runtime" / "Remote runtime disconnected" | "Reconnect" |
| Pane-top warning (`PaneTopWarningBanner.tsx`) | `TriangleAlert` + text | "Learn more", "Don't show again", "Dismiss" |
| Mobile driving (`MobileDriverOverlay.tsx`) | "Your phone is in control" / "Desktop typing is paused. Output keeps streaming." | "Take back", "Minimize" |
| Drop overlay | blue 20 % fill, 2 pt border, radius 4 (UI-SPEC §6) | — |

### 4.5 Close confirmations [verified from source]

- `CloseTerminalDialog.tsx`: "Stop running command?" / "Closing this terminal will stop the command running inside it." (agent: "Stop this agent?" / "Closing this terminal will stop the agent's current work."), note "This terminal will not resume automatically. Cancel and put the workspace to sleep to resume it later.", checkbox "Don't ask again for running terminals", buttons "Cancel", **"Stop and Close"** / "Stop Agent".
- `PinnedTabCloseDialog.tsx`: "Close pinned tab?" / "This tab is pinned. Are you sure you want to close it?", checkbox "Don't ask again for pinned tabs", "Cancel", "Close".

## 5. Right sidebar

### 5.1 Activity bar (`right-sidebar/use-right-sidebar-activity-items.ts`, `right-sidebar-top-activity-bar.tsx`, `activity-bar-buttons.tsx`, `activity-bar-position-menu.tsx`) [verified from source]

Geometry in UI-SPEC §7. Items, in order, with visibility rules:

| id | Title (tooltip; + shortcut) | Icon | Shown for |
|---|---|---|---|
| explorer | "Explorer" (⌘⇧E) | `Files` | always |
| vault | "Agents" | custom `AgentSessionHistoryIcon` (`agent-session-history-icon.tsx`) | always |
| workspaces | "Attached worktrees" | `Workflow` | **folder workspaces only** |
| pr-checks | "PR Checks" | `ListChecks` | **folder workspaces only** |
| source-control | "Source Control" (⌘⇧G) | `GitBranch` | **Git only** |
| checks | "Checks" | `ListChecks` | **Git only**; status dot 7 pt top-right (pass/fail/pending colour) |
| ports | "Ports" (⌘⇧I) | `Plug` | always |
| plugins | plugin titles | plugin icons | experimental plugins |

Overflow: `MoreHorizontal` "More sidebar tabs" dropdown. Right-click on the bar: "Activity Bar Position" ▸ **Top** / **Side**. Close toggle `PanelRight` "Toggle right sidebar (⌘L)". Default tab `explorer`, open by default, width 350.

### 5.2 Explorer (`FileExplorer.tsx`, `FileExplorerToolbar.tsx`, `FileExplorerViewSwitch.tsx`, `FileExplorerRootSelect.tsx`, `FileExplorerNameFilter.tsx`, `FileExplorerTreeStatus.tsx`, `FileExplorerRow.tsx`, `file-explorer-row-context-menu.tsx`, `FileExplorerBackgroundMenu.tsx`, `SearchQueryRow.tsx`, `SearchFilters.tsx`, `SearchResultsPane.tsx`) [verified from source]

- Header row: root select (`FolderTree` + "Repository root" / "Explorer root", `ChevronDown`); segmented switch "Names" ("Filter files by name") | "Contents" ("Search file contents"), aria "Explorer search mode"; toolbar `ListCollapse` "Collapse All", `RefreshCw` "Refresh Explorer", `Ellipsis` "More Explorer Actions" → checkable "Show Dotfiles", "Show Git Ignored Files".
- Names mode: filter field `ListFilter` "Find files" / "Find in {path}", `X` "Clear file filter".
- Contents mode (⌘⇧F): query row `Search` "Search files", toggles `CaseSensitive` "Match Case", `WholeWord` "Match Whole Word", `Regex` "Use Regular Expression", `X` "Clear search"; `Ellipsis` "Toggle search details" → "files to include" (e.g. `*.ts, src/**`), "files to exclude" (e.g. `*.min.js, dist/**`); results "{n} result(s) in {m} file(s)", "(results truncated)", "Press Enter to search", "No results. Try another search or adjust your filters.", "Type to search in files".
- Tree rows: `ChevronRight` disclosure, `Folder`/`FolderOpen` 12, file-type icon, git decoration colours, `Link` symlink, `CircleSlash` "Ignored by .gitignore", `Loader2`; radius 6, 12 pt, indent 16/level.
- Row context menu: `FilePlus` "New File", `FolderPlus` "New Folder", — `Copy` "Copy", "Copy Path(s)", "Copy Relative Path(s)", `Files` "Duplicate", "Add as Project...", `SquareTerminal` "Open in Terminal", `Eye` "View File", `Globe` "Open in smthz Browser", "Open Markdown Preview", `Download` "Download (Folder)", `ListCollapse` "Collapse Folder", `Search` "Find in Folder", — `Pencil` "Rename" (Enter), `Trash2` "Delete". Background menu: "New File", "New Folder".
- Empty/status: "Select a workspace to browse files", "Select a workspace to search", "No files in this workspace", "No files in this folder", "Could not load files for this workspace: …".

### 5.3 Agents / session history (`AiVaultPanel*.tsx`, `AiVaultSession*.tsx`) [verified from source]

Header "Agents" (subtitle "Indexed history" / "Resume past sessions"), `RefreshCw` "Refresh Session History", `Search` "Search sessions" (+ `X` "Clear search"). Controls: scope segmented "Workspace" | "Project" | "All"; host picker (`Server`); `ListFilter` "View options" (agent checklist "Select all"/"Clear", Group by "Folder"/"Agent", "Hide empty sessions", "Reset view"). List bar "{n} sessions" / "{x} of {y} sessions", history-depth menu ("Unlimited", "Recommended", "May be slower", "Slowest"). Rows: agent icon, title, time, hover "Continue in CLI", "Show Details"/"Hide Details", drag "Drag to resume in a new tab"; row menu `Play` resume, `LocateFixed` "Jump to Original Pane", "Jump to Folder/Worktree", `Copy` "Copy Resume Command", `MessageSquarePlus` "Hand Off to Another Agent", `FileJson` "Open Log", "Reveal Log", `FolderOpen` "Open Working Directory", "Copy Session ID", "Copy Log Path", `Trash2` "Delete". States: `LoaderCircle` "Scanning sessions", full-text search enablement copy ("Enable full-text search?…", "Enable").

### 5.4 Source Control (`right-sidebar/source-control/**`) [verified from source]

Header: branch compare "Current branch: {b} vs {base}" ("Change base ref", `ExternalLink` "Open review page in browser"), toolbar `List` "View as list" / `ListTree` "View as tree", `MessageSquare` "Notes", `RefreshCw` "Refresh branch compare", `MoreHorizontal` "More source control actions" (`Settings2` "Change Base Ref"…). Filter `Search` "Filter files…". Commit box: "Message" textarea (aria "Commit message"), `Sparkles` "Generate commit message with AI" (stop `Square`), primary split button **Commit** / Push / Pull / Sync / "Publish Branch" (`Check`, `ArrowUp`, `ArrowDownUp`, `CloudUpload`) with dropdown "Commit", "Commit & Sync", "Fetch" ("Fetch from remote without merging"), "Create {PR}". Sections **"Staged Changes"**, **"Changes"**, **"Untracked Files"** with header actions `Minus` "Unstage all", `Plus` "Stage all", `Undo2` "Discard all", "View all"; file rows with `Plus` "Stage", `Minus` "Unstage", `Undo2` "Discard changes", `Trash` "Delete untracked file", counts "+n −m"; file context menu `Eye` "View", `Copy` "Copy Path", "Copy Relative Path", `FolderOpen` "Open in" ▸, "Open in File Explorer". Conflicts block (`GitMerge` "Merge conflicts", "Resolve with AI", "Abort merge/rebase"). "Committed on Branch" list ("{n} files changed vs {ref}"), Commits graph ("Commits", "Refresh commits", "No commits yet"). Discard confirm "Discard changes?" / "This cannot be undone." / "Discard". Empty: **"Select a workspace to view changes"**, "Source Control is only available for Git repositories", "No changes on this branch".

### 5.5 Checks (`right-sidebar/checks-panel/*`) [verified from source]

Empty states: "No workspace selected" / "Select a workspace to view checks"; "Checks unavailable" / "Checks require a Git branch and hosted review context"; "Publish Branch", "Sync Branch", "Create {PR}" / "Push & Create {PR}". With a PR: review header (`GitMerge`, title, `Link` "Link another PR", `RefreshCw` "Refresh", `Ellipsis` "More PR actions", "Open on GitHub"), triage strip ("failing check · Inspect details or start an AI fix pass. · Fix", "pending", "Conflicts block this · Resolve"), checks list (`CircleCheck` passing / `CircleX` failing / `CircleDashed` pending / `LoaderCircle`; "No checks configured"; detail view "Jobs", "Annotations", "Retry"), comments ("Comments", "Grouped" / "Timeline", "Add comment", "Queue for agent", "Resolve"/"Unresolve").

### 5.6 Ports (`PortsPanel.tsx`, `local-workspace-ports-panel.tsx`, `local-port-row.tsx`, `ssh-ports-panel.tsx`, `ssh-port-forward-dialog.tsx`) [verified from source]

Local: header "Ports" + `RefreshCw` "Refresh Ports"; sections "Active Workspace", "Other Workspaces", "External" (`ChevronRight` collapsible); rows: port, process, `ExternalLink` "Open in Browser", menu "Port {n} menu": `Copy` "Copy {addr}", "Copy Address", "Copy Details", `Info` "Show Details", `Trash2` "Stop Process". States: "Scanning...", "No ports detected", "No local ports detected", "No workspace selected", "Port scan unavailable on {host}: {why}". SSH: "Forwarded" / "Detected" sections, `Plus` "Add", "No forwarded ports", "Forward a port to access remote services on your local machine.", button "Forward a Port"; dialog "Forward a Port" (Remote Port, Local Port "Same as remote", Remote Host "localhost", "Label (optional)" "dev-server", "Cancel" / "Forward").

### 5.7 Attached worktrees and PR Checks (folder workspaces) [verified from source]

`FolderWorkspaceWorktreesPanel.tsx`: "{n} attached worktrees", "No attached worktrees yet", "Worktrees created from this workspace will show up here." `FolderWorkspacePrChecks*.tsx`: per-worktree checks rows.

## 6. Status bar (`status-bar/StatusBarSurface.tsx` and segments) [verified from source]

h 24, `px-3 gap-4`, 12 pt, top border. **Left cluster** (flex 1): provider usage meters (Claude, Codex, Gemini, …; `inline-flex gap-3 rounded px-1 py-0.5 hover:bg-accent/70`) opening a 360 pt "Usage" dropdown (account switchers "Claude Account" / "Codex Account", "Manage Accounts…", "Detailed"/"Compact", "Refresh rate limits"); when nothing is configured an empty CTA (`StatusBarUsageEmptyCta.tsx`: `BarChart3` "Agent usage limits" → card "Connect your AI provider accounts to see their usage in real time and easily switch between accounts." / "Connect an account" / `EyeOff` "Hide from status bar"); `RefreshCw` refresh button. **Right cluster** (gap 12), in order:

| Segment | Trigger look | Popover / behaviour |
|---|---|---|
| Caffeinate (`Coffee`) | icon + "Active"/"Inactive" | modes "Keep this computer awake continuously", "Stay awake while an agent is working", "Allow normal system sleep behavior" |
| Remote server update | `RefreshCw` "Updating {x}/{y}" | only during updates |
| Skill update | `Loader2` "Updating skills" / `CheckCircle2` / `AlertCircle` | only during updates |
| Chat resume | `RotateCcw` "{n} chats to resume" | only after restart |
| App update | `Download` "smthz v{v} downloading… {p}%", `CheckCircle2` "Update ready", `AlertCircle` "Update failed" | click expands the update card |
| Pet | sprite | experimental |
| **Resource Manager** | `MemoryStick` 12 + memory "·" `Terminal` 12 + PTY count (11 pt tabular); `AlertTriangle` "Daemon unreachable" | popover "Resource Manager": summary (CPU, memory, `RotateCw` "Restart local daemon", `Trash2` "Kill all local sessions", "{n} orphans"), tree "Name / CPU" per repo/workspace (Expand/Collapse), session rows (`Trash2` "Kill session {n}" → dialog "Kill {n}?" / "Force-quits this terminal…" / "Kill session"), PTY list "This computer" (`Terminal` rows, `ArrowUpRight` "Go to terminal", "End" → "End {terminal}?" dialog), "Nothing running right now", "Clean up workspaces" |
| **Ports** | `Plug` + "{n} ports" ("Ports — {n} workspace · {m} external") | popover: "Scanning for workspace ports...", "No workspace ports detected", "External Ports", rows with Open in Browser / Copy / Stop Process / `FolderOpen` "Go to Worktree" |
| SSH / Remote hosts | `Server` (or `MonitorSmartphone`) + host count | popover "Remote Hosts": host rows "Connected"/"Disconnected"/"Reconnecting" with "Connect"/"Disconnect", "Manage Remote Hosts…" |
| Floating workspace chip | `PanelsTopLeft` 14 in a 20² bordered `secondary` chip; amber 6 pt dot for new activity | tooltip "Show floating workspace" / "Minimize floating workspace"; right-click "Move to Floating Button", "Hide Floating Workspace"; ⌥⌘A |

Segments collapse to icon-only when narrow (`status-bar-density.ts`). **Right-click anywhere on the bar** → visibility menu with checkboxes: Claude Usage, Codex Usage, Gemini Usage, Antigravity Usage, OpenCode Go Usage, Kimi Usage, MiniMax Usage, Grok Usage, ZCode Usage, Cursor Usage, Remote Hosts, Resource Manager, Ports (`StatusBarVisibilityMenu.tsx`). View menu "Show Status Bar" hides the whole bar.

## 7. Floating workspace (`floating-terminal/*`) [verified from source]

⌥⌘A toggles a floating panel over the window: window controls `Minus` "Minimize", `Maximize2` "Maximize" / `Minimize2` "Restore"; empty state rows `TerminalSquare` "New Terminal", `FileText` "New Markdown Note" / "Open Markdown Note", `Globe` "New Browser"; resize handles; orchestration card "Enable orchestration" ("Set up the smthz CLI and agent skill so agents can coordinate through smthz." / "Dismiss" / "Enable").

## 8. Notifications and toasts [verified from source]

- Toaster (`components/ui/sonner.tsx`, `App.tsx`): **bottom-right**, offset bottom 40 pt (above the status bar), close button on every toast, 14 pt sans; type icons `CircleCheck` (success), `Info` (info), `Loader2` (loading), `OctagonX` (error), `TriangleAlert` (warning). Toasts can carry an action button (e.g. "View", "Force Delete", "Open Settings", "Retry"). Styling in UI-SPEC §10.
- Notification card stack (`NotificationCardStack.tsx`): stacked cards for update (`UpdateCard.tsx`: "Your terminal sessions won't be interrupted during the update.", `X` "Dismiss tip"), star nag (`StarNagCard.tsx`: "Enjoying smthz?", "Star on GitHub" / "Later") [decide: no smthz GitHub page], telemetry notice (`FirstLaunchBanner.tsx`: "Help us decide what to build next", "Opt out" / "Got it").
- Native macOS notifications (Settings › Notifications): agent task complete, terminal bell, sound; tray/menu-bar item "smthz - activity waiting".
- Feature tips / contextual tours (`feature-tips/*`, `contextual-tours/*`): popover cards "Step {n} of {m}", `ArrowLeft` "Back", `ArrowRight` "Next", "Done", "Skip tour", `X` "Dismiss tour".

## 9. Palettes

### 9.1 Jump palette ⌘J — also the command palette (`WorktreeJumpPalette.tsx`, `worktree-jump-palette-*.tsx`, `cmd-j/*`) [verified from source]

Centred overlay dialog. Input placeholder **"Search chats, terminals, workspaces, tasks, settings, and actions..."**, title "Jump to...". Filter chips row ("Scoped to", `ListFilter` "Filter results" → Hosts / Projects with search, "Clear all"; Tab key opens the filter). Sections: **"Recent Chats & Terminals"**, **"Open Tabs"** ("Current Tab" badge), **"Recent Workspaces"** / **"Workspaces"** ("Current", "primary", "Last active {t} ago", host badge, SSH state), **"Projects & Groups"** (badges "Project", "Repo group"), **"Tasks"** ("Searching tasks…", "Some task sources could not be searched" + "Retry"), **"Actions & Settings"** (badges "Action", "Settings"; actions: "Create Worktree", "Delete Worktree", "New Terminal Tab", "New Markdown File", "New Browser Tab", "Add Quick Command", "Split Chat Right/Down", plugin commands; every Settings page is a row), website rows ("Go to {url}", "Website"), create row `Plus` **"Create worktree "{query}""**. Match labels "Comment", "Issue", "PR", "MR", "Port", "Task", "Run". Footer hints: keycaps "Enter" Open · "Esc" Close · "↑↓" Move · "Tab" Filter. Empty states: "Type to search worktrees, settings, tabs, and actions.", "No results match your search" + "Try a worktree, setting, action, tab title, agent prompt, URL, PR, or port.", "No active worktrees, settings, actions, or open tabs" + "Create a worktree or open a tab in smthz to get started.", loading "Loading jump targets" / "Gathering your recent worktrees and open tabs.". Selected row: fg 13 % over background + 1 pt inset fg 19 % ring (dark: accent + 16 % ring).

### 9.2 Go to file ⌘P (`QuickOpen.tsx`) [verified from source]

Same shell. Title "Go to file", placeholder "Go to file...", aria "Search for a file to open"; "Loading files...", "No matching files.", "More matches may be available. Refine your search to narrow the results.", "{n} files found"; footer Enter Open · Esc Close · Move. Needs `rg` (install guidance card when missing).

### 9.3 Keyboard shortcuts overlay [verified from source]

There is **no separate overlay**: Help ▸ "Keyboard Shortcuts" opens Settings › Shortcuts (`SidebarSettingsHelpMenu.tsx` `openShortcutsSettings`). The Shortcuts page lists every action from §15 with editable chords and a "Shortcuts in Terminal" setting.

## 10. Dialogs

### 10.1 New workspace composer (`NewWorkspaceComposerModal.tsx`, `NewWorkspaceComposerCard.tsx`, `new-workspace/*`) [verified from source]

Dialog `sm:max-w-lg` (512), title 16/600 **"Create workspace"** ("Create worktree" for Git, "Create Folder Workspace" for folders); sr-only description "Choose the project and workspace name. Select an agent if you want to start one." Sections top to bottom:

1. **Project** — label "Project" + ghost button `FolderPlus` "Add project"; combobox placeholder "Choose project" (`ProjectCombobox.tsx`: search, "Browse projects", "No projects yet.", "No projects match your search.", "Add project"); "Run on" target combobox (`Cloud`, "Choose target", "Add host" ▸ "Add SSH host", "Add Remote smthz Server"); SSH status "Connect"/"Connecting"/"Not connected".
2. **Create From** [Optional] — smart name field with source tabs **Smart · GitHub · GitLab · Linear · Jira · Branch · Name** (`SmartWorkspaceSourceTabs.tsx`; filters Open/Merged/Closed/All), result rows (`GitPullRequest`, `CircleDot`, `GitBranch`, `GitMerge`), "Use "{text}" as workspace name", "Create new branch", "Reuse branch".
3. **Agent [Optional]** — agent picker + `Settings2` "Open agent settings" / "Configure agents".
4. **Advanced** ▸ (`ChevronDown`) — "Name" ("Workspace name"), "Branch name" ("feature/my-branch"), "Note" ("Write a note"), base ref picker, parent worktree picker ("Parent worktree", "No parent", "Nests this workspace under another in the sidebar. Does not change the base branch."), setup-script choice ("orca.yaml" / "local settings", "Wait for setup to complete before starting agent"), "Sparse checkout".
5. Footer — switch "Create more", primary `sm` button "Create workspace" with ⌘↩ key hint (`LoaderCircle` while creating).

### 10.2 Add project (`sidebar/AddRepoDialog*.tsx`, `AddRepoStartSteps.tsx`, `add-repo-local-start-actions.ts`, `AddRepoSteps.tsx`, `AddRepoCreateStep.tsx`, `AddRepoHostSelector.tsx`) [verified from source]

Start step: title "Add a project", subtitle "Add a project to get started with smthz."; host selector ("Host", "Add remote host": SSH host / remote server / WSL distro); primary card `FolderOpen` **"Browse folder"** ("Local project, Git repo, or folder with many repos"); "Other ways to add": `Plus` "Create new project" ("Start from an empty folder"), `Globe` "Clone from URL" ("Clone a remote Git repository"), `Monitor` SSH ("Open a project from an SSH target"). Scanning state `Loader2` "Scanning repositories. Click to stop." (`CircleStop` "Stop scan"). Clone step: "Clone from URL", "Git URL" (`https://github.com/user/repo.git`), "Clone location"/"Parent folder", "Choose folder", "Clone"/"Cloning...". Create step: "Create a new project" ("Name it and smthz will create a real project with sensible defaults."), "Name" (`my-project`), Git repository toggle, "Create project". Back `ArrowLeft` "Back". After adding: `ProjectAddedDialog.tsx` (default checkout choice).

### 10.3 Other dialogs from the main window [verified from source]

| Dialog | Key copy |
|---|---|
| Delete workspace (`DeleteWorktreeDialog*.tsx`) | "Delete Workspace(s)", target preview, dirty-change hint, lineage notice, "Don't ask again" option ("We'll skip this confirmation next time. You can change this in Settings."), "Cancel" / destructive "Delete"; failure toasts with "Force Delete" |
| Workspace meta / Update (`WorktreeMetaDialog.tsx`) | display name, emoji, notes, linked issue/PR fields |
| Remove folder, sleep twin, worktree visibility, orca.yaml trust (`OrcaYamlTrustDialog.tsx`), forget SSH workspace, host rename/remove, project group name/delete, auto-rename failed, feedback (`SidebarFeedbackDialog.tsx`, image attachments) | per file |
| Quick command add/edit | §3.5 |
| Close running terminal / pinned tab / bulk close | §4.5, §3.3 |
| Fork agent session (`TerminalAgentSessionForkDialog.tsx`) | "Fork Agent Session", "Copy context", "Create fork" |

## 11. Settings page

Shell: UI-SPEC §11. Sidebar (`settings/SettingsSidebar.tsx`) [verified from source]: `ArrowLeft` **"Back to app"**; search "Search settings" (⌘F); groups below; a **Projects** group at the end with one entry per project (`Server` "SSH" pill for remote ones; "No projects added yet.", "No matching project settings."); pills "Update available" (amber), "Review skill"; onboarding entry "Onboarding checklist, {x} of {y} done. Show setup guide.". Content (`settings-page-renderer.tsx`): "Loading settings...", search miss "No settings found for "{q}"". Section header = title 24/600 + optional badge (10 pt uppercase) + description.

### 11.1 Navigation (`hooks/settings-navigation-*-sections.ts`, `components/settings/settings-navigation-foundations.ts`) [verified from source]

| Group | Page (title — smthz label) | Icon | Badge | Description |
|---|---|---|---|---|
| AI Capabilities | Agents | `Bot` | Optional | Manage AI agents, set a default, and customize commands. |
| | AI Provider Accounts | `UserCog` | Optional | Optional account switching and usage setup for Claude, Codex, Gemini, OpenCode Go, MiniMax, and Grok. |
| | Orchestration | `Network` | | Coordinate multiple coding agents through smthz. |
| | Linear (conditional) | Linear glyph | | How Linear works in smthz, setup checklist, agent skill, and example prompts. |
| | Computer Use (conditional) | `MousePointerClick` | | Enable agents to control any app on your computer. |
| | Voice (conditional) | `Mic` | | Local speech-to-text dictation with on-device models. |
| Set Up | smthz Account (conditional) | `CircleUserRound` | | Share work instantly and reach your desktop from smthz Mobile wherever you are. |
| | Onboarding checklist | logo glyph | | Finish the onboarding checklist for core smthz workflows. |
| | General | `SlidersHorizontal` | | Workspace defaults, app setup, and maintenance. |
| | Integrations | `Blocks` | | Connect GitHub, GitLab, Linear, and source-hosting services. |
| | Mobile (conditional) | `Smartphone` | | Control terminals and agents from your phone. |
| Workflows | Automations | `CalendarClock` | Beta | Schedule agent work and choose whether Automations appears in the sidebar. |
| | Artifacts | `Files` | Beta | Share HTML and Markdown files with your team and manage their public links. |
| | Share Skills | `BookOpen` | Beta | Share your skills with an unlisted link. Anyone who has it can install them. |
| | Agent Session Search | `History` | | Search everything your agents have said and done, on this computer and on any paired smthz server. |
| | Git & Source Control | `GitBranch` | | Branch naming, base refs, and Git AI Author. |
| | Task Sources | `ListChecks` | | Connect providers, install the Linear skill, and choose what appears in Tasks. |
| | Terminal | `SquareTerminal` | | Shells, renderer, sessions, and terminal behavior. |
| | Quick Commands | `Play` | | Saved terminal commands, scoped globally or per project. |
| | Browser | `Globe` | | Home page, link routing, and session cookies. |
| | Mobile Emulator | `TabletSmartphone` | | Configure mobile emulator support for smthz and coding agents. |
| | Floating Workspace (desktop only) | `PanelsTopLeft` | | [description computed; not read] |
| Interface | Appearance | `Palette` | | Theme, zoom, app and terminal appearance, sidebars, and status bar. |
| | Chat | `MessageSquare` | | Choose how chats look and behave. |
| | Input & Editing | `TextCursorInput` | | Selection and editing behavior. |
| | Notifications | `Bell` | | Native desktop notifications for agent and terminal events. |
| | Shortcuts | `Keyboard` | | Keyboard shortcuts for common actions. |
| | Stats & Usage | `BarChart3` | | smthz stats plus Claude, Codex, OpenCode, Muse token analytics and Grok subscription usage. |
| Remote Hosts | SSH Hosts | `Cable` | | Use existing machines over SSH for files, terminals, Git, and workspaces. |
| | Remote smthz Servers (not in web client) | `Server` | | [description computed; not read] |
| Privacy & Security | macOS Permissions | `ShieldCheck` | | macOS privacy access for terminal-launched developer tools. |
| | Privacy & Telemetry | `Lock` | | Anonymous usage data and telemetry controls. |
| Advanced | Advanced | `Wrench` | | Low-level compatibility settings for troubleshooting. |
| | Dev Tools (dev builds) | `Bug` | Dev | Dev-only tools for exercising UI states. |
| Experimental | Experimental | `FlaskConical` | | New features that are still taking shape. Give them a try. |
| | Plugins | `Blocks` | | Install and manage experimental smthz plugins. |
| Projects | one row per project | project icon | SSH | per-project page |

### 11.2 Controls per page (titles from each page's search index, `components/settings/*-search.ts`) [verified from source; control types for Appearance and Terminal read in the pane files, others inferred from titles]

| Page | Settings (in order of the search index) |
|---|---|
| Agents | Agents (list, default agent, custom commands) · Agent Runtime · Agent Permissions · Prompt Cache Timer |
| AI Provider Accounts | Account Location · Claude Accounts · When you switch accounts while Claude is running · Codex Accounts · Active Codex Account · Use Gemini CLI credentials · OpenCode Go Session Cookie · OpenCode Go Workspace ID · MiniMax Usage · Grok (xAI) Usage · Antigravity Accounts · Cursor Usage · GLM Coding Plan |
| Orchestration | Agent Orchestration |
| Linear / Computer Use / Voice | Linear · Computer Use · OpenAI Transcription, Enable Voice Dictation, Dictation Mode, Microphone, Speech Model |
| smthz Account | smthz account · Machine name |
| General | Workspace Directory · External worktrees · Nest Workspaces · Ask Before Deleting Workspaces · Ask Before Deleting Automations · Open In Apps · Tab Order · Reuse a preview tab when browsing files · Confirm before closing pinned tabs · Confirm before closing running terminals · smthz CLI · Agent skill · Check for Updates · Default Project Runtime · editor block: Auto Save Files, Auto Save Delay, Editor Font Family, Editor Word Wrap, Collapse Unchanged Regions, Default Diff View, Default Diff File Tree, Minimap, Rich Markdown Spellcheck, Markdown Review Notes · support: Star on GitHub [decide] |
| Integrations | GitHub · GitLab · Bitbucket · Azure DevOps · Gitea · Jira · Linear Integration (each with connect status) |
| Mobile | Mobile · Show smthz Mobile Button · Network Interface · Mobile Pairing · Connected Devices · When you leave the mobile app |
| Automations / Artifacts / Share Skills | Show Automations Button · Allow publishing public artifact links, Show Artifacts Button · Unlisted skill links |
| Agent Session Search | computer list, indexing toggle, advanced |
| Git & Source Control | Branch Prefix · Jira Key Casing · Keep Local Main Up to Date · Source Control Group Order · Default Compare Base · Auto-rename branch & worktree · Branch name command template · Show Source Control AI actions · Action recipes · PR creation defaults · GitHub API Budget · GitLab API Budget |
| Task Sources | Task Providers |
| **Terminal** | Terminal shell (System shell ({path}) / Custom shell; Advanced: Shell arguments "-l (default)" / "Custom args") · **Typography**: Font Size (stepper `Minus`/`Plus`, px), Font Family, Font Weight, Bold Font Weight, Line Height, Font Ligatures (Auto / On / Off), "Import from Ghostty" · **Rendering**: GPU Acceleration (Auto/On/Off), Color Contrast (Automatic / Off / Custom, Subtle…Strong), Inline Images · **Cursor**: Cursor Shape (Bar / Block / Underline), Blinking Cursor, Cursor Opacity · **Themes**: Theme Mode (Dark / Light / Match dark mode), Dark Theme, Light Theme (theme picker "Built-in" / "Imported", search "Search terminal themes", "No themes found."), Dark/Light Divider Color, Import from YAML / Warp, live preview (`Sun`/`Moon`, "Show pane divider in preview") · **Panes**: Inactive Pane Opacity, Divider Thickness · **Interaction**: Scroll Speed (Normal / Fast / TUI, `RotateCcw` "Reset"), Right-click to paste, Focus Follows Mouse, Copy on Select, Trim Gutter on Copy, Allow TUI Clipboard Writes (OSC 52), Ask Before Closing Running Terminals · **Window**: Background Opacity, Window Blur ("Restart required"), Horizontal Padding, Vertical Padding, Hide Mouse While Typing, Color Overrides ("Reset all color overrides") · Manage Sessions · **Advanced**: Scrollback Rows ("{n} rows" / Custom), Word Separators, Option as Alt (Auto / Both / Left / Right / Off), JIS Yen (¥) to Backslash |
| Quick Commands | Quick Commands (list + add dialog §3.5) |
| Browser | Default Home Page · Default Search Engine · Default Zoom · Link Routing · Terminal URL clicks · Localhost Worktree Labels · Session & Cookies · Site permissions · Browser identity · Install Browser Use Skill · Import Browser Cookies |
| Mobile Emulator | Mobile Emulator · Default Emulator Device · Emulator Availability · Agent CLI Control |
| Floating Workspace | Floating Workspace |
| **Appearance** | tabs **Interface** (`AppWindow`) · **Terminal** (`TerminalSquare`) · **Window & Sidebar** (`PanelLeft`, "Sidebar, status bar, and file explorer"). Interface: Theme (segmented **System / Dark / Light**), Language, UI Zoom ("when not in a terminal pane"), IDE Font ("Default font"), Titlebar App Name, App Icon ("Choose the app icon shown in the Dock and window switcher."), Minimize to Tray on Close, Show Menu Bar Icon ("Keep a smthz shortcut and activity indicator in the macOS menu bar."), Follow symlinked directories. Window & Sidebar: **Status Bar** ("Choose which indicators appear in the status bar." + the §6 checkboxes, Usage percentages Used / Remaining), **Sidebar** (Workspace Card Layout Detailed / Compact, Show Tasks Button, Show Automations Button, Show smthz Mobile Button "Show the smthz Mobile shortcut in the sidebar. It remains available from Toolbox.", Also show pinned worktrees in their original lists), **File Explorer** (Show Git-Ignored Files "Files matched by .gitignore.") |
| Chat | Match terminal interface · Contrast · Text size · Code text size · Width · Reset chat appearance · Resume working chats automatically after a restart · Queue follow-ups · Use your shell environment · Inline visuals · Chat names · Permissions for new chats · Providers |
| Input & Editing | Middle-click Paste from Selection |
| Notifications | Enable Notifications · Agent Task Complete · Terminal Bell · Machines · Suppress While Focused · Notification Sound · Notification Volume · Send Test Notification |
| Shortcuts | full table §15 (editable), Shortcuts in Terminal |
| Stats & Usage | stats dashboards (`components/stats/*`) |
| SSH Hosts | SSH Connections · Add SSH Target · Import from SSH Config · Test Connection |
| Remote smthz Servers | server list, pair |
| macOS Permissions | Developer Permissions · Microphone and Camera · Screen Recording and Accessibility · Full Disk Access · LAN, USB, and Bluetooth |
| Privacy & Telemetry | Share Anonymous Usage Data · Diagnostics · Telemetry environment variables |
| Advanced | HTTP/1.1 Compatibility · Network |
| Experimental | Pet · Agent Dashboard · Terminal attention · Agent sleep · Chat UI · New card style · WSL distros as hosts · Cloud VM |
| Plugins | Plugins |
| Project page (`RepositoryPane.tsx`) | Display Name · Project Icon · GitHub Account · Keep Fork Up to Date · Project Runtime · Default Jira project · Git AI Author · MCP Configs · Setup Script · Archive Script · When to Run Setup · Custom GitHub Issue Command · External worktrees · Default Worktree Base · Worktree Location · Sparse Checkout Presets · Worktree Shared Paths · Remove Project |

## 12. Landing and onboarding

### 12.1 Landing (`Landing.tsx`) [verified from source]

Geometry UI-SPEC §9. Logo tile (aria "smthz logo"); title — Orca renders **"ORCA"** uppercase 36/700 [decide: "SMTHZ" vs "smthz"]; optional preflight issues card (`AlertTriangle`); copy "Add a project to get started." / "Select a workspace from the sidebar to begin."; buttons `FolderPlus` 14 "Add project" and `GitBranchPlus` 14 **"Create " + lowercase target** ("Create workspace" / "Create worktree"); shortcut list "Create workspace" ⌘N, "Move up workspace" ⌘⇧↑, "Move down workspace" ⌘⇧↓; footer GitHub star button (`Star` "Star on GitHub" / "Starred on GitHub", `X` "Hide") [decide: no smthz GitHub]. Tab group with no content: "Loading editor...".

### 12.2 Onboarding (`onboarding/*`) [verified from source]

Full-window flow "Welcome to smthz" with a step rail ("Go to onboarding step {n}: {title}", "{n} of {m}"): **Language** ("Display language", "System language: {x}", "Other language…") → **Default Agent** ("Pick your default agent", "Detected on your system", "Popular agents", "Yolo mode") → **Appearance** ("Make it feel like home": System "Match OS" / Dark "Easy on the eyes" / Light "Bright & crisp", Ghostty import, preview chips Font, Cursor, Theme palette, Colors, Padding, Window, Dividers, Mouse, macOS Option key) → (Windows Terminal, Windows only) → **Notifications** ("Set up notifications", "Allow notifications for smthz", "Open System Settings") → **Integrations** ("Set up GitHub tasks", GitHub CLI status "Install gh"/"Sign in"/"Re-check", Linear) → **Add your first project**. Buttons "Continue", `ChevronLeft` "Back", "Skip to project setup"; skip confirm "Skip onboarding?" / "It won't take long!" / "Skip" / "No, keep going".

## 13. App menu bar (Electron menu, `i18n` `menu.*`) [verified labels; menu structure inferred from labels]

App: "Check for Updates...", "Settings" (⌘,), Quit smthz · File · Edit (Copy, Paste, Select All…) · **View**: Toggle Left Sidebar, Toggle Right Sidebar, Show Status Bar, Appearance ▸ (Show Tasks Button, Show Automations Button, Show smthz Mobile Button, Show Titlebar App Name), Open Worktree Palette, Reload, Force Reload, Reset Size, Zoom In, Zoom Out · Window · **Help**: "Explore smthz", "Getting Started with smthz", "Report Crash...".

## 14. Other destinations reachable from the sidebar [verified file names; contents summarised only]

- **Tasks** page (`task-page/*`, `TaskPage*`): provider source bar (GitHub / GitLab / Linear / Jira), lists, pagination, "Close tasks" (`X`, "Close · Esc").
- **Automations** page (`automations/*`): breadcrumb "Automations / Runs / Run details", toolbar `RefreshCw` "Refresh automations", `History` "Runs", `Plus` "New Automation"; empty "Create an automation to start scheduling agent work."; table columns (Schedule, Next run, Host, Last run…), editor dialog "Create automation" / "Edit automation".
- **smthz Mobile** page (`mobile/*`): pairing ("Step 1 of 2", "Get the app.", QR, iOS/Android, "Release channel" Preview/Stable).
- **Workspace board** drawer (Kanban) — §2.6.

## 15. Default keyboard shortcuts (macOS) (`shared/keybindings/definitions-core-1..4.ts`) [verified from source]

| Group | Action | Chord |
|---|---|---|
| Global | Go to File | ⌘P |
| | Open Settings | — (unassigned; ⌘, via app menu) |
| | Force Reload | ⌘⇧R |
| | Switch worktree (jump palette) | ⌘J |
| | Previous / Next worktree | ⌘⇧↑ / ⌘⇧↓ |
| | Create worktree | ⌘N, ⌘⇧N |
| | Rename worktree | ⌥⌘R |
| | Delete Workspace | ⌘⇧⌫ |
| | Select Workspace 1–9 | ⌘1…⌘9 |
| | Dictation | ⌘E |
| | Toggle Sidebar / Right Sidebar | ⌘B / ⌘L |
| | Show Explorer / Search / Source Control / Ports | ⌘⇧E / ⌘⇧F / ⌘⇧G / ⌘⇧I |
| | Focus worktree list | ⌘⇧0 |
| | Toggle Floating Terminal / Maximize floating panel | ⌥⌘A / ⌥⌘⇧A |
| | Zoom In / Out / Reset | ⌘= (⌘⇧+) / ⌘− / ⌘0 |
| | Worktree history back / forward | ⌥⌘← / ⌥⌘→ |
| | Workspace board, Agent dashboard, Open Tasks, Show Checks, Toggle sleeping, Toggle child workspaces, Send review notes | unassigned |
| Tabs | New terminal tab / New agent tab / New browser tab | ⌘T / ⌥⌘T / ⌘⇧B |
| | New mobile emulator / New markdown / Open markdown | ⌥⌘⇧E / ⌘⇧M / ⌘⇧O |
| | Close active tab / Close all editor tabs | ⌘W / ⌥⌘W |
| | Rename active tab / Reopen closed tab | ⌘R / ⌘⇧T |
| Tab navigation | Next / previous tab (same type) | ⌥⌘] / ⌥⌘[ |
| | Next / previous tab (all types) | ⌘⇧] / ⌘⇧[ |
| | Previous recent tab | ⌃Tab |
| | Next / previous terminal tab | ⌃PageDown / ⌃PageUp |
| | Select Tab 1–9 | ⌃1…⌃9 |
| Terminal panes | Copy / Select all / Paste | ⌘C / ⌘A / ⌘V |
| | Search active pane / Clear active pane | ⌘F / ⌘K |
| | Focus next / previous pane | ⌘] / ⌘[ |
| | Expand / collapse pane | ⌘⇧↩ |
| | Close active pane | ⌘W |
| | Split right / down | ⌘D / ⌘⇧D |
| | Equalize pane sizes, Set Title…, Clear Pane Title | unassigned |
| Browser, Editors, File Explorer, Settings, Chat | Find ⌘F; editor Save ⌘S, Replace ⌥⌘F, Markdown preview ⌘⇧V, Word wrap ⌥Z…; Settings search ⌘F | per table in source |

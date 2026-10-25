# UI-SPEC — Orca 1.4.238 look and behaviour, for the native smthz shell

Status: research spec, 2026-10-24. Author: worker for task `task_279149630b03`. Source root: `reference/orca-1.4.238` (read-only); all paths below are relative to `src/` unless they start with `reference/`.

**Evidence tags.** `[verified]` = read in the source quoted next to it. `[inferred]` = derived (arithmetic on tokens, Tailwind defaults, Electron behaviour, or no direct source). `[decide]` = 1:1 conflicts with a smthz product rule, Liquid Glass or native macOS; the user must choose (collected in §15).

**What was not done.** No screenshot of the running Orca was taken: `orca computer list-windows --app com.stablyai.orca` reported "No windows found" (Orca's window was not on screen) and restoring it would have taken focus from the user. Every value here comes from source, not from pixels. Nothing in this file was checked against a rendered Orca window.

**Units.** Orca renders CSS px at UI zoom 1 (`--ui-zoom-factor`, `renderer/src/assets/main.css`), 1 rem = 16 px. On macOS 1 CSS px = 1 pt, so the numbers below are points. Tailwind is v4.3 (`package.json`), shadcn style `new-york-v4`, base colour `neutral` (`reference/orca-1.4.238/components.json`) [verified]. Tailwind v4 palette colours are OKLCH; the hex values given for named Tailwind colours (orange-600, yellow-500, …) are the v3 sRGB equivalents and can differ by about 1–2 % [inferred].

---

## 1. Design tokens

### 1.1 Colour tokens (`renderer/src/assets/main.css` `:root` / `.dark`) [verified]

| Token | Light | Dark | Used for |
|---|---|---|---|
| `--background` | `#ffffff` | `#0a0a0a` | window/page canvas, landing, settings content, dialogs |
| `--foreground` | `#0a0a0a` | `#fafafa` | primary text |
| `--card` | `#ffffff` | `#171717` | titlebar (`--bg-titlebar` fallback), tab strip, status bar |
| `--popover` | `#ffffff` | `#171717` | popovers, toasts |
| `--primary` / `--primary-foreground` | `#171717` / `#fafafa` | `#e5e5e5` / `#171717` | default buttons, badges |
| `--secondary` / fg | `#f5f5f5` / `#171717` | `#262626` / `#fafafa` | secondary buttons, landing buttons |
| `--muted` / `--muted-foreground` | `#f5f5f5` / `#737373` | `#262626` / `#a1a1a1` | secondary text, icons |
| `--accent` / fg | `#f5f5f5` / `#171717` | `#404040` / `#fafafa` | hover fills, selected menu rows |
| `--border` | `#e5e5e5` | `rgb(255 255 255 / 0.07)` | every 1 px seam |
| `--input` | `#e5e5e5` | `rgb(255 255 255 / 0.15)` | input borders/fill |
| `--ring` | `#a1a1a1` | `#737373` | focus rings (used at 50 %) |
| `--destructive` | `#e40014` | `#ff6568` | destructive text/buttons |
| `--editor-surface` | `#ffffff` | `#1e1e1e` | editor header/body |
| `--worktree-sidebar` | `#f5f5f5` | `#2a2a2a` | **left sidebar surface** and its 36 px header |
| `--worktree-sidebar-foreground` | `#0a0a0a` | `#fafafa` | sidebar text |
| `--worktree-sidebar-accent` | `#eaeaea` | `#353535` | active nav row, active settings nav row |
| `--worktree-sidebar-border` | `#e5e5e5` | `rgb(255 255 255 / 0.07)` | sidebar seams |
| `--worktree-sidebar-ring` | `#a1a1a1` | `#737373` | sidebar focus/selection rings |
| `--sidebar` | `#fafafa` | `#171717` | **right sidebar** surface |
| `--sidebar-accent` | `#f5f5f5` | `#262626` | right sidebar hover |
| `--sidebar-primary` | `#171717` | `#1447e6` | (right sidebar primary) |
| `--status-success` | `#15803d` | `#86efac` | success text/dots |
| `--status-warning` | `#ca8a04` | `#eab308` | needs-attention |
| `--agent-question` | orange-600 ≈`#ea580c` | orange-500 ≈`#f97316` | "agent is asking" everywhere |
| `--agent-working` | yellow-500 ≈`#eab308` | same | working glyphs |
| `--terminal-pane-locate` | blue-600 ≈`#2563eb` | blue-400 ≈`#60a5fa` | pane focus flash / attention rim |
| `--tab-group-split-divider` / strong | `#868690` / `#71717a` | `#71717a` / `#a1a1aa` | split handles between tab groups |
| `--workspace-status-done/review/progress` | `#c7a594` / `#16a34a` / `#d4a300` | same | PR-state group icons |
| git decorations added/modified/deleted/untracked | `#587c0c` / `#895503` / `#ad0707` / `#007100` | `#81b88b` / `#e2c08d` / `#c74e39` / `#73c991` | file explorer/diff |
| `--shadow-floating` | `0 10px 24px rgb(0 0 0 / .18)` | same | popovers, toasts |

Composited values the native port needs (alpha over the surface it sits on) [inferred, arithmetic]:

| Usage | Light | Dark |
|---|---|---|
| dark `--border` over `#171717` (tab strip, status bar) | — | `#272727` |
| dark `--border` over `#2a2a2a` (left sidebar) | — | `#393939` |
| sidebar search field fill `fg/5` | `#e9e9e9` | `#343434` |
| sidebar nav hover `fg/8` | `#e2e2e2` | `#3b3b3b` |
| sidebar nav inactive text `fg/60` | `#686868` | `#a7a7a7` |
| sidebar nav inactive icon `fg/30` | `#aeaeae` | `#686868` |
| workspace card hover (`.worktree-sidebar-card-hover`) | `#ececec` (fg 4 %) | `#282828` (sidebar-accent 40 %; nearly invisible, as shipped) |
| workspace card active (`data-worktree-card-active=primary`) | `#e2e2e2` fill + border fg 40 %·border | `#3f3f3f` fill + border fg 18 % mix |
| active tab fill (`fg 6 % over card`) | `#f0f0f0` | `#252525` |
| sidebar section title `muted-foreground/80` over sidebar | `#8a8a8a` | `#8f8f8f` |

### 1.2 Radii [verified `@theme inline`, main.css]

`--radius` = 10 px. `rounded-sm` 6, `rounded-md` 8, `rounded-lg` 10, `rounded-xl` 14, `rounded-2xl` 18. Tailwind plain `rounded` = 4, `rounded-xs` = 2, `rounded-[4px]`, `rounded-[11px]` used literally [inferred: Tailwind v4 defaults for the unsuffixed ones].

### 1.3 Typography [verified]

- UI font: **Geist** variable (`renderer/src/assets/fonts/Geist-Variable.woff2`, weights 100–900), fallback `-apple-system`. Setting `appFontFamily` default `'Geist'` (`shared/constants.ts`). Body `letter-spacing: 0.01em`, antialiased. `[decide D-FONT]`
- Mono: `'SF Mono', SFMono-Regular, ui-monospace, Menlo…` (`--font-mono`).
- Nerd-font symbols fallback for PUA glyphs: `SymbolsNerdFontMono-Regular.woff2`.
- Sizes in use: 9, 10 (`text-3xs`, line 14), 11 (`text-2xs`, line 16; `text-[11px]`), 12 (`text-xs`, line 16), 13 (`text-[13px]`, the main row size), 14 (`text-sm`, line 20), 18 (`text-lg`), 24 (`text-2xl`), 36 (`text-4xl`), 48 (`.landing-title`). Weights 400, 450 (menu items), 500, 600, 700. `tracking-tight` (−0.025em) on sidebar nav rows [inferred value: Tailwind default].

### 1.4 Icons [verified]

Lucide (`lucide-react ^0.577.0`), default stroke 2; sidebar nav uses stroke 1.75 inactive / 2.25 active; header action icons 14 px stroke 2.25. Shell tab icon is a custom black rounded tile with a white chevron (`tab-bar/shell-icons.tsx` `GenericTerminalIcon`, 24-unit viewBox, rect rx 2.5). `[decide D-ICONS]` (DESIGN.md asks for SF Symbols). The table in §14 gives the closest SF Symbol for each Lucide icon [inferred mapping].

### 1.5 Motion [verified]

Sidebar width 200 ms ease; card fill/border 200 ms; tab-group split divider colour 100 ms; menus open fade + zoom from 0.98 in 150 ms, close fade/zoom-out 95 %; dialogs fade + zoom-in 95 % 200 ms; settings shell enter 180 ms ease-out; terminal pane opacity transition 140 ms; pane focus rim flash 1.5 s; reduced motion disables spinners, menu and rim animations. Theme swaps disable all transitions (`.theme-transition-disabled`).

### 1.6 Controls (shadcn primitives, `renderer/src/components/ui/*`) [verified]

| Control | Geometry and states |
|---|---|
| Button `default` | h 36, px 16, radius 8, 14/500, `bg-primary`, hover 90 %, disabled 50 % opacity, focus ring 3 px `ring/50` |
| Button `ghost` | transparent; hover `accent` (dark: `accent/50`) |
| Button `outline` | 1 px `border`, `bg-background`, shadow-xs, hover `accent` |
| Button `secondary` | `bg-secondary`, hover 80 % |
| Sizes | `xs` h 24 px 8 12 px; `sm` h 32; `lg` h 40; `icon` 36²; `icon-sm` 32²; **`icon-xs` 24², radius 8, svg 12** (all sidebar/header buttons); `chip` h 16 10 px |
| Input | h 36, radius 8, 1 px `input` border, transparent (dark `input/30`), px 12, 14 px (md: 14), placeholder `muted-fg/60`; compact variant h 28 12 px `bg-input/50` |
| Switch | 36×20 pill, checked `bg-foreground` (black/white, **no accent colour**), unchecked `muted-fg/30`, thumb 14 px `bg-background` |
| Checkbox | 16², radius 4, checked `bg-primary` |
| Tabs (segmented) | list `bg-muted` radius 10 p 3; active trigger `bg-background` |
| Tooltip | `bg-foreground` / `text-background` (inverted), radius 8, px 12 py 6, 12 px, arrow 10 px; sidebar delay 400 ms |
| Kbd (`ShortcutKeyCombo`) | min-w 24, radius 4, 1 px `border/80`, `bg-secondary/70`, px 6 py 2, 12/500 muted, shadow-sm |

Focus: global `outline-ring/50`; buttons show a 3 px `ring/50` ring on `:focus-visible`; there is **no blue accent anywhere in the chrome** (`baseColor: neutral`) [verified]. `[decide D-ACCENT]`

---

## 2. Window chrome

| Item | Value | Source |
|---|---|---|
| Style | `titleBarStyle: 'hiddenInset'`: native traffic lights over web content, no system title/toolbar | `main/window/createMainWindow.ts` [verified] |
| Traffic lights | x = 16, vertical centre 18 (radius 6 ⇒ y = 12) | `main/window/main-window-visual-lifecycle.ts` `TRAFFIC_LIGHT_X`, `TITLEBAR_CSS_CENTER`, `TRAFFIC_LIGHT_RADIUS` [verified] |
| Window background | `#0a0a0a` dark / `#ffffff` light | createMainWindow [verified] |
| Minimum size | 600 × 400 | `MIN_WIDTH`, `MIN_HEIGHT` [verified] |
| First-launch size | the whole primary-display work area (not maximised); later the saved bounds | createMainWindow [verified] |
| Vibrancy / blur | none on macOS (`windowBackgroundBlur` only acts on Windows acrylic) | createMainWindow comment #8482 [verified] |
| Drag regions | titlebar, sidebar header, tab-strip rows and right-sidebar header are window-drag areas; controls inside are no-drag | main.css `.titlebar*`, `TabGroupPanel.tsx` [verified] |
| Click-through | `acceptFirstMouse: true` (first click into an inactive window acts) | createMainWindow [verified] |

Native mapping [inferred]: `NSWindow` with `.fullSizeContentView`, `titlebarAppearsTransparent = true`, `titleVisibility = .hidden`, no `NSToolbar`; reposition the standard buttons to x 16 / centre 18 (via `standardWindowButton(_:)` frames in `NSWindowDelegate`/layout); `isMovableByWindowBackground` only on the chrome bands; `acceptsFirstMouse` overrides on the chrome views. `[decide D-CHROME]`

## 3. Title band (top 36 pt)

There are two layouts [verified `app-shell/AppWorkspaceShell.tsx`]:

1. **Workspace view** (a workspace open): no full-width titlebar. The left column gets a 36 pt `.titlebar-left` header sitting on top of the sidebar, same surface (`--worktree-sidebar`), 1 px bottom seam drawn as `inset 0 -1px 0 var(--border)` so content stays 36 pt high. The centre column starts with a 4 pt drag strip + the 32 pt tab strip (36 pt baseline, comment in main.css `.titlebar-left`). The right sidebar starts with its own 36 pt header.
2. **Page views** (landing, tasks, settings, skills…): a full-width `.titlebar` 36 pt, `bg-card`, 1 px bottom `border`, containing the left cluster then the main strip.

Left cluster, left to right (`app-shell/TitlebarLeftControls.tsx`) [verified]:

| Element | Geometry | Style |
|---|---|---|
| Traffic-light pad | 80 pt wide | — |
| App name "Orca" | h 24, px 6, ml 2, mr 4, radius 4, max-w min(280, 32vw) | 12 pt / 600, `muted-foreground` (inside the sidebar header: `worktree-sidebar-foreground`); right-click menu "Hide App Name"; setting `showTitlebarAppName` default true |
| Sidebar toggle | `.sidebar-toggle` padding 4×8, radius 4, icon **PanelLeft 16** | `muted-foreground`; hover `bg-accent` + `foreground`, 150 ms; tooltip "Toggle sidebar (<shortcut>)" below, offset 6 |
| Back / Forward | `ml-auto mr-3 pl-2`, each `.sidebar-toggle-compact` padding 4×5, icons **ArrowLeft 12 / ArrowRight 12** | `foreground`; disabled `muted-foreground` + 45 % opacity; tooltips "Go back (…)", "Go forward (…)"; hidden in Settings |

Main strip (`app-shell/TitlebarMainStrip.tsx`) [verified]: the tab-strip portal slot (`#titlebar-tabs`, flex 1) used on page views, an optional "Collapse pane" button (**Minimize2 14**, `.titlebar-icon-button` padding 4, mr 8, radius 4) when a pane is expanded, and the right-sidebar toggle (**PanelRight 16**, `.sidebar-toggle mr-2`) only while the right sidebar is closed. When the right sidebar is closed in workspace view, the toggle floats absolutely at the top-right of the centre column, in a 36 pt high box, so its centre matches the open state.

## 4. Left sidebar

Container (`components/sidebar/index.tsx`) [verified]: `bg-worktree-sidebar`, flex column, width default **280** (`shared/constants.ts` `sidebarWidth: 280`), min **220**, max **500**, persisted; transition 200 ms. Resize handle: 12 pt hit area straddling the right edge (`-right-1.5 w-3`), a 1 pt line transparent → `ring/50` on hover → `ring` while dragging. The sidebar has no explicit right border in workspace view: the seam is the centre column's `border-l` [inferred from comments in AppWorkspaceShell]. Scrollbar: overlay, hidden until the sidebar is hovered, thumb `muted-fg 28 %` (hover 48 %), 8 pt wide, no right inset (`.worktree-sidebar-scrollbar`). Toggle collapses to width 0; the 36 pt header then floats over the tab strip with `bg-card` and a right border (`.titlebar-left-floating`).

Top-to-bottom order [verified]:

### 4.1 Navigation block (`SidebarNav.tsx`)
`px-2 pt-2 pb-1`, rows spaced 2 pt. Each row: full width, radius 8, `px-2 py-1.5`, gap 8, 13 pt / 500, `tracking-tight`, icon 16 pt. Row height ≈ 32 pt [inferred: 6 + ~20 line + 6].

| Row | Icon | Default visible | Notes |
|---|---|---|---|
| Search | Search (stroke 1.75, `fg/30`) | always | fill `fg/5`, hover `fg/8`, text `fg/60`; on hover/focus shows the worktree-palette shortcut as keycaps (9 pt, `bg fg/8`, `border/80`) at the right; opens the jump palette (⌘J) |
| Setup guide | — | while onboarding incomplete | `SetupGuideSidebarEntry.tsx` |
| Tasks | List | yes (`showTasksButton: true`) | on hover shows provider shortcuts (Github / Gitlab / Linear / Jira 14 pt) at the right |
| Artifacts | Files | no (`showArtifactsButton: false`) | |
| Skills | BookOpen | no (`showSkillsButton: false`) | |
| Automations | CalendarClock | yes | |
| Agent dashboard | — | experimental only | |
| Orca Mobile | Smartphone | yes | "New" pill (primary, 10 pt/600) until dismissed; EyeOff hide button |

States: inactive text `fg/60`, icon `fg/30` stroke 1.75; hover `bg fg/8`; **active** (`aria-current=page`) `bg-worktree-sidebar-accent`, text accent-fg, icon full colour stroke 2.25. Every row's context menu: "Hide from sidebar" (EyeOff 14).

### 4.2 Section header (`SidebarHeader.tsx`, `sidebar-header-actions.tsx`)
`mt-2 h-8 px-2`. Title "**Projects**" (default `groupBy: 'repo'`; "Workspaces" otherwise), 12 pt / 600, `muted-foreground/80`, `pl-2`. Right cluster, gap 4, all `ghost icon-xs` 24² buttons, 14 pt icons stroke 2.25, `muted-foreground`, tooltips below:
1. **Bell** — toggle the Agents/activity body (pressed: `bg-primary/15 text-primary`);
2. **SlidersHorizontal** — workspace options menu (filters, sort, group-by);
3. **FolderPlus** — "Add project";
4. **Plus** — "New workspace" (tooltip shows ⌘N).

### 4.3 Workspace list (`WorktreeList.tsx`, `worktree-list/*`)
Virtualised. Rows:

- **Project (repo) header** (`rows/SectionHeader.tsx`): height **28** (`GROUP_HEADER_ROW_HEIGHT`), `pt-1` when spaced, left padding 10 (`PROJECT_GROUP_HEADER_BASE_PADDING`) + 18 per nesting level (`SIDEBAR_TREE_INDENT`). Repo icon box 16² (glyph 14, repo badge colour), label 13 pt / 600, line 16, truncating; optional host label, fork indicator, path-status. Right: collapse affordance 20² radius 8, ChevronDown 14 rotated −90° when collapsed, hover `accent/70`; project actions. Header is sticky while scrolling (`bg-worktree-sidebar`). Draggable to reorder (grab cursor on icon+title).
- **Host header** (remote hosts): 36 tall.
- **Workspace card** (`worktree-card-surface.tsx`, `worktree-card-header.tsx`, `worktree-card-meta-row.tsx`): margin-left 4, `pr-1.5`, radius 10, 1 pt transparent border, padding `pt-1.25 pb-1.5` (title-only cards `py-2`). Title row: optional repo chip, host glyph (Server 12 / ServerOff 12 destructive), title 13 pt leading 20, **semibold when unread**, else regular; badges 16 high 10 pt; right side Star (12, amber-400 filled) for pinned and a hover-revealed Trash2 (14) delete button (hover `destructive/10`). Meta row: 11 pt `muted-foreground`, branch in mono 11 pt, PR/merge chips (GitMerge 10, amber). Status lane dot at the left: 8 pt circle, emerald-500 when an agent is live, `neutral-500/40` otherwise; spinner / Activity (yellow) / question (orange) / red dot variants (`StatusIndicator.tsx`, `AgentStateDot.tsx`).
  - Hover: `.worktree-sidebar-card-hover` (see §1.1 composite).
  - Active (open workspace): fill fg 8 % (dark 10 %), border fg 40 %-mixed, shadow `0 1px 2px fg 4 %`.
  - Multi-selected (not active): ring-coloured border 35 %, accent 70 % fill, 1 pt ring 30 %.
  - Sleeping: text tokens dimmed in OKLab (fg 52 %, muted 34 %).
  - Deleting: 50 % opacity + grayscale with a centred pill "Deleting…" (LoaderCircle spin); disconnected runtime 60 % opacity.
  - Double-click title = inline rename. Drag = reorder / nest / drop on a status lane.
- Agent sub-rows under a card (compact agents list), lineage children rows (indent 18).

### 4.4 Bottom toolbar (`SidebarToolbar.tsx`)
`border-t border-worktree-sidebar-border px-2 py-1.5`, 36 pt tall [inferred: 24 + 12]. Left: **Settings** (gear, `ghost icon-xs`, tooltip above with its shortcut) + help menu (CircleHelp…). Right: **Crosshair** "Scroll to current workspace", **Kanban** "Workspace board" (`secondary` variant when the board is open).

## 5. Centre column: tab groups and tab strip

### 5.1 Tab group panel (`tab-group/TabGroupPanel.tsx`) [verified]
- Strip row: **32 pt** high, `bg-card`, 1 pt bottom `border`, `pr-1.5`, window-drag region. Content: optional spacer equal to the collapsed sidebar header width; the tab bar (flex 1); an action cluster (`ml-1.5`, gap 2) with the **Command** quick-commands button (Play 14 + "Command" 12/500, h 28 px 6 radius 8, label hidden under 480 pt strip width) and, only with split groups, the **Pane Actions** button (Ellipsis 16 in 28², menu item "Close split pane" X destructive). Unfocused group: action cluster 50 % opacity until hover.
- Body: fills the rest; editor/terminal/browser surfaces.
- With split groups: groups get `border-l/r/b` except at edges; the focused group's bottom border becomes `accent`; **unfocused groups render at opacity 0.95** (`split-group-dim.ts`).
- Split resize handle between groups: 6 pt hit area, 3 pt visible line, radius 1, colour `--tab-group-split-divider`, hover/drag `-strong`, 100 ms (`.tab-group-split-resize-handle`).

### 5.2 Tabs (`tab-bar/SortableTab.tsx`, `drop-indicator.ts`, `tab-width-rules.ts`) [verified]
| Property | Value |
|---|---|
| Width | 180 pt, min 72; 220 pt when the window is ≥ 1280 pt wide |
| Height | full strip (32) |
| Padding / text | `px-1.5` (6), 12 pt, single-line truncate |
| Borders | 1 pt `border-r` when tabs follow, `border-t` by default (`includeTopTabBorder = true`); a tab docked at the end gets a 1 pt left seam |
| Inactive | `bg-card`, `muted-foreground`, hover `foreground` |
| Active | `bg = fg 6 % over card`, `foreground`, **2 pt bottom bar in `foreground`** (full width) |
| Unread activity | `amber-500/10` wash over the whole tab |
| Leading icon | 12 pt: shell tile (§1.4) or agent icon, 70 % opacity when inactive; state dot (8) / filled bell (12 amber) for attention; Pin 12 when pinned |
| Close | 16² radius 6 button with X 12, right side; invisible until tab hover (active tab: always `muted-foreground`), hover `bg-muted` + `foreground`; middle-click closes (not pinned) |
| Expand indicator | Minimize2 12 in a 16² button when the pane is expanded |
| Rename | double-click opens an inline input h 20, 12 pt |
| Drag | reorder; drop indicator 2 pt `blue-500` line left/right; drag to the body edge splits |
| Overflow | horizontal scroll without scrollbar; ChevronLeft/Right 14 buttons (h 24 w 20) appear at the ends; 1.5 rem mask fades at clipped ends; hidden under 260 pt |
| New tab | **Plus 14** in a 28² radius-8 button, `ml-2`, `muted-foreground`, hover `accent/50`; opens a create menu (w 288, radius 11) with shells, agents, browser, file search |
| Hover card | `TabHoverCard.tsx` (details on hover) [verified file, contents not reviewed] |
| Context menu | rename, split, move to pane, pin, copy id, close/close others (`SortableTabContextMenu.tsx`) [verified files, items not enumerated] |

## 6. Terminal area

[verified `shared/default-global-settings.ts`, `shared/terminal-themes/defaults.ts`, `renderer/src/assets/terminal.css`]

| Property | Default |
|---|---|
| Font | SF Mono (macOS), **14 pt**, weight **500**, bold 700, line height 1.0, ligatures auto |
| Cursor | block, blinking |
| Padding | 4 pt top/left (`--pane-padding-x/y`, default 4 px) |
| Dark theme "Ghostty Default Style Dark" | bg `#282c34`, fg `#ffffff`, cursor `#ffffff`, selection `#5a7898`/`#ffffff`; ANSI 0–7 `#1d1f21 #cc6666 #b5bd68 #f0c674 #81a2be #b294bb #8abeb7 #c5c8c6`; 8–15 `#666666 #d54e53 #b9ca4a #e7c547 #7aa6da #c397d8 #70c0b1 #eaeaea` |
| Light theme "Builtin Tango Light" (separate light theme on) | bg `#ffffff`, fg `#2e3434`, selection `#accef7`; ANSI 0–7 `#2e3436 #cc0000 #4e9a06 #8e7700 #3465a4 #75507b #05727e #6a6a6a`; 8–15 `#555753 #ef2929 #1b7a1b #6d5a00 #204a87 #ad7fa8 #034b50 #3d3d3d` |
| Split divider inside a tab | 3 pt line (`terminalDividerThicknessPx: 3`) colour `#3f3f46` dark / `#d4d4d8` light, hit area wider, lines extend 5 pt into crossings |
| Inactive pane | opacity **0.9**, active 1.0, transition 140 ms |
| Pane title bar (optional, when a pane has a title) | 24 pt, mono 13 pt, padding 0×8, fg `rgb(255 255 255/.52)` on dark terminals (`rgb(24 24 27/.64)` on light), 1 pt separator `.06`/`.10` alpha, a drag handle (32 wide) appears on hover centre, close button fades in |
| Attention / locate | 1.5 pt inset rim in `--terminal-pane-locate` 64 %; focus flash 1.5 s |
| Scrollbar | overlay, 14 pt track, thumb `rgba(121,121,121,.4)` (hover .7), radius 7, inset 3 |
| Drop overlay | `rgba(59,130,246,.2)` fill, 2 pt `rgba(59,130,246,.5)` border, radius 4 |

## 7. Right sidebar

[verified `components/right-sidebar/*`, `shared/constants.ts`]
- Surface `bg-sidebar` (`#fafafa` / `#171717`), width default **350**, min 220 (keeps ≥ 320 for the centre), open by default (`rightSidebarOpenByDefault: true`), left resize strip 4 pt (`hover ring/20`, active `ring/30`).
- Header 36 pt, 1 pt bottom border, window-drag. Activity bar "top" layout: icon buttons 36 × 36, icon 16, inactive `muted-foreground/60` (hover `muted-foreground`), active `foreground` with a 2 pt bar at the bottom spanning the middle 50 % (radius top); status dot 7 pt at top-right. Overflow "More sidebar tabs" (MoreHorizontal 16) dropdown. Side layout alternative: a 40 pt vertical strip on the right, 40² buttons, icon 18, active bar 2 pt on the right edge.
- Tabs and icons: Explorer (Files), Agents (custom history icon), Workspaces (Workflow), PR Checks / Checks (ListChecks), Source Control (GitBranch), Ports (Plug).
- Panel title when used: 11 pt / 600 uppercase `tracking-wider`.
- File explorer rows: radius 6, `px-2 py-1`, 12 pt, indent 16 per level + 8, Folder/FolderOpen 12 icons; hover `accent`; selected = fg 8 % mixed into accent + 1 pt inset `border` ring (dark: accent 70 %).

## 8. Status bar

[verified `components/status-bar/StatusBarSurface.tsx`; `statusBarVisible: true`]
24 pt high, `px-3`, gap 16, `bg-card` (`--bg-titlebar` fallback), 1 pt top border, 12 pt. Left cluster: provider usage (Claude/Codex usage segments, `px-1 py-0.5` rounded hover `accent/70`, refresh button). Right cluster, gap 12: caffeinate, remote-server update, skill update, chat-resume, app update, pet, **resource usage** (MemoryStick 12 + memory, "·", Terminal 12 + PTY count 11 pt tabular), **ports**, **SSH**, floating-terminal toggle (PanelsTopLeft 14 in a 20² bordered `secondary` chip). Overflowing segments scroll; the usage cluster fades at its end. Segments collapse to icon-only at narrow widths (`status-bar-density.ts`).

## 9. Landing / empty states

`components/Landing.tsx` [verified]: full-bleed `bg-background`, centred column max-w 512, gap 16, py 32:
- Logo tile 80², radius 18, 1 pt `border/80`, `shadow-lg shadow-black/40`, fill `#12181e`, logo 48².
- Title "ORCA" 36 pt / 700, `tracking-tight`.
- Preflight issues card (max-w 384, radius 10, `bg-muted/40`, AlertTriangle amber).
- Copy 14 pt muted: "Add a project to get started." / "Select a workspace from the sidebar to begin."
- Two buttons, gap 10: **FolderPlus** "Add project", **GitBranchPlus** "Create worktree|workspace"; each `bg-secondary/70`, 1 pt `border/80`, 14/500, px 16 py 8, radius 8, hover `accent`.
- Shortcut list (max-w 320, mt 24): "Create workspace", "Move up workspace", "Move down workspace" with keycaps.
- Footer GitHub star button at the bottom (24 pt from the edge).
Other empty states: tab group without content shows "Loading editor…" 14 pt muted centred; sidebar drop affordance card (FolderPlus 20, radius 8, `worktree-sidebar-accent/95`).

## 10. Dialogs, popovers, menus, toasts

[verified `components/ui/dialog.tsx`, `dropdown-menu.tsx`, `context-menu.tsx`, `popover.tsx`, `select.tsx`, `main.css` sonner rules]
- **Dialog**: overlay `black/55` + 2 pt backdrop blur; panel centred, max-w 512 (compact 384), radius 10, padding 24, gap 16, 1 pt border `black/14` (`white/14` dark), fill `background/96` (dark `rgba(23,23,23,.96)`), backdrop blur 40, shadow `0 20px 60px rgba(0,0,0,.28)` + inner 1 px highlight; title 18 / 600 (compact 14, display 24–28), description 14 muted; footer right-aligned, buttons gap 8; close X (14) top-right 16/16 at 70 % opacity. Open fade + zoom 95 %, 200 ms. `[decide D-DIALOG]`
- **Dropdown / context menu**: min-w 176, radius **11**, padding 4, 1 pt `black/14` border (`white/14`), fill `rgba(255,255,255,.82)` / `rgba(0,0,0,.72)` with backdrop blur 40, shadow `0 12px 28px rgba(0,0,0,.22)` (dark `.40`) + 1 px inner highlight. Items: radius 8, px 8 py 4, **12 pt / 450, line 17**, gap 8, icons 14 `muted-foreground`; highlight `black/8` (dark `white/14`); destructive items red; labels 11 / 600 muted; separators 1 pt `border/60` with 3 pt margins; shortcut text 11 pt muted/85 right-aligned. This translucent style is already close to a native macOS menu.
- **Popover / Select**: radius 8, same translucent fill and blur.
- **Toasts** (sonner): padding 14×16, gap 10, `shadow-floating`, description at 80 % opacity, close button with `popover` fill. Bottom-right [inferred: sonner default; position not checked].
- **Jump palette (⌘J)**: selected row = fg 13 % over background with 1 pt inset fg 19 % ring (dark: `accent` + 16 % ring).

## 11. Settings page

[verified `components/settings/SettingsSidebar.tsx`, `settings-page-renderer.tsx`, `SettingsSection.tsx`, `hooks/settings-navigation-*-sections.ts`]
- Replaces the workspace area (full-width titlebar + page). Enter animation 180 ms.
- Left settings sidebar: **280** wide, `bg-worktree-sidebar`, right border. Top block (px 12 py 12, bottom border): ghost button "**Back to app**" (ArrowLeft 16, 13 pt muted). Search block: input with Search 16 icon at left (pl 36), 13 pt, `bg-background/60`, shortcut keycaps right.
- Groups in order: AI Capabilities, Set Up, Workflows, Interface, Remote Hosts, Privacy & Security, Advanced, Experimental; plus Projects (one entry per project). Group label 11 pt / 500 uppercase, tracking 0.18em, muted, px 12; groups spaced 20, items 4.
- Nav item: radius 10, px 12 py 6, 13 pt, gap 8, icon 16; inactive `fg/60`, hover `accent/60`; active `worktree-sidebar-accent`, 500 weight, 1 pt ring `ring/25`; optional pills (update available amber, "SSH" with Server 12).
- Sections and icons (selection; names for UserCog, Server and ShieldCheck/Lock rows were not read and are [inferred]): Agents (Bot), Accounts (UserCog), Orchestration (Network), Linear, Computer Use (MousePointerClick), Voice (Mic), Orca Account (CircleUserRound), General (SlidersHorizontal), Integrations (Blocks), Mobile (Smartphone), Appearance (Palette), Chat (MessageSquare), Input & Editing (TextCursorInput), Notifications (Bell), Shortcuts (Keyboard), Stats & Usage (BarChart3), Automations (CalendarClock), Artifacts (Files), Share Skills (BookOpen), Agent Session Search (History), Git (GitBranch), Task Sources (ListChecks), Terminal (SquareTerminal), Quick Commands (Play), Browser (Globe), Emulators (TabletSmartphone), Floating Workspace (PanelsTopLeft), SSH Hosts (Cable), Servers (Server), security (ShieldCheck, Lock), Advanced (Wrench), Dev Tools (Bug), Experimental (FlaskConical), Plugins (Blocks).
- Content: scroll area, column max-w 896 (setup guide 1152), px 32, pt 40, pb 96, sections gap 40. Section header: title 24 pt / 600, optional pill (10 pt uppercase), description 14 pt line 24 muted, bottom border `border/60`, pb 20; body below with gap 24.

## 12. Behaviour summary

- Sidebar toggle and right sidebar toggle (chords from the keybinding table, not re-checked here), back/forward through workspace history, worktree palette from the Search row, ⌘N (and ⌘⇧N) new workspace [verified comment in `sidebar-header-actions.tsx`], the jump palette (`components/cmd-j`, ⌘J per its folder name [inferred]), Ctrl-Tab MRU (`ctrlTabOrderMode: 'mru'`) [verified settings; exact default key chords live in the keybinding table, not re-listed here].
- Hover-reveal controls (delete on cards, close on tabs, task-provider shortcuts) are always visible on touch (`can-hover`) [verified].
- Terminal focus: clicks on the top chrome release terminal focus first (`data-regular-terminal-input-focused`) [verified]. Focus follows mouse off by default.
- Theme: `theme: 'system'` follows macOS; dark/light swap without transitions [verified].

## 13. Where glass is allowed and where Orca's flat style must stay

Product rule (AGENTS.md / DESIGN.md): Liquid Glass for navigation and controls only; terminal cells, code, diffs, chat and data stay on stable surfaces.

| Surface | Orca | Recommendation |
|---|---|---|
| Terminal, editor, diff, chat bodies | opaque | **flat, always** (both rules agree) |
| Tab strip, status bar, pane title bars | opaque `card` | **flat** (also M3 decision D10) |
| Left sidebar and 36 pt header | opaque `#f5f5f5` / `#2a2a2a` | flat for 1:1; glass only if the user picks the native sidebar `[decide D-SIDEBAR]` |
| Window toolbar | none | 1:1 = no toolbar; a glass toolbar is a deviation `[decide D-CHROME]` |
| Menus, context menus, popovers, select | already translucent + blur, radius 11 | **native `NSMenu`/popover (glass on macOS 26)** is the closest match; no conflict |
| Dialogs | centred translucent panel over a dimmed window | native sheet vs custom centred panel `[decide D-DIALOG]` |
| Tooltips | inverted dark pill | custom view for 1:1 or native `help` `[decide D-TOOLTIP]` |
| Buttons, switches | neutral black/white | native controls tinted neutral, or custom drawn `[decide D-ACCENT]` |

## 14. Lucide → SF Symbol table [inferred mapping]

| Lucide | SF Symbol | Lucide | SF Symbol |
|---|---|---|---|
| PanelLeft | `sidebar.left` | PanelRight | `sidebar.right` |
| ArrowLeft / ArrowRight | `arrow.left` / `arrow.right` | Minimize2 | `arrow.down.right.and.arrow.up.left` |
| Search | `magnifyingglass` | List | `list.bullet` |
| CalendarClock | `calendar.badge.clock` | Smartphone | `iphone` |
| Files | `doc.on.doc` | BookOpen | `book` |
| EyeOff | `eye.slash` | Bell | `bell` |
| SlidersHorizontal | `slider.horizontal.3` | FolderPlus | `folder.badge.plus` |
| Plus | `plus` | Settings | `gearshape` |
| Crosshair | `scope` | Kanban | `rectangle.split.3x1` |
| ChevronDown/Left/Right | `chevron.down/left/right` | FolderTree | `folder` (no tree variant) |
| Pin | `pin` | X | `xmark` |
| Ellipsis / MoreHorizontal | `ellipsis` | Play | `play` |
| Star | `star.fill` | Trash2 | `trash` |
| Server / ServerOff | `server.rack` / no equivalent (use `server.rack` + red tint) | GitBranch | `arrow.triangle.branch` |
| GitBranchPlus | no equivalent (compose `arrow.triangle.branch` + `plus` badge) | GitMerge | `arrow.triangle.merge` |
| Workflow | `point.3.connected.trianglepath.dotted` | ListChecks | `checklist` |
| Plug | `powerplug` | MemoryStick | `memorychip` |
| Terminal / SquareTerminal | `terminal` / `apple.terminal` | PanelsTopLeft | `uiwindow.split.2x1` |
| Folder / FolderOpen | `folder` / `folder` (open: no exact) | Activity | `waveform.path.ecg` |
| CircleCheck | `checkmark.circle` | CircleDashed | `circle.dashed` |
| Loader2 / LoaderCircle | `ProgressView` (spinner) | AlertTriangle | `exclamationmark.triangle` |
| Palette | `paintpalette` | Keyboard | `keyboard` |
| Mic | `mic` | Globe | `globe` |
| Lock | `lock` | ShieldCheck | `checkmark.shield` |
| Wrench | `wrench.and.screwdriver` | Bug | `ant` |
| FlaskConical | `flask` | History | `clock.arrow.circlepath` |
| BarChart3 | `chart.bar` | MessageSquare | `message` |
| Network | `network` | MousePointerClick | `cursorarrow.click` |
| Bot | no exact (`cpu` / custom) | Github, Gitlab, Linear, Jira | brand marks, no SF Symbol (bundle assets) |

## 15. Decisions for the user (1:1 vs native/Liquid Glass)

| ID | Conflict | Options |
|---|---|---|
| D-CHROME | Orca has no toolbar: traffic lights at (16, 18) over a 36 pt custom band whose left part is the sidebar header and whose centre is the tab strip. smthz uses a system SwiftUI toolbar (glass on macOS 26) with title + status + New Shell. | (a) 1:1 custom chrome, hidden titlebar, no `NSToolbar`, no glass in the title band; (b) keep a native glass toolbar (visible deviation). Recommendation: (a). |
| D-SIDEBAR | macOS 26 `NavigationSplitView` sidebars float as inset glass panels with system row styling; Orca's sidebar is a flat opaque `#f5f5f5`/`#2a2a2a` column with custom rows. Conflicts with "glass for navigation". | (a) custom flat sidebar (HStack/NSSplitView), 1:1; (b) native sidebar with Orca's content (not 1:1). Recommendation: (a), keep glass only in menus/popovers. |
| D-FONT | Orca uses Geist (OFL, bundled); DESIGN.md says SF system text. | (a) bundle Geist (license allows), 1:1; (b) SF Pro at the same sizes (close but visibly different). |
| D-ICONS | Orca uses Lucide (ISC licence) at 12–16 pt with specific strokes; DESIGN.md says SF Symbols. | (a) bundle the ~60 Lucide SVGs used (exact); (b) SF Symbols from §14 (close, several have no equivalent). |
| D-ACCENT | Orca chrome is neutral (switch "on" is black/white, focus ring grey). macOS controls use the system accent (blue). | (a) force neutral tint on all controls; (b) keep the system accent. |
| D-DIALOG | Orca dialogs are centred over a dimmed, blurred window; macOS prefers window-attached sheets. | (a) custom centred panel, 1:1; (b) native sheets. |
| D-TOOLTIP | Orca tooltips are inverted dark pills with arrow, 400 ms delay; native tooltips are system yellow/grey after ~1 s. | (a) custom tooltip view; (b) `.help()`. |
| D-NAV | Orca's sidebar (Search, Tasks, Automations, Orca Mobile, Projects list) differs from DESIGN.md (Needs You, Workspaces, Tasks, Automations, Activity, Library). | (a) adopt Orca's structure and update DESIGN.md; (b) keep DESIGN.md destinations in Orca's visual style. |
| D-WINDOW | Orca: min 600×400, first launch fills the work area. smthz: min 800×600 (DESIGN.md), default 1100×760. | (a) Orca values; (b) keep DESIGN.md. |
| D-STATUS | Orca puts host/resource/ports/SSH state in a 24 pt bottom status bar; DESIGN.md says critical state must also be near the top. | (a) 1:1 status bar only; (b) status bar plus a top indicator (e.g. in the sidebar header). |
| D-ZOOM | Orca zooms the whole UI; native has no direct equivalent (already M3 D7). | as decided in M3-PLAN D7. |

## 16. Decisions taken (2026-10-24, user mandate "UI 1:1 with Orca")

The user asked for a 1:1 match, so every `[decide]` item takes option (a): D-CHROME (a), D-SIDEBAR (a), D-FONT (a) bundle Geist, D-ICONS (a) bundle the Lucide SVGs used, D-ACCENT (a) neutral tint, D-DIALOG (a), D-TOOLTIP (a), D-NAV (a) adopt Orca's structure (DESIGN.md superseded for the sidebar), D-WINDOW (a), D-STATUS (a), D-ZOOM per M3 D7. Fonts/icons are copied by `scripts/package-app.sh` into the app bundle `Contents/Resources` (no `Package.swift` change) and loaded at runtime with fallback to SF Pro / SF Symbols if missing.

Shared contract so parallel workers compile against the same names (owned by UI-0, `Sources/SmthzApp/Theme/OrcaTheme.swift`):
`enum OrcaTheme` with static dynamic `Color`s: `background, foreground, card, popover, primary, primaryForeground, secondary, secondaryForeground, muted, mutedForeground, accent, accentForeground, border, input, ring, destructive, worktreeSidebar, worktreeSidebarForeground, worktreeSidebarAccent, worktreeSidebarBorder, sidebar, sidebarAccent, statusSuccess, statusWarning`; `enum OrcaMetrics` with `titleBandHeight=36, tabStripHeight=32, statusBarHeight=24, leftSidebarWidth=280, leftSidebarMin=220, leftSidebarMax=500, rightSidebarWidth=350, tabWidth=180, tabWidthWide=220`; `enum OrcaFont` (`ui(size:weight:)`, falls back to system); `OrcaIcon` (`Image` factory by name, Lucide with SF Symbol fallback).

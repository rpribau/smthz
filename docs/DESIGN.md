# smthz native design specification

Research/design completed using the local apple-design skill and actual reference source. This is an implementation specification, not a verified UI/accessibility rating. The source icon remains unchanged at `icon/icon.png`.

## Main window

Use a system window toolbar above three resizable regions: workspace navigator, workbench and contextual tools. Default one agent/content pane; nested splits are explicit user actions. Toolbar always identifies workspace, branch, execution host, pending attention and search. A `Needs You` destination gathers questions, approvals, errors and completed work requiring acknowledgement.

Navigator destinations: Needs You, Workspaces, Tasks, Automations, Activity, Library, then projects/workspaces. Keep navigation at two levels; express nested worktrees through breadcrumbs and the workspace overview. Library exposes Skills and Artifacts. Contextual tools include Files, Changes, Agents, Checks and Ports according to folder/Git/host capabilities.

Use SwiftUI navigation, standard menus/forms/sheets and AppKit for persistent nested pane splits, accessible pane tab strips and specialized views. Make toolbar commands available in menus. Preserve standard macOS keyboard commands, raw terminal input, visible focus and remappable shortcut conflict feedback.

## Materials and identity

Silver/graphite identity inspired by the supplied icon. Use semantic system colors, accent/selection, SF system text and SF Symbols; do not imitate a web design system. Use system Liquid Glass for navigation and controls; keep terminal cells, code/diffs, chat messages and data content on stable surfaces. Avoid repeated blurred layers and decorative animation. Honor Reduce Transparency, Reduce Motion, increased contrast and system appearance.

Starting layout values are design choices: navigator about 240 pt, tools about 320 pt on a 1440x900 window. At about 1100 pt hide tools before navigation. At minimum 800x600 show a focused pane while retaining the full split tree; View menu/toolbar restores hidden regions. Resizing or hiding a view never closes its process. Remember user widths/layout per workspace. Critical state/actions must remain near the top, not only in a bottom bar.

System body/control text starts at 13 pt, secondary 12 pt, headings 17/22 pt; terminal/editor start at user-adjustable 13–14 pt and chat at 14 pt. Support content enlargement to 200%, growing rows and stacking metadata. macOS text enlargement is not iOS Dynamic Type. Test text contrast at 4.5:1 and essential nontext/focus at 3:1, including actual composited materials. Native targets default around 28 pt and never below 20 pt. Status must include text/symbols, not color alone.

## Screen coverage

Welcome/setup; workspace create/manage/cleanup; tabs/splits/detached windows; terminal/chat/questions/history/accounts; files/search/editor; source control/diff/reviews; hosted tasks/boards; browser/profiles/design selection; automation/run history; activity/dashboard; skills/plugins; artifact sharing; hosts/environments/ports; resources/diagnostics; settings; reconnect/empty/error/update states; computer-use and emulator permissions; optional pet. Implement real workflows before claiming these surfaces complete.

## Accessibility and resource checks

Every icon/action has a label; all drag/split/board gestures have keyboard/menu alternatives. VoiceOver can navigate terminal text, conversation history, questions and diff hunk actions. Preserve focus across reconnect and pane changes; announce concise status changes instead of every streaming token. Virtualize long lists/transcripts, bound caches and pause drawing of inactive views without stopping work. Load browser, plugin and speech resources on demand.

## Browser constraint

Use public WKWebView APIs with a Swift-owned typed browser service. Target references carry page/frame/navigation generation; cancellation and unsupported capabilities are explicit. Prove trusted input, cross-origin/shadow content, design extraction, profile persistence, captures, network routing and macOS/Linux unattended execution. Synthetic DOM events, a screenshot or a successful navigation do not establish CDP-equivalent behavior. Document native equivalents and ask before accepting functionality reductions.

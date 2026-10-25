# UI-CHECKS — how the coordinator verifies the UI (written 2026-10-24)

Baseline after UI wave 2: build OK, 211 tests x3, `Package.swift` unchanged. Screenshot (dark, host up, one shell) matches the Orca layout: 36 pt band with traffic lights, flat sidebar (Search, Tasks, Automations, Orca Mobile, Projects header + 4 icons, project row, workspace card, bottom toolbar), tab strip (Shell 1 tab with close, +, Command), right sidebar with activity bar and empty state, 24 pt status bar, terminal with the Ghostty-dark palette and a block cursor.

## Per-change routine
1. Scope diff against the pre-launch snapshot (`diff -rq Sources.<snap> Sources`), `Package.swift` diff, no `.build-*` left.
2. `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --scratch-path /tmp/smthz-verify`, then `swift test` x3; compare the count (211).
3. `SMTHZ_SCRATCH_PATH=/tmp/smthz-verify ./scripts/package-app.sh`; start `/tmp/smthz-verify/debug/smthzd`, create a session with `smthz run -- /bin/zsh -f`, `open build/smthz.app`, `screencapture -x`, read the image. Afterwards `pkill -f 'smthz.app/Contents/MacOS/smthz$'; pkill -TERM -x smthzd` and confirm no strays.
4. Never use System Events `keystroke` unless the app is verified frontmost.

## Visual checklist (compare with docs/UI-SPEC.md)
- [ ] Dark and light mode (toggle System Settings > Appearance; Orca follows the system): colours §1.1.
- [ ] Heights: title band 36, tab strip 32, status bar 24; sidebar 280 (220-500 resize), right sidebar 350, tab 180/220; traffic-light centre y=18 (measure on the retina screenshot, divide by scale).
- [ ] Window min 600x400; narrow widths collapse the right sidebar/tabs sensibly.
- [ ] Geist actually loaded (compare glyphs `a`, `g`, `1`); Lucide icons are the Lucide shapes, not SF Symbols fallback.
- [ ] Sidebar: hover, active, selected, card hover-revealed controls; Search field; Projects buttons.
- [ ] Tabs: hover close, active underline, overflow chevrons with many tabs, + menu, Command button, middle-click close, double-click rename, context menu.
- [ ] Right sidebar: 6 activity icons, active indicator, empty states.
- [ ] Status bar: host state dot/text, session count, "Host not running" variant.
- [ ] Landing / host-not-running state, toasts instead of native alerts, custom tooltips (400 ms), Settings page (Back to app, search, 896 pt column, Terminal/Appearance wired).
- [ ] Terminal: palette dark/light, selection, SF Mono 14/500, 4 pt padding, inactive pane dimming, `clear`, Ctrl-C, resize/`stty size`.
- [ ] Reduce Motion / Reduce Transparency / Increase Contrast.
Use real mouse input for hover/click states (synthetic clicks were unreliable).

## Known items to flag
- The sidebar shows the literal label "Orca Mobile" (copied from the spec): decide a smthz name with the user before release.
- Tabs/sidebar are driven by host sessions; real tab model (ShellModel) binding is M3 WP-A0/A3.
- Bundle identifier, signing identity, Liquid Glass use (only menus/popovers) are still pending decisions.

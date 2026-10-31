# Terminal conformance (WP-T1)

Date: 2026-10-31. Checklist C1–C15 from `docs/TERMINAL-BEHAVIOR.md` plus the PARITY-AUDIT WP 5 items, checked in the real app.

## Setup

- Build: `swift build --scratch-path /tmp/smthz-t1` (Xcode toolchain). App: a copy of `build/smthz.app` at `/tmp/smthz-t1/smthz.app` with the scratch `SmthzApp`/`smthzd` binaries, ad-hoc signed.
- Private host: `smthzd --state-dir /tmp/smthz-t1/st` (a second one on `/tmp/smthz-t1/st2` for the Landing check), app opened with `open -n --env SMTHZ_SOCKET=... --args -SmthzStateDirectory ...`.
- Input: System Events keystrokes only after checking that the app copy's pid was frontmost; clicks, drags and wheel through CGEvent (`osascript -l JavaScript`). Evidence: screenshots (`screencapture`) and host logs (`smthz read`). Screenshots were kept in the scratch folder only and deleted with it.
- Shell: the user's login zsh (`/bin/zsh -l`) at 54x164 cells; ABC keyboard layout.
- Headless tests: `Tests/SmthzCoreTests/TerminalConformanceTests.swift` (6 tests, interactive `zsh -f -i` on a real PTY with `SessionEnvironment`).

## Results

| # | Item | How tested | Result | Evidence | Fix | Not verified |
|---|---|---|---|---|---|---|
| C1–C4 | TERM, terminfo, COLORTERM, UTF-8 locale | App: `echo TERM=$TERM CT=$COLORTERM LANG=$LANG; tput colors`. Test `shellSeesTerminfoColourAndUTF8Locale` | Pass | `TERM=xterm-256color CT=truecolor LANG=en_US.UTF-8`, `256` | – | – |
| C5 | `clear` | App: `clear` after output. Test `clearAndControlLEraseTheDisplay` | Pass | Screen blank with the prompt on row 0; bytes `ESC[3J ESC[H ESC[2J` | – | Scrollback empty after `clear` checked only by bytes, not by scrolling up |
| C6 | Ctrl-L | App: `seq 1 5`, Ctrl-L. Same test | Pass | Prompt redrawn at the top; `ESC[2J` emitted | – | – |
| C7 | ED/EL/CUP | Exercised through vim, less, top and `clear` | Pass (indirect) | Screens drawn correctly | – | No synthetic byte-level replay this round (done in TERMINAL-BEHAVIOR) |
| C8 | Line wrap | App: `printf '%0200d' 0` at 164 columns | Pass | 164 + 36 characters on two rows | – | Reflow after a width change |
| C9 | SIGWINCH / `stty size` after resize | App: `trap 'stty size' WINCH`, then ⌘D split, ⌘W close, ⌘= zoom ×3. Test `sttySizeFollowsResize` | Pass | `54 164` → split `54 81` (both panes) → close `54 164`; zoom `51 148`, `48 133`, `43 121` | – | Window-edge drag resize (sidebar drag also reported `54 162…148`) |
| C10 | Bracketed paste | App: `printf '\e[?2004h'; cat -v`, then ⌘V, Edit › Paste into terminal, context menu Paste. Test `bracketedPasteIsRequestedAtThePromptOnly` | Pass | `^[[200~line1` / `line2^[[201~` once per paste (the second copy on screen is `cat`'s output after the tty echo; one `send` per paste confirmed with a temporary log) | – | – |
| C11 | Alternate screen: vim, less, top | App: `vim -u NONE -N file`, `:q`; `seq 1 300 \| less`, space, `q`; `top -s 1 -n 10`, `q` | Pass | Full-screen UI drawn; primary screen (`echo BEFORE-VIM`…) restored after each | – | htop (not installed; `top` used instead) |
| C12 | Ctrl-C, Ctrl-Z, `fg` | App: `sleep 100`, Ctrl-Z, `jobs; fg`, Ctrl-C. Test `controlZStopsAndFgResumesTheForegroundJob` | Pass | `zsh: suspended sleep 100`, `[1] + continued sleep 100`, `^C`, shell alive | – | – |
| C13 | Exit notice | App: `exit` | Pass | "Terminal exited … exit code 0. Its output is preserved." with Close/Restart | – | – |
| C14 | Colour: 256 and true colour | App: 24-bit gradient (`ESC[48;2;r;g;bm`), `ESC[38;2;255;100;0m`, `ESC[31m`, `ESC[38;5;46m` | Pass | Smooth gradient, orange, ANSI red, index-46 green | – | Light theme |
| C15 | PATH/HOME | Covered by `SessionEnvironmentTests` | Pass (existing tests) | – | – | – |
| W1 | Mouse reporting | App: `vim -c 'set mouse=a ruler'`, CGEvent click on line 4 | Pass | Ruler moved to `4,9` | – | Drag/selection reporting, SGR wheel in TUIs with mouse mode, Shift-click override |
| W2 | Selection and copy | App: CGEvent drag over text + ⌘C; double-click a word + ⌘C | Pass | Clipboard `LECT-ME-PLEASE` (drag start offset was the test's), `WRAPWORD` | – | Triple-click line selection, copy-on-select (setting is VISUAL-ONLY) |
| W3 | Wheel scrollback and alternate scroll | App: line-unit wheel over 200 rows; wheel inside `less` | Pass | Scrolled back to `row-97`; `less` advanced 15 lines | – | Trackpad momentum |
| W4 | Find in terminal | App: ⌘F, `needle` (1/2), `row-12` (1/11, scrolled into scrollback), Esc | Pass | Bar shows counts, match highlighted, Esc returns focus to the terminal | – | Regex/case toggles. Observation (out of scope): ⌘A in the find field does not select the field text |
| W5 | Font zoom | App: ⌘= ×3, ⌘0 | Pass | Grid shrinks and the shell gets SIGWINCH (see C9) | – | ⌘- |
| W6 | Wide and emoji glyphs | App: `你好`, `😀`, `👍🏽`, `é`, half-width `ｱ`. Test `wideAndEmojiCharactersAreUTF8` | Pass | CJK and emoji take 2 cells, columns after them line up | – | Grapheme clusters wider than 2 code points (ZWJ sequences) |
| W7 | IME / marked text | App with `-terminal.optionAsAlt off`: `echo caf`, Option-E, E | Pass (dead key) | Marked `´` shown at the cursor, then `café` | **Fixed:** Option was hard-wired as Meta, so dead keys and composing layouts (the Mac also has Latin American enabled) could never compose. Now `TerminalOptionKey` follows Orca "auto" (Alt only on ABC/US) and the input source | A real IME (Japanese/Chinese), switching layouts live, `TerminalSettingsModel.apply` still forces Meta for "auto" (settings lane) |
| W8 | OSC 52 | App: `printf '\e]52;c;%s\a' $(printf osc52-on \| base64)`; `printf '\e]52;c;?\a'`; relaunch; relaunch with `-terminal.allowOsc52Clipboard NO` | Pass after fix | Write → clipboard `osc52-on`; query → no reply; relaunch → clipboard kept (`sentinel2`); setting off → clipboard kept | **Fixed:** writes were always allowed and replayed history re-applied old writes (control build without the fence: clipboard became `osc52-off` on relaunch). Now `TerminalClipboardPolicy` gates writes on `terminal.allowOsc52Clipboard` (default on, as in Orca), blocks replayed ones and caps size; reads stay denied | Settings toggle (settings lane wires the key) |
| W9 | Replay after relaunch | App: run vim twice, quit app, relaunch | Pass after fix | Before: `2R1R65;20;1c12;2$y` typed into the zsh prompt (DSR, DA2, DECRQM replies to vim's old queries). After: prompt clean, host log has no new input | **Fixed:** replies generated while history is replayed are dropped | A TUI that is still waiting for an answer when the app relaunches would not get one |
| W10 | Session selection by real click | App: CGEvent click on the `Shell 1` tab, then typing | Pass | Shell 1 content shown, `echo IN-SHELL-ONE` reached that session | – | Sidebar session rows |
| W11 | Focus of a new tab | App from Landing (fresh state dir): ⌘T, then type without clicking | Pass after fix | Before: hollow cursor, typed text lost until a click. After: `echo LANDING-FIRST-TAB` reached the new session | **Fixed:** focus requested before the pane was in a window was dropped; it is now granted in `viewDidMoveToWindow` | – |

## Not done

- Copy terminal context, `terminal.switchInputSource` and file-path link detection (PARITY-AUDIT WP 5 extras): not implemented in this WP.
- Light mode, pixel measurements, VoiceOver.
- Terminal surfaces still do not call `TerminalSettingsModel.apply` when created (noted in UI-WIRING by the settings lane).
- Replay at a different size than the original output (TERMINAL-BEHAVIOR P3) was not reproduced or changed.

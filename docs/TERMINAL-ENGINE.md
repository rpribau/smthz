# Terminal engine evaluation (M1/M3)

Date: 2026-10-24. Decision: **adopt SwiftTerm for the app's terminal view.**

## Candidate
- SwiftTerm `1.99.1` (tag `v1.99.1`, commit `2f573f7`, 2026-10-20), pinned with `exact:` in `Package.swift`, attached to the `SmthzApp` target only (`SmthzCore`, `smthz`, `smthzd` and the tests do not depend on it).
- License: MIT (Miguel de Icaza; portions from xterm.js and others, all permissive). Public API only.
- Transitive packages resolved by SwiftPM: `swift-argument-parser`, `swift-png`, `h`, `swift-docc-plugin` (declared by SwiftTerm; only SwiftTerm's library target is linked into the app). `Package.resolved` now exists.
- Note: version numbers jump from 1.20.0 to 1.99.x upstream; 1.99.1 is the newest tag.

## Integration (`Sources/SmthzApp/TerminalSessionView.swift`)
- `TerminalView` (AppKit) in an `NSViewRepresentable`; one emulator per selected session (`.id(sessionID)`).
- Output: poll `session.read` (25 ms when idle, no sleep while draining) from cursor 0, feed bytes to the emulator. Switching sessions or reopening replays the host log, so the screen is rebuilt.
- Input: `TerminalViewDelegate.send` -> ordered command queue -> `session.write`.
- Resize: `sizeChanged(newCols:newRows:)` -> `session.resize` with the real grid.
- One persistent `HostClient` per terminal inside an actor (reconnects after an error); synchronous RPC never runs on the UI actor.
- Font size controls, link opening (http/https only), clipboard copy, bell, exit notice (`[Process exited: ...]`).
- `scripts/package-app.sh` accepts `SMTHZ_SCRATCH_PATH` (default unchanged).

## Verified in the real app (debug bundle, ad-hoc signed, `smthzd` at default paths, screenshots)
- New Shell (toolbar shortcut Cmd-Shift-N): zsh prompt renders cleanly, no raw escape codes.
- Typing through the UI (System Events key events): `echo hello-from-ui`, `tput setaf 1; echo RED-TEXT`, `ls -G /` (colours render), `seq 1 300`.
- Resize: `stty size` reports `40 70`, which matches the visible grid (host PTY received the real rows/cols).
- Scrollback: after `seq 1 300`, mouse-wheel scroll shows earlier lines (113-152).
- Session switching: leaving and returning to a session replays the same screen.

## Not verified / limits
- Typing used `System Events`: `keystroke " "` (a literal space) is dropped before it reaches the app, `key code 49` works; `keystroke` with `'` was garbled. This is the synthetic-event path, not evidenced as a SwiftTerm defect. Real keyboard use, IME/dead keys, Option-as-Meta and paste were not exercised.
- Shift-PageUp is forwarded to the shell, not used for scrollback (SwiftTerm 1.99.1 behaviour as observed). Mouse-wheel scroll works.
- Mouse reporting, selection/copy UI, Find bar, alternate-screen apps (vim/less/htop), true colour, Kitty graphics and sixel were not tested.
- Performance was not measured (no baseline yet).

## Defect found in the host (SmthzCore, out of scope for this task)
Shells started by `smthzd` have **no controlling terminal**: `ps` shows TTY `??`, TPGID 0, and foreground jobs share the shell's process group. Consequences seen in the UI:
- Ctrl-C does not interrupt `sleep 100` (the tty echoes `^C` but no SIGINT is delivered); a shell stuck in `dquote>` cannot be escaped with Ctrl-C.
- No SIGWINCH reaches the shell after `session.resize`, so zsh keeps its start-up `COLUMNS` (80). zsh's `PROMPT_EOL_MARK` padding then wraps in a narrower terminal and shows a stray `%` line before each prompt. `stty size` is correct because the kernel size is updated.
- Job control (Ctrl-Z, fg/bg) cannot work.
`PTYSession.swift` assumes `POSIX_SPAWN_SETSID` plus `addopen` of the slave acquires the controlling tty; on this macOS it does not. Suggested fix for the SmthzCore author: make the child acquire the ctty explicitly (e.g. `ioctl(TIOCSCTTY)` in a small exec trampoline, or an equivalent spawn path) and add a test asserting `tcgetpgrp`/`ps -o tpgid` is non-zero and that Ctrl-C (`\x03`) kills a foreground `sleep`.

## Also noted
- The session list formats pids with a thousands separator ("17,840"); cosmetic, not changed here.
- Creating the session at 80x24 and resizing on first layout is a small race for programs that read the size once; opening the session with the view's real size is a follow-up.

## Alternatives (not needed now)
If SwiftTerm later proves insufficient: libghostty/Ghostty embedding, or a WebKit terminal with xterm.js (needs a bundled JS asset; Node is not required at runtime). Neither was evaluated.

## Resolved (2026-10-24): `clear` under a `TERM=dumb` host

The host now builds each session's environment with `SessionEnvironment` (`Sources/SmthzCore/SessionEnvironment.swift`): `TERM=xterm-256color`, `COLORTERM=truecolor`, UTF-8 `LANG`, a standard `PATH` without Xcode toolchain dirs, `HOME/USER/LOGNAME/SHELL`; an explicit `session.create` environment overrides. Verified headlessly and in the app (see `docs/TERMINAL-BEHAVIOR.md`, C1-C5, C8, C12, C15). The app also resets the emulator on `truncated` reads and creates shells at the view's real size.

# Terminal behaviour: the `clear` bug and conformance checklist

Date: 2026-10-24. Scope: research only. No code or file other than this document was changed.
Build used for reproduction: `.build-haiku` (removed afterwards), SwiftTerm 1.99.1 (tag `v1.99.1`, the pinned version).

## Summary

- **Most probable root cause (verified):** the shell does not receive `TERM=xterm-256color`. `smthzd` gives every session the environment of the `smthzd` process (`HostService.swift:262`, `WorkspaceModel.swift:14-15` passes no `environment`). The `smthzd` and `SmthzApp` processes currently running on this machine (pids 43623 and 43679, Xcode DerivedData build) have **`TERM=dumb`** and no `LANG`. With `TERM=dumb`, `/usr/bin/clear` emits nothing, so typing `clear` shows no change. This was reproduced headlessly end to end.
- **Second, same family (verified):** if `TERM` is unset, `clear` prints `TERM environment variable not set.` and exits 1.
- **Not the cause (verified):** the emulator. When the bytes that `clear` produces under `xterm-256color` are replayed through SwiftTerm's headless `Terminal`, the screen is cleared, leaving only the new prompt on row 0. SwiftTerm implements ED 2 and ED 3 (`Terminal.swift:4331-4372`).
- **Not the cause (verified):** the PTY and RPC path. The shell writes the correct clear sequence and `session.read` returns it intact.
- **Recommended fix (for the SmthzCore author, not done here):** build the child environment explicitly in the host and never inherit `TERM` from the host process. Details in the last section.

## Evidence chain

### 1. What the app does (read from source)

| Step | Where | What happens |
|---|---|---|
| New Shell | `Sources/SmthzApp/WorkspaceModel.swift:14-15` | `createSession(executable: "/bin/zsh", arguments: ["-l"], cwd: $HOME)`. No `environment`, no `rows`/`cols` (defaults 24x80). |
| Host env default | `Sources/SmthzCore/HostService.swift:262` | `environment: p.environment ?? ProcessInfo.processInfo.environment`. The child gets the host's environment. |
| Spawn | `Sources/SmthzCore/PTYSession.swift:63` | Environment is passed as `envp`, sorted. Nothing is added or removed (`TERM`, `COLORTERM`, `LANG` are not set anywhere in `Sources` or `Tests`; verified by grep). |
| Controlling tty | `PTYSession.swift:89-93` | `setsid`, `TIOCSCTTY`, `dup2` of the slave to stdio, then `execve`. Ctrl-C works because of this (per the handoff notes). |
| Output | `SessionManager.swift:141-159` | Output is kept in a 4 MiB in-memory window (`SessionManager.swift:33`) or in a bounded on-disk scrollback. Reads are by absolute offset; `truncated` is returned at `:158`. |
| Display | `Sources/SmthzApp/TerminalSessionView.swift:112-119` | Polls `session.read` from cursor 0 and feeds every chunk to `TerminalView.feed(byteArray:)`. |
| Input | `TerminalSessionView.swift:157-159` | `send` queues `session.write`. |
| Resize | `TerminalSessionView.swift:152-155`, `PTYSession.swift:186-193` | `sizeChanged` queues `session.resize`, which is `TIOCSWINSZ` on the master. |

The app does not set `TERM` on the `TerminalView` either. `TerminalView` is an emulator and does not spawn anything, so nothing in the UI path sets the child's `TERM`.

### 2. What the host gives the shell (verified)

Hosts were started on private sockets (`/tmp/smthz-hk/*.sock`), each with a zsh session created by `smthz run -- /bin/zsh -l`:

| Host started with | Shell's `$TERM` | `clear` output (bytes after the echoed command) | Visible result |
|---|---|---|---|
| `TERM=xterm-256color` (inherited from my shell) | `xterm-256color` | `ESC[3J ESC[H ESC[2J` (+ new prompt) | Screen cleared |
| `env TERM=dumb` | `dumb` | **none** (echo `clear`, then `\r\n`, then new prompt) | **Screen not cleared** |
| `env -u TERM` | unset | `TERM environment variable not set.` | Error line, screen not cleared |

Standalone check (same binary, same environment):

```
TERM=xterm-256color /usr/bin/clear | od -c   -> 033 [ 3 J 033 [ H 033 [ 2 J   (exit 0)
TERM=dumb           /usr/bin/clear | od -c   -> (no bytes)                        (exit 0)
env -u TERM         /usr/bin/clear           -> TERM environment variable not set. (exit 1)
TERM=dumb           /usr/bin/tput setaf 1    -> (no bytes)
```

`infocmp dumb` reports `dumb|80-column dumb tty`, which has no `clear` capability. `xterm-256color` terminfo is present in `/usr/share/terminfo`.

### 3. Emulator replay (verified)

Raw logs were read with `smthz read <id>` from each host and fed to SwiftTerm's headless `Terminal` (80x24, scrollback 1000), using a replay tool in the scratchpad that is outside the project:

| Log | Screen after the whole log |
|---|---|
| `xterm-256color` host, `clear` | row 0: `robs@... smthz %` (cleared, cursor at top) |
| `dumb` host, `echo BEFORE-CLEAR`, `clear`, `echo TERM=$TERM ...` | rows 0-5 still show `echo BEFORE-CLEAR`, `BEFORE-CLEAR`, `... clear` and the prompts. The emulator is correct: there was nothing to erase. |
| unset-`TERM` host | row 3 shows `TERM environment variable not set.` |

Synthetic checks (verified): `ESC[?1049h ... ESC[?1049l` returns to the primary screen with its content intact. `ESC[3J` alone clears scrollback and leaves the visible screen.

### 4. Live environment of the user's running processes (verified)

```
ps eww -o command= -p 43623   # smthzd (Xcode DerivedData build)
  TERM=dumb
  PATH=/Applications/Xcode.app/Contents/Developer/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin
  (no LANG, LC_*, COLORTERM)
ps eww -o command= -p 43679   # SmthzApp
  TERM=dumb
```

For comparison, my test host (started from a normal shell) had `TERM=xterm-256color LANG=en_US.UTF-8 COLORTERM=truecolor`.

**Inferred:** Xcode launches processes with `TERM=dumb` and its own `PATH`, and the sessions created by the app inherit this. I did not confirm Xcode's launch behaviour from Xcode's own documentation. Whether the bug report was made against this exact host is inferred from timing: the processes have been running about 5-6 minutes.

**Consequence:** `TERM=dumb` also affects `tput`-based colour. The earlier claim in `docs/TERMINAL-ENGINE.md` that `tput setaf 1` renders red was not reproducible under `TERM=dumb`, so that check must have run with a non-dumb host (inferred).

## Prioritized diagnosis

1. **P1 (verified, probable root cause): child `TERM` is `dumb`, or unset, because it is inherited from `smthzd`'s environment.** `clear` depends on the terminfo entry for `$TERM`. `dumb` has no `clear` capability, so the shell emits nothing. Fix in the host (see the fix section).
2. **P1 (verified, same mechanism): `LANG` is missing in the running host.** Without `LANG`, zsh uses the C locale. Output with non-ASCII text may then be shown wrongly. This was not reproduced here. Consider it with P1 because the same fix covers it.
3. **P2 (inferred): `PATH` in the host is Xcode's.** A host started from Xcode gets `/Applications/Xcode.app/.../usr/bin` first, so shell tools such as `git`, `python`, and `clang` come from Xcode's copies. Not part of the clear bug, but the same environment problem.
4. **P3 (inferred, not reproduced): replay from cursor 0 happens at the view's initial size.** `TerminalSessionView` feeds the whole log into an emulator whose size is the view's size at creation time. The shell produced that output at the 80x24 default or at the size of a previous resize. Wrapping or cursor-positioned output can then differ from the live screen. Clear sequences themselves still replay correctly, because they reset state regardless of size. This does not cause the reported bug, but it can cause visibly wrong screens after switching sessions.
5. **P3 (verified in code): `truncated` is ignored.** `session.read` returns `truncated` when the requested offset is older than the 4 MiB window (`SessionManager.swift:158`). `TerminalSessionView.swift:115-118` ignores it. Output lost before a re-attach is silently skipped. Not related to `clear`.
6. **Ruled out:** the emulator (section 3), the PTY write path (section 2 shows the bytes intact), the controlling tty (fixed per the handoff notes, so SIGWINCH now reaches the foreground group, but this task did not test it), bracketed paste, alternate screen.

## Conformance checklist (what smthz must satisfy)

Each item has a test. Items marked **(h)** can be run headlessly with `smthzd` and `smthz`. Items marked **(u)** need the app UI.

| # | Behaviour | Expected | Test |
|---|---|---|---|
| C1 | `TERM` is set and has a terminfo entry | `xterm-256color` (SwiftTerm's own default, `Terminal.swift:8912`, `TerminalOptions.swift:217`) | (h) `smthz run -- /bin/zsh -l`, then `smthz write <id> 'echo TERM=$TERM\n'`; read; expect `TERM=xterm-256color` |
| C2 | Terminfo resolves | `infocmp $TERM` succeeds | (h) `smthz write <id> 'infocmp $TERM >/dev/null && echo OK\n'` |
| C3 | `COLORTERM` for truecolor | `truecolor` | (h) `echo $COLORTERM` |
| C4 | UTF-8 locale | `LANG=en_US.UTF-8` (SwiftTerm uses the same, `Terminal.swift:8919`) | (h) `echo $LANG`; then `echo 'héllo ✓'` and check bytes are UTF-8 (`c3 a9`, `e2 9c 93`) |
| C5 | `clear` clears the viewport and scrollback | `ESC[3J ESC[H ESC[2J`; viewport blank, cursor at row 0, no scrollback above | (h) capture bytes (procedure below); (u) type `clear`, scroll up: nothing above the prompt |
| C6 | Ctrl-L (zsh `clear-screen`) | Clears the screen and redraws the prompt at the top | (u) press Ctrl-L; (h) capture bytes and check for a `ESC[H`/`ESC[2J` pair (not yet verified) |
| C7 | ED 0/1/2/3, EL, CUP | Standard semantics (SwiftTerm `Terminal.swift:4331`) | Synthetic bytes through the replay tool |
| C8 | Line wrap | Wraps at `cols`; `printf` of 100 characters at 40 columns puts 60 characters on the next line | (h) `smthz write <id> 'printf "%0100d\\n" 0\n'`, then replay |
| C9 | Resize reaches the shell | After `session.resize`, `stty size` and `$COLUMNS` match the view | (h) `smthz run` with `stty size` after a resize (see procedure); (u) resize the window and run `stty size` |
| C10 | Bracketed paste | zsh enables `ESC[?2004h` at the prompt (verified in captured bytes) and `ESC[?2004l` while a command runs | (h) captured bytes show `?2004h` at the prompt; (u) paste text, check the shell receives `ESC[200~ ... ESC[201~` (not yet verified) |
| C11 | Alternate screen | `ESC[?1049h` enters, `ESC[?1049l` restores the primary screen, primary content intact | Synthetic replay (verified in section 3); (u) run `vim` or `less`, quit, check the prompt content returns |
| C12 | Ctrl-C and job control | Ctrl-C interrupts a foreground job; Ctrl-Z stops it; `fg` resumes | (h) `sleep 100` then `\x03`; `ps -o tpgid -p $$` non-zero (per handoff notes) |
| C13 | Exit notice | `[Process exited: ...]` appears once | (u) `exit` in the shell |
| C14 | Colour | `tput colors` = 256; `tput setaf 1` emits `ESC[31m`; truecolor `ESC[38;2;...m` renders | (h) under `TERM=xterm-256color` capture bytes; (u) visual |
| C15 | `PATH` and `HOME` | Child has a sane `PATH` (not Xcode's), `HOME`, `USER`, `LOGNAME`, `SHELL` | (h) `echo $PATH`, `echo $HOME` in the session |

## Concrete test procedures

### Capture the bytes the shell sent (headless, works now)

```sh
B=.build-haiku/debug            # or your build products
S=/tmp/smthz-hk/s.sock          # short path, under 104 bytes
$B/smthzd --socket $S --journal /tmp/smthz-hk/j.sqlite &
$B/smthz run --socket $S -- /bin/zsh -l            # prints the session id
ID=<id>

# Read the cursor from stderr: "next=N exit=running".
$B/smthz read $ID --socket $S > /dev/null 2> /tmp/smthz-hk/c0
C0=$(sed -n 's/.*next=\([0-9]*\).*/\1/p' /tmp/smthz-hk/c0)

$B/smthz write $ID 'clear\n' --socket $S
sleep 1
$B/smthz read $ID --from $C0 --socket $S 2>/dev/null | od -c
```

Expected with a correct `TERM`: `033 [ 3 J 033 [ H 033 [ 2 J` after the echoed `clear`. Expected with `TERM=dumb`: no `033 [ 2 J`.

Full log for the replay tool: `smthz read $ID --socket $S > log.bin` (no `--from`, which starts at 0).

### Replay a log through the emulator (headless)

Use a tiny executable that depends on SwiftTerm (for example a scratch package outside the project) and calls `Terminal(delegate:options:)`, `feed(byteArray:)`, then prints `getLine(row:)?.translateToString(trimRight: true)` for each row. This is what section 3 used. Check the printed rows against the expected screen.

### Check the host's environment (what the shell will inherit)

```sh
ps eww -o command= -p "$(pgrep -f 'smthzd --socket')" | tr ' ' '\n' | grep -E '^(TERM|LANG|COLORTERM|PATH)='
```

### Check what the shell itself sees

```sh
$B/smthz write $ID 'echo TERM=$TERM LANG=$LANG COLORTERM=$COLORTERM\n' --socket $S
```

### Check the controlling tty and job control

```sh
$B/smthz write $ID 'ps -o pid,tty,tpgid -p $$\n' --socket $S
$B/smthz write $ID 'sleep 100\n' --socket $S
# Ctrl-C: `smthz write` decodes only \n escapes, so send byte 0x03 from the app
# (or through HostClient). Not run from the CLI in this session; the shell should survive.
```

### Check resize

```sh
$B/smthz write $ID 'stty size; echo COLUMNS=$COLUMNS\n' --socket $S
# Resize the view (or call session.resize with rows 40, cols 70), then:
$B/smthz write $ID 'stty size; echo COLUMNS=$COLUMNS\n' --socket $S
```

Note: `smthz` has no resize subcommand. Use the app, or a direct `session.resize` call through `HostClient`.

### Run the real UI check (once the fix is in)

1. Quit the app. Stop the `smthzd` that the app uses (check with `ps`; do not kill another user's host without asking).
2. Start `smthzd` with a known environment, for example `env TERM=xterm-256color LANG=en_US.UTF-8 smthzd`. The fix should make this unnecessary.
3. In the app, New Shell. Type `echo $TERM` (expect `xterm-256color`), then `clear` (expect the screen to clear and scrollback to be empty).

## Recommended fix (for the SmthzCore author)

The host should build the child environment explicitly, not inherit it:

1. Add a single function (for example `TerminalEnvironment.default(base:)`) that returns `TERM=xterm-256color`, `COLORTERM=truecolor`, `LANG` (keep the host's value if set, otherwise `en_US.UTF-8`), `HOME`, `USER`, `LOGNAME`, `SHELL`, and a `PATH` that starts with `/usr/bin:/bin:/usr/sbin:/sbin` plus the host's own non-Xcode entries. Use `Terminal.getEnvironmentVariables(termName:)` semantics as the model (`Terminal.swift:8903-8920`).
2. Call it in `HostService` for `session.create` when `environment` is nil, and in `smthz run` (CLI) so both paths match.
3. Test: create a session, read `echo $TERM`, expect `xterm-256color` (C1). Add a test that `session.read` after `clear` contains `ESC[2J`.
4. Do not let `TERM` leak from the host. `dumb` and unset must never reach a shell.

This is a host change, so it belongs to a SmthzCore task, not this research task.

## Sources

- SwiftTerm 1.99.1 (pinned): <https://github.com/migueldeicaza/SwiftTerm/tree/v1.99.1>
  - ED handler, ED 2 and ED 3: `Sources/SwiftTerm/Terminal.swift:4331-4372`
  - Default `TERM`, `COLORTERM`, `LANG` helper: `Sources/SwiftTerm/Terminal.swift:8903-8920`
  - Default `termName`: `Sources/SwiftTerm/TerminalOptions.swift:217`
  - Local child spawns with the helper: `Sources/SwiftTerm/LocalProcess.swift:600`
- Local code (line numbers as of this document): `Sources/SmthzApp/TerminalSessionView.swift`, `Sources/SmthzApp/WorkspaceModel.swift`, `Sources/SmthzCore/HostService.swift`, `Sources/SmthzCore/PTYSession.swift`, `Sources/SmthzCore/SessionManager.swift`
- `docs/TERMINAL-ENGINE.md` (the earlier evaluation, including its colour claim, see the note above)
- `clear` and terminfo: `/usr/bin/clear`, `/usr/share/terminfo/64/dumb` (checked with `infocmp`)

## Verified vs inferred

**Verified (reproduced in this session):**
- `clear` emits nothing under `TERM=dumb`, prints an error when `TERM` is unset, and emits `ESC[3J ESC[H ESC[2J` under `xterm-256color`.
- A shell started by `smthzd` inherits the host's `TERM`, and the shell's output reflects it (`TERM=dumb` in the shell).
- The live `smthzd` (pid 43623) and `SmthzApp` (pid 43679) have `TERM=dumb` and `PATH` from Xcode; the live `smthzd` has no `LANG`.
- SwiftTerm's headless emulator clears the screen on the captured `xterm-256color` bytes and does not on `dumb` bytes.
- Alternate screen restore and ED 3 behave as expected in the emulator.

**Inferred (not verified):**
- Xcode sets `TERM=dumb` for processes it launches, and the bug report came from this host.
- The bug in the UI is caused only by `TERM`. The UI itself was not driven in this session.
- Replay from cursor 0 at the wrong size causes visibly wrong screens (P3). Not reproduced.
- Bracketed paste sent from the UI, Ctrl-L behaviour, and resize with `stty size` are expected from the source, not observed.

**Not done:** no UI test (the app was not driven), no web search (the SwiftTerm source at the pinned tag was the primary source), and no change to any code or to the user's running processes.

## Cleanup

Test hosts started on `/tmp/smthz-hk/*.sock` were stopped and their sessions closed. `.build-haiku` and `/tmp/smthz-hk` were removed. The user's `smthzd` (pid 43623) and `SmthzApp` (pid 43679) were not touched.

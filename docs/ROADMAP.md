# smthz implementation roadmap

## Approved product

Native macOS 26+ Apple Silicon application, English UI, SwiftUI/AppKit shell and Swift-owned core. Reimplement the applicable Orca 1.4.238 desktop workflows from `reference/orca-1.4.238`; use `icon/icon.png` as the brand source. Windows, companion mobile applications and importing Orca application state are deferred. Desktop iOS/Android development tools remain in scope. Execution hosts support macOS and Linux.

Use public WebKit APIs exclusively for browsing. When an experiment demonstrates a gap, investigate an equivalent native workflow. Any actual reduction in functionality requires the user's explicit acceptance. Chromium and private APIs are excluded. Small page scripts and isolated document renderers are allowed; application state and authority remain in Swift.

Own accounts, relay, pairing/revocation, profiles, sharing and artifact/skill storage services are required. Do not use Orca production endpoints or credentials. Native C/C++ dependencies and external Git, ripgrep, OpenSSH and agent executables are permitted. Node is restricted to justified isolated compatibility adapters, never the application core.

## Architecture

- SwiftUI navigation/settings plus AppKit terminal, editor and document surfaces. Liquid Glass on navigation and controls; stable semantic surfaces for working content.
- Independent Swift `smthzd` execution host, persistent PTY owner, Swift CLI and macOS UI. Each execution host owns its processes, workspaces, accounts, journals and scheduling. Windows own presentation state.
- SQLite transactions and journals, bounded file/blob storage, authenticated Unix socket locally and versioned WebSocket remotely. Request IDs, capabilities, process incarnations, cancellation, limits and acknowledgements are explicit contracts.
- No resubmission of possibly executed input after connection loss. No treating missing observations as proof of process death. PID alone is not process ownership.
- SwiftTerm is the first terminal engine to evaluate; editor parity and Claude's native control path require experiments. No engine or SDK replacement is assumed equivalent without evidence.

## Milestones

| ID | Deliverable | Acceptance |
|---|---|---|
| M0 | Swift project, identities, durable ledger, build prerequisites | Build and tests; traceable scope; no false completed-feature claims |
| M1 | PTY/terminal, editor, WebKit macOS/Linux, Claude and helper experiments | Reproducible behavior, limitations and evidence for each choice |
| M2 | SQLite recovery, process ownership, host/CLI and authenticated RPC | Crash/reconnect/idempotency/identity tests |
| M3 | Native shell, persistent terminals, tabs, groups, splits and windows | Real processes survive UI detach; restore does not duplicate work |
| M4 | Project/folder/worktree/Git/hooks, files/editor/diffs/documents | Folder and Git journeys, safe saves, recovery and meaningful edits |
| M5 | Agent launch, provider transports, accounts/chat/permissions/history/usage | Capabilities match each provider; no duplicate sends or wrong-host state |
| M6 | WebKit browser, profiles/design/automation/capture/routing | Browser capability fixtures; explicit native equivalents for gaps |
| M7 | Own auth/relay, SSH and paired macOS/Linux hosts, tunnels/update | Real deployment, pairing/revocation/reconnect and remote journeys |
| M8 | Orchestration DAG/mail/receipts/federation, automation, VM recipes | Durable ownership and failed-attempt recovery; real scheduled runs |
| M9 | Hosted integrations, skills/plugins/artifacts and own storage/sharing | Per-provider workflows; real installation and publication grants |
| M10 | Speech/computer-use/emulators/attention/pet/settings | Real prerequisite-backed features, permissions and accessible UI |
| M11 | Full ledger audit, recovery, benchmarks, distribution/update/notices | Evidence-backed parity; signed install/update; accepted performance |

Backend contracts begin with M2; real auth/relay precedes public pairing and real storage precedes sharing. Work proceeds in small dependency-ordered tasks, not one request per entire milestone. A working early slice is not completion of full desktop parity.

## Validation and performance

Port relevant reference invariants and fixtures rather than its historical implementation structure. Use real PTY, Git, filesystem, SQLite, socket, provider, WebKit and UI tests. Include cancellation, denied access, disk-full, stale identity, revoked pairing, host restart, lost acknowledgement and reconnect scenarios. Test macOS/Linux and plain folders independently of Git.

Compare Release builds against Orca with equivalent workloads on the same hardware, OS, repositories and agent binaries. Report app/host/helpers, WebKit WebContent/network/GPU and external agents/tools separately, plus total cost and attribution limits. Measure startup, input-to-PTY and input-to-paint latency, workspace switching, idle/peak CPU, retained memory, energy and multi-hour recovery/soak. Set numerical budgets only after the baseline; do not claim savings without measurements.

## Execution ownership

The coordinator never writes product code: it writes specifications, documents decisions, and verifies every delivery (scope diff, build, full test suite three consecutive runs, real binaries/app). Implementation is authored by dispatched workers, one bounded task per fresh session: Codex GPT-6.1 Sol (medium) is the default author, with Opus 5.5 and Sonnet 5.5 workers for research, plans, docs and selected code tasks (Codex GPT-6-Luna was also used). Hermes (local model) is paused and resumes only on the user's instruction. Workers do not run git write commands; commits and pushes are made by the coordinator.

## Current state

Implementation started 2026-10-23. Updated 2026-10-31. Xcode 27.1 is installed in `/Applications`; `xcode-select` still points at the Command Line Tools, so builds use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (Swift 6.4, macOS 27 SDK). The app is packaged as an ad-hoc signed `build/smthz.app` with a bundled `smthzd`; no signing identity, infrastructure or service credentials have been provisioned. No milestone is formally accepted yet.

| ID | Status (2026-10-31) |
|---|---|
| M0 | Mostly done: package, identities, journal, docs; repo published (MIT). Open: real bundle identifier |
| M1 | Partial: SwiftTerm chosen (`docs/TERMINAL-ENGINE.md`); editor experiment recommends Monaco in WKWebView (`docs/EDITOR-EXPERIMENT.md`); browser/agents experiment GO with reductions (`docs/BROWSER-AGENTS-EXPERIMENT.md`). Linux host and Claude control path not proven |
| M2 | Largely done locally: authenticated Unix-socket RPC, versioning, idempotency, cancellation, limits, single-instance host, disk scrollback, push streaming. Open: recovery after host restart, remote WebSocket TLS/auth, `handshake`/`request.cancel` outside durable idempotency |
| M3 | In progress: tabs, groups, splits, persistence, host auto-start, keybinding registry done; windows, floating terminal and terminal conformance checks open |
| M4 | Started: plan in `docs/M4-PLAN.md`; workspace/repo host work in progress |
| M5-M11 | Not started (visual-only placeholders exist for several pages); see `docs/PARITY.md` and `docs/PARITY-AUDIT.md` |

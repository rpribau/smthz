# BROWSER-AGENTS-EXPERIMENT: M1 gates for the WebKit browser and agent control paths

Author: Opus 5.5 worker (task_482ecadb9812), 2026-10-31. Research and prototype only: nothing in `Sources/` or `Tests/` changed.
Machine: macOS 26.6 (25G72), arm64, Xcode 27.1 SDK (MacOSX27.0), Swift 6.4. Installed agent CLIs: `claude` 2.1.308, `codex` 0.164.0 (`hermes` also present). Not installed: Chrome, gemini, opencode, aider, goose, amp, cursor-agent, copilot, grok.
Reference: `R/` = `reference/orca-1.4.238/`.

Evidence labels: **[M]** measured by the prototype in this session, **[C]** cited from `R/` (path given), **[D]** documented Apple/CLI behaviour that was not run, **[U]** unverified (design assumption).

## 0. Verdicts

| Gate | Verdict | One-line reason |
|---|---|---|
| A. WebKit browser pane (PARITY-AUDIT WP 19) | **GO** | Every pane feature measured works with public WebKit (profiles, cookies, dialogs, downloads, uploads, find, popups, PDF, auth, inspector flag). |
| A. Browser automation CLI (WP 20) | **GO with reductions** | 56 of the 80 Orca commands map fully. Network capture, request interception, device emulation, geolocation/offline, devtools and `exec` are partial or missing. Background (inactive app) mouse input is JS-synthesized (`isTrusted=false`). See §A.4. Needs user acceptance. |
| B. TUI agents in PTY tabs + status hooks (WP 14-15) | **GO** | Claude hooks can be injected per launch with `--settings` without editing `~/.claude/settings.json` [M]. Codex needs `~/.codex/hooks.json` plus trust entries, as Orca does [C]. OSC 7501 is a no-install fallback [C]. |
| B. Native chat (WP 18) | **GO in stages, Node not required** | The Codex app-server JSON-RPC handshake and `model/list` work from a plain stdio driver [M]. The Claude stream-json `initialize` control request works without the Node SDK [M]. ACP is not testable locally (no ACP agent installed) [U]. Decision needed: Swift-native Claude protocol or an isolated Node SDK sidecar (§B.6). |

---

## Part A: WebKit browser feasibility

### A.1 How Orca does it [C]

- The pane is a Chromium `webContents` per page (`R/src/renderer/src/components/browser-pane/BrowserPane.tsx`, 611 files in `R/src/main/browser/`).
- Automation goes through **CDP**. Orca bundles the native `agent-browser` binary (`R/package.json:206` `"agent-browser": "~0.27.0"`, `R/src/main/browser/agent-browser-bridge-process.ts`). It talks to a loopback CDP WebSocket proxy over each guest (`cdp-ws-proxy.ts`). The CDP methods Orca's code uses most often: `Runtime.evaluate`, `Emulation.setUserAgentOverride`, `Input.dispatchMouseEvent`, `Input.insertText`, `DOM.focus`, `Page.captureScreenshot`, `Page.screencastFrame`, `Input.dispatchKeyEvent`, `Emulation.setDeviceMetricsOverride`, `Network.getAllCookies`, `Page.handleJavaScriptDialog`, `Accessibility.getFullAXTree`, `Page.printToPDF` (grep counts over `src/main/browser`).
- The snapshot is the browser's real AX tree (`snapshot-engine.ts`, `Accessibility.getFullAXTree`) with refs bound to `backendDOMNodeId`.
- Cookie import reads Chrome/Edge SQLite and decrypts with the Keychain item `Chrome Safe Storage` + PBKDF2-SHA1 (`saltysalt`, 1003 iterations) + AES-128-CBC (`browser-cookie-key.ts:14-56`, `browser-cookie-decryption.ts:85-115`). Safari `Cookies.binarycookies` needs Full Disk Access (`browser-cookie-safari-import.ts:23`). Firefox is also supported.
- Design mode injects guest scripts (`grab-guest-*.ts`) and sends HTML, computed CSS and a cropped screenshot to the agent (`docs/site/content/docs/browser/design-mode.mdx`).
- CLI surface: `R/src/cli/specs/browser-basic.ts` (40 commands) + `browser-advanced.ts` (40 commands) = **80 commands**.

### A.2 Prototype

A throwaway SwiftPM executable (`wkprobe`, about 600 lines, deleted afterwards) with a Python test server on `127.0.0.1:8765` and a toy CONNECT proxy on `:8766`. It used **only public API**: `WKWebView`, `WKWebsiteDataStore(forIdentifier:)`, `WKHTTPCookieStore`, `WKUserScript`, `WKContentWorld`, `WKScriptMessageHandler`, `callAsyncJavaScript`, `takeSnapshot`, `pdf(configuration:)`, `printOperation(with:)`, `find`, `WKDownloadDelegate`, `WKUIDelegate`, `WKContentRuleListStore`, `WKWebsiteDataStore.proxyConfigurations` (Network `ProxyConfiguration`), and `NSEvent`/`CGEvent` sent into the app's own window. The web view lived in an **off-screen** `NSWindow` (origin -3000,-3000) in an `.accessory` app that was never activated (except in one variant, noted below).

### A.3 Measured results [M]

| Capability | Result | Evidence (run 2/run 3 of the probe) |
|---|---|---|
| Load/goto | yes | `load(URLRequest)` -> `didFinish` 111-170 ms (local server, first load includes WebContent process launch) |
| Console capture | yes | documentStart user script wrapping `console.*` + `error`/`unhandledrejection` -> `log:page-loaded 42 \| warn:a warning \| uncaught:Error: boom-uncaught` |
| Snapshot (refs) | yes, JS | DOM/ARIA walk in isolated `WKContentWorld("smthz")`: 12 nodes in 1.2-1.4 ms; 4000 entries (6000-element page) in 14.8 ms. Page world sees `typeof __smthzRefs === "undefined"` (isolation holds) |
| Click (app inactive) | **no native** | `window.sendEvent` / `wv.mouseDown(with:)` / `makeKey()` (window stayed non-key) / CGEvent-backed NSEvent / KeyLie `isKeyWindow` subclass / on-screen alpha 0 and alpha 1: **0 DOM events** in every variant. JS `el.click()` works with `isTrusted=false` |
| Click (app active, window key) | yes, native | Same `window.sendEvent` after `NSApp.activate` -> `pointerdown, mousedown, mouseup, click`, all `isTrusted=true` |
| Hover | native only when active | `mouseMoved` while inactive -> no events, `:hover` false |
| Type/keypress (app inactive) | yes, native | `keyDown` NSEvents with web view as first responder (window **not** key) -> `keydown`+`input` events `isTrusted=true`, value `hi`. `NSResponder.insertText(" there")` -> `hi there` |
| Fill | yes, JS | prototype value setter + `input`/`change` -> `filled` (`isTrusted=false`) |
| Select/check | yes, JS | `select.value` + `change`, `checkbox.click()` -> `g,true` |
| Scroll | yes, native (inactive) | CGEvent wheel -> NSEvent -> `wv.scrollWheel` -> `scrollY=300`, `wheel` `isTrusted=true` |
| Screenshot (viewport) | yes | `takeSnapshot(nil)` 0.7-1.4 ms, 1024x768, real pixels while off-screen (inspected visually) |
| Full-page screenshot | yes, by resizing | `snapshotRect` beyond the viewport returns **blank** pixels (0 dark samples). Resizing the web view frame to content height (16000 px) -> 5423/123100 dark samples (real content) |
| PDF | yes | `pdf(configuration:)` 3.7-8.6 ms, one tall page (3 pages for a 38016 px page). Paginated: `printOperation(with:)` + `runModal(for:)` -> 4 pages in 57-79 ms. **`NSPrintOperation.run()` deadlocks the main thread** (the probe hung until killed) |
| Eval | yes | `callAsyncJavaScript` with arguments and awaited promise -> `{a=42, t="Probe Page", fetched=11}` |
| Network log | partial | `decidePolicyFor navigationResponse` only sees documents (`200 / main=true`). `PerformanceResourceTiming` lists `img.png`, `echo-headers`, `missing` with duration but **`responseStatus` = n/a** (not in WebKit) |
| Extra headers | partial | Header on our own top-level `URLRequest` arrived; the same header on page `fetch` did not. `customUserAgent` arrived |
| Cookies | yes | Store sees `hc(httpOnly)`, `sc`. `document.cookie='sc=visible'`. `setCookie` of an HttpOnly+SameSite cookie is sent by the page (`hc=secret; injected=v; sc=visible`). `deleteCookie` works |
| Profiles | yes | Two `WKWebsiteDataStore(forIdentifier:)`: B has 0 cookies and sent no Cookie header. `allDataStoreIdentifiers` lists both. `remove(forIdentifier:)` while in use -> "Data store is in use" (every web view and store reference must be released first) |
| Local/session storage | yes | JS get/set/clear -> `A,1,0`. `dataRecords` lists cookies, disk/memory cache, local/session storage |
| Dialogs | yes | `WKUIDelegate` async alert/confirm/prompt: accept -> `true,typed-answer`, dismiss -> `false,null`. The async delegate can hold the dialog open until the CLI answers |
| Downloads | yes | `.download` policy + `WKDownloadDelegate` -> file written in 2.9-4 ms. `startDownload(using:)` also works |
| Upload | yes (JS path) | `DataTransfer` -> `input.files` -> `js.txt` + `change`. `runOpenPanelWith` was called once in one run. With the app inactive the native click does not arrive, so the panel path needs the app active |
| Find in page | yes | `WKWebView.find` -> `matchFound=true` |
| Viewport | yes / partial | Frame 400x700 -> `innerWidth 400`, `@media (max-width:500px)` applies. `pageZoom 0.5` -> `800x1400 dpr=0.5`. No DPR override, no touch emulation |
| Color scheme | yes | `wv.appearance` aqua/darkAqua flips `prefers-color-scheme` (`1 -> 0`). Reduced motion: no public override |
| Geolocation | partial | JS override of `navigator.geolocation` -> `40.4,-3.7` (page-visible, not engine level) |
| Offline / block | partial | `WKContentRuleList` blocking fetch/xhr/img/script -> `blocked: Load failed`, removed -> `fetched`. `navigator.onLine` is unchanged unless shimmed |
| Proxy routing | yes for http | `proxyConfigurations=[httpCONNECTProxy 127.0.0.1:8766]`: the proxy logged `CONNECT smthz.test:80` and the **plaintext tunneled** `GET /proxied` with full headers (both runs). For https the proxy would only see `CONNECT host:443` [D] |
| HTTP auth | yes | `respondTo challenge` -> `URLCredential` -> `Authed` |
| Popups | yes | `window.open` -> `createWebViewWith` called |
| Design mode (grab) | yes, JS | outerHTML + `getComputedStyle` from the isolated world + cropped `takeSnapshot(rect)` 84x18 |
| Inspector | flag only | `isInspectable = true` set without error. Attaching from Safari's Develop menu was not exercised [U]. There is no public API to embed or drive the inspector [D] |

### A.4 Orca browser CLI -> public WebKit mapping

Legend: **Y** = achievable with public API (measured or a direct API exists), **P** = partial (workaround noted), **N** = not achievable. "JS" = runs in the isolated content world.

| Orca command(s) (`R/src/cli/specs/browser-*.ts`) | WebKit | How / workaround |
|---|---|---|
| `browser identity get/set` | Y | `customUserAgent` [M]. Per-host UA (Orca's Firefox UA for Google sign-in) by switching the UA before the load [U] |
| `open-url`, `goto`, `back`, `forward`, `reload` | Y | `load`, `goBack/goForward`, `reload/reloadFromOrigin` [M load] |
| `tab list/show/current/switch/create/close` | Y | App-level registry of `WKWebView`s (no WebKit dependency) |
| `tab profile list/create/delete/set/show/use-default` | Y | `WKWebsiteDataStore(forIdentifier:)` [M]. Delete only after every view using the store closes [M] |
| `tab profile clone` | P | Cookies copy via `WKHTTPCookieStore` [M]. local/IndexedDB storage cannot be copied between stores; a JS per-origin copy covers localStorage only on origins we visit |
| `snapshot` | P | JS DOM/ARIA walk [M]. It is **not** the engine's computed AX tree: accessible-name computation is approximated, closed shadow roots are invisible, and cross-origin iframes need per-frame `callAsyncJavaScript(in: WKFrameInfo)` [D] |
| `click`, `dblclick`, `hover`, `drag`, `focus`, `check`, `uncheck` | Y while active / P while inactive | Native `NSEvent` into our window gives `isTrusted=true` when smthz is active and the window key [M]. Otherwise JS-synthesized events (`isTrusted=false`) [M]. Sites that check `isTrusted` (some anti-bot, some editors) fail in the background |
| `fill`, `clear`, `select`, `select-all`, `inserttext` | Y | JS value setter + events [M], or `insertText` into the first responder [M] |
| `type`, `keypress` | Y | `keyDown/keyUp` NSEvents are trusted even when the app is inactive [M]. The web view must be first responder, so restore the terminal's focus afterwards (Orca has the same problem: `agent-input-focus-guard.ts` [C]) |
| `scroll`, `scrollintoview`, `mouse wheel` | Y | Native wheel event, trusted while inactive [M], or JS |
| `mouse move/down/up` | P | Native when active [M], JS `PointerEvent`/`MouseEvent` otherwise |
| `screenshot` (png/jpeg) | Y | `takeSnapshot` [M] + `NSBitmapImageRep` encoding |
| `full-screenshot` | Y | Temporarily resize the web view to content height (16000 px tested) [M]. `snapshotRect` alone is blank outside the viewport [M] |
| `pdf` | Y | `pdf(configuration:)` [M]. Paginated with `printOperation` + `runModal(for:)`, never `run()` [M] |
| `eval`, `wait`, `get`, `is`, `find`, `highlight` | Y | `callAsyncJavaScript` (awaits promises) [M]; waits = JS polling + navigation delegate |
| `console`, `capture start/stop` (console part) | Y | documentStart user script + message handler [M] |
| `network`, `capture` (network part) | P | Documents: `navigationResponse` (status and headers) [M]. Page fetch/XHR: JS shim (status, headers, body). Subresources: `PerformanceResourceTiming` URLs/timings only, no status [M]. Plain-http full log: optional local proxy via `proxyConfigurations` [M]. **HTTPS subresource status/headers: N** (would need a MITM root CA: not recommended) |
| `intercept enable/disable/list` | P | Block/allow: `WKContentRuleList` [M]. Navigations: cancel/redirect in `decidePolicyFor navigationAction` [D]. Page fetch/XHR: pause/mock via JS shim. **Pause/modify arbitrary subresource requests (CDP `Fetch.requestPaused`): N** |
| `set headers` | P | Our top-level loads [M]; re-issue intercepted top-level navigations with headers [U]; page fetch/XHR via JS shim; plain-http subresources via proxy [M]. HTTPS subresources: N |
| `set credentials` | Y | Auth challenge delegate [M] |
| `set device`, `viewport` | P | Width/height via frame (real `innerWidth` and media queries) [M], UA [M], zoom [M], `WKWebpagePreferences.preferredContentMode` [U]. **DPR override and touch emulation: N** |
| `set media` | P | Color scheme via `appearance` [M]. Reduced motion only via a JS `matchMedia` shim |
| `geolocation` | P | JS shim on `navigator.geolocation` [M]. No engine-level override and no public permission delegate on macOS [D] |
| `set offline` | P | Content rule list block-all [M] + `navigator.onLine`/`offline` event shim; or point the store at a dead proxy (runtime switch unverified) [U] |
| `cookie get/set/delete` | Y | `WKHTTPCookieStore` incl. HttpOnly [M] |
| `storage local/session get/set/clear` | Y | JS [M] |
| `dialog accept/dismiss` | Y | Async `WKUIDelegate` held until answered [M] |
| `download` | Y | `WKDownloadDelegate` [M] |
| `upload` | Y | `DataTransfer` assignment [M] (works in background); or `runOpenPanelWith` returning URLs (needs a trusted click, i.e. app active) |
| `clipboard read/write` | Y | `NSPasteboard` (outside WebKit) |
| `exec` (raw agent-browser command) | **N** | No CDP endpoint exists. Replace with smthz's own command grammar; `agent-browser` cannot attach to WKWebView |

Totals (80 commands, counted per `path:` entry): **Y 56, P 23, N 1** (`exec`). Click/check/uncheck/hover/drag/dblclick/mouse move-down-up count as P because they are only trusted while smthz is active; the HTTPS-subresource gaps sit inside the P rows network/intercept/headers.

Pane features outside the CLI (overview.mdx, profiles.mdx, design-mode.mdx):

| Feature | WebKit | Note |
|---|---|---|
| Address bar, history, tabs, reopen closed, zoom, find, hard reload | Y | App-level + `reloadFromOrigin`, `pageZoom`, `find` [M] |
| Downloads shelf, site permissions | Y / P | Downloads [M]. Camera/mic via `requestMediaCapturePermissionFor` [D]. Geolocation/notifications have no public per-site delegate on macOS [D] |
| Link routing (terminal/markdown links -> pane or system browser) | Y | App logic |
| Viewport-size emulation | P | See `viewport` |
| Profiles + isolation | Y | [M] |
| Cookie import from Chrome/Edge | Y [U] | Same algorithm as Orca: copy the `Cookies` SQLite, Keychain `Chrome Safe Storage` (a system prompt asks the user), PBKDF2-SHA1 via CommonCrypto `CCKeyDerivationPBKDF`, AES-128-CBC `CCCrypt`, strip the 32-byte host hash on newer Chrome (`stripHmac` in `browser-cookie-decryption.ts`), then `setCookie`. Chrome is not installed here, so only the `setCookie` half was run [M] |
| Cookie import from Safari / Firefox | Y [U] | binarycookies parser (Full Disk Access, like Orca) / Firefox `cookies.sqlite` (plain) |
| Google sign-in | P [U] | Google blocks many embedded UAs; Orca's scoped-Firefox-UA trick is reproducible with `customUserAgent` but unverified |
| Passkeys (FIDO key account picker) | U | Not tested |
| DevTools | **P** | `isInspectable=true` -> Safari Web Inspector in a separate Safari window (needs Safari's Develop menu). **No in-pane DevTools and no DevTools settings pane** |
| Design mode | Y | JS overlay + computed style + cropped snapshot [M] |
| Remote/streamed browser for SSH workspaces | P [U] | "Browse through SSH host": `proxyConfigurations` with a SOCKS5 endpoint from `ssh -D` [U]. A server-hosted (streamed) page needs a Linux browser host, which does not exist |
| Share as artifact | depends on own services | Not a WebKit question |

### A.5 Functional reductions the user must accept (browser)

1. **R-B1 Background input is untrusted:** while smthz is not the active app, mouse/hover/drag automation uses JS events (`isTrusted=false`). Keyboard and wheel stay trusted. Orca's CDP input is always trusted.
2. **R-B2 Snapshot is a DOM/ARIA approximation**, not Chromium's computed accessibility tree. Ref names can differ on complex widgets and closed shadow DOM. Cross-origin iframes need per-frame injection.
3. **R-B3 Network capture:** no status/headers for HTTPS subresources not issued by page JS. No HAR-level fidelity.
4. **R-B4 Interception:** block and allow only for subresources. No pause/modify/continue (CDP `Fetch`) except for page fetch/XHR through a JS shim, which the page can detect.
5. **R-B5 Extra headers:** only on top-level loads smthz issues and page fetch/XHR, not on HTTPS subresources.
6. **R-B6 Device emulation:** no devicePixelRatio override and no touch emulation. Viewport, UA and zoom work.
7. **R-B7 Geolocation, offline and reduced-motion overrides are JS shims** visible to the page, not engine-level.
8. **R-B8 DevTools:** Safari Web Inspector in a separate window only. No embedded DevTools and no programmatic devtools.
9. **R-B9 `exec` passthrough to agent-browser is dropped.** smthz exposes its own command grammar.
10. **R-B10 Profile clone copies cookies only** (plus localStorage on visited origins). IndexedDB/cache are not cloned.
11. **R-B11 Server-hosted (streamed) remote browser** is not available until a Linux browser host exists. The local-render + SSH SOCKS route is the only remote mode.
12. **R-B12 Browser automation needs the smthz app running** (WKWebView lives in the app process, not `smthzd`). Orca has the same constraint with Electron, so this is not a new reduction, but `smthz browser ...` must return a clear "app not running" error.

Explicitly **not** recommended: a MITM root CA for HTTPS capture. It would need a user-trusted certificate and is a security risk.

### A.6 Architecture for smthz (design)

- **Process placement:** `WKWebView` must live in the app (AppKit main thread). The app registers with `smthzd` as the **browser provider** over the existing Unix socket. The CLI calls `smthz browser <cmd>` -> host RPC `browser.*` -> the host forwards to the provider -> the reply is journaled like other RPCs. Background tabs (not in any visible pane) are kept in one off-screen window: rendering, JS, keyboard, wheel and snapshots all work there [M].
- **Injected runtime:** one JS bundle (snapshot/ref map, fill/select helpers, console/fetch/XHR shims, design-mode overlay, waits) injected at documentStart into `WKContentWorld("smthz")` for all frames. Refs are a `Map<String, WeakRef<Element>>` in that world [M], so they are invisible to the page.
- **Input policy:** if `NSApp.isActive && window.isKeyWindow`, send native events; otherwise use JS fallback for pointer and native for keys/wheel. The response reports `trusted: true/false` so agents know.
- **Focus guard:** typing needs the web view as first responder; save and restore the previous first responder (terminal pane) around each command.
- **PDF:** never call `NSPrintOperation.run()` on the main thread; use `runModal(for:)` or `pdf(configuration:)`.

### A.7 Browser WP specs (refine PARITY-AUDIT WP 19-20)

Disjoint scopes; B1 and B2 can run in parallel; B3 after B1/B2; B4 after B3; B5 after B4.

| WP | Scope (files) | Acceptance | Tests | Effort |
|---|---|---|---|---|
| **B1 BROWSER-PANE** | new `Sources/SmthzApp/Browser/{BrowserPaneView,BrowserTabModel,BrowserToolbar,BrowserDownloadsShelf,BrowserDialogs,BrowserFind}.swift`; one hook line in the pane-host file named by the coordinator | Browser tab type in the tab strip; address bar with search fallback; back/forward/reload/hard reload; ⌘F find; zoom; popups open as tabs; downloads shelf (open/reveal/cancel); alert/confirm/prompt sheets; HTTP auth sheet; file upload panel; `isInspectable` toggle | Manual checklist + screenshot; unit tests for URL/search normalisation in SmthzCore (`BrowserURLInput.swift`) | 8 wd |
| **B2 BROWSER-PROFILES** | new `Sources/SmthzCore/Browser/{BrowserProfileStore,BrowserCookieImportChrome,BrowserCookieImportSafari,BrowserCookieImportFirefox,ChromiumCookieCrypto}.swift` + tests | Profile registry (id, label, data store UUID) persisted in the state dir; create/delete (deferred until views close)/default; cookie import from Chrome/Edge/Firefox/Safari into `HTTPCookie` values excluding Google domains; decrypt pipeline uses CommonCrypto only | Fixture SQLite DBs with known plaintext encrypted by the test itself (v10, with and without host-hash prefix); binarycookies fixture; no real Keychain access in tests | 5 wd |
| **B3 BROWSER-RPC+CLI** | new `Sources/SmthzCore/Browser/BrowserAutomationProtocol.swift` (Codable requests/results for every row in §A.4); `HostService`/`HostClient` `browser.*` forwarding + provider registration; new `Sources/smthz/BrowserCommands.swift` + dispatch lines in `Sources/smthz/main.swift` | `smthz browser <cmd>` for all 80 Orca commands (Y and P rows), `exec` returns `unsupported`; "app not running" error; idempotent request ids | Protocol round-trip tests; host forwarding test with a fake provider; CLI parse tests | 5 wd |
| **B4 BROWSER-AUTOMATION** | new `Sources/SmthzApp/Browser/Automation/*` (+ `Resources/browser-runtime.js`) | App executor for every B3 request; input policy and focus guard (§A.6); full-page screenshot by resize; capture buffers (console 1000 entries, network 500) | Local-server e2e harness run by the coordinator (like `wkprobe`), asserting each §A.3 row; JS unit tests not required | 10 wd |
| **B5 DESIGN-MODE** | new `Sources/SmthzApp/Browser/DesignMode/*` | Toggle picker overlay; click -> HTML + computed style + cropped PNG attached into the active agent terminal (paste as file path) | Manual + e2e harness row | 3 wd |

---

## Part B: agent control paths

### B.1 How Orca does it [C]

- **Roster:** 47 ids (`R/src/shared/tui-agent.ts`). Per-agent config in `R/src/shared/tui-agent-config.ts` (381 lines) covers `detectCmd`, `launchCmd`, `expectedProcess`, `promptInjectionMode` (`argv` | `stdin-after-start` | ...), `draftPromptFlag` (`claude --prefill`), `preflightTrust`, paste-ready signals and timeouts. Permission presets are in `R/src/shared/tui-agent-permissions.ts`: claude `--permission-mode auto` / `--dangerously-skip-permissions`; codex `--approve-for-me` / `--dangerously-bypass-approvals-and-sandbox`. Version probe: `R/src/main/agent-cli-version-probe.ts`. Workspace trust preflight: `agent-workspace-trust*.ts`, `agent-trust-presets.ts`.
- **Status:** two channels into one store (`R/src/main/agent-hooks/README.md`):
  1. **Managed hooks** POST to a loopback HTTP server with a token header (`hook-post-command.ts`: `curl -X POST http://127.0.0.1:$ORCA_AGENT_HOOK_PORT/hook/<agent>`, env `ORCA_PANE_KEY`, `ORCA_TAB_ID`, `ORCA_AGENT_LAUNCH_TOKEN`, `ORCA_WORKTREE_ID`). Claude events: SessionStart, UserPromptSubmit, Stop, StopFailure, SubagentStart/Stop, TeammateIdle, Pre/PostToolUse(+Failure), PermissionRequest, PostCompact, SessionEnd (`claude/claude-managed-hook-events.ts`). Orca writes them into the user's `~/.claude/settings.json` (`claude/hook-settings.ts:50`). Codex: `~/.codex/hooks.json` plus hook **trust hashes in `config.toml`** (`codex/codex-real-home-hooks-json.ts`, `codex/codex-hook-system-trust.ts`).
  2. **OSC 7501 Program Status Protocol** read from PTY output. The terminal must answer `ESC]7501;?` with `ESC]7501;?:states=idle,working,done,blocked,error:kinds=permission,question,auth ESC\` (`R/src/shared/program-status/protocol.ts:10-18`, `query-responder.ts`). Claude Code (>=2.1.295), Grok, pi, omp and Codex (state only) emit it. Precedence: hooks win, OSC fills gaps (`server/program-status/hook-precedence.ts`).
- **Native chat:**
  - Default Chat UI is a structured view **over the PTY**: transcript decoders for Claude/Codex/Grok/OMP JSONL (`native-chat/transcript-line-decoders-*.ts`), with the composer delivering into the same PTY (`docs/.../agents/native-chat.mdx`).
  - Structured sessions use the Claude Agent SDK (`@anthropic-ai/claude-agent-sdk 0.3.284`, `claude/claude-stream-json-connection.ts`, `--permission-prompt-tool stdio` and `can_use_tool`), the Codex app-server (`codex/codex-app-server-*.ts`) and ACP (`acp/*`, dialects: grok, omp, opencode, antigravity).
- **Accounts:** Claude per-account `CLAUDE_CONFIG_DIR` (`claude-accounts/claude-account-folder.ts:39`), Keychain service `Claude Code-credentials` (`claude-accounts/keychain.ts:7`). Codex per-account managed `CODEX_HOME` (`codex-accounts/runtime-home-service*.ts`).

### B.2 Experiments [M]

All experiments ran in `/tmp/smthz-exp-opus-browser/agents/work` (deleted). A 60-line Python stdio driver stood in for any non-Node client. No model turn was sent, so no tokens were spent.

1. **Claude per-launch hooks without touching user settings.** `claude -p --input-format stream-json --output-format stream-json --verbose --settings '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"cat > …/hook-SessionStart.json"}]}]}}'` plus one `control_request {subtype:"initialize"}`:
   - The SessionStart hook fired 0.43 s after spawn. The payload contained `session_id`, `transcript_path` (`~/.claude/projects/<cwd-slug>/<id>.jsonl`), `cwd`, `hook_event_name`, `source:"startup"`.
   - The user's existing global hook (Orca's managed one, which prints `{}`) **also** ran. `--settings` hooks are **merged with** the user's hooks, not substituted for them.
   - The stream also carries `system/hook_started` and `system/hook_response` events.
2. **Claude stream-json control protocol without the SDK.** `control_response` to `initialize` arrived in 0.45-0.75 s. Keys: `account` (email/org/plan, not copied here), `agents`(5), `commands`(71), `models`(13, with `supportsEffort`), `current_permission_mode`, `claude_code_version` "2.1.308", `pid`, `session_state` "idle", `capabilities`, output styles, fast mode and remote-control flags. With `--permission-prompt-tool stdio` the handshake is identical. `can_use_tool` round-trips were **not** exercised because that needs a model turn [U].
3. **Codex app-server.** `codex app-server`, then `initialize` (clientInfo), `initialized`, `model/list`:
   - `initialize` returned in 0.02 s with `userAgent`, `codexHome`, `platformOs`. Observation: the server's user agent string contained a leftover `Orca/1.4.229` token from this machine's Codex config.
   - Unsolicited `remoteControl/status/changed` notification.
   - `model/list` returned models with `supportedReasoningEfforts`.
   - `codex app-server generate-json-schema` emits the full protocol (39 files): **106 client requests** (`thread/start|resume|fork`, `turn/start|steer|interrupt`, `account/*`, `fs/*`, `skills/list`, `hooks/list`, `review/start`, `command/exec`...), **10 server->client requests** (`item/commandExecution/requestApproval`, `item/fileChange/requestApproval`, `item/tool/requestUserInput`, `item/permissions/requestApproval`, `mcpServer/elicitation/request`, ...), **85 notifications** (`item/agentMessage/delta`, `turn/started|completed`, `thread/tokenUsage/updated`, `account/rateLimits/updated`, ...).
   - The CLI labels app-server `[experimental]`.
4. **Hook transport cost.** `smthz --version` (debug build) runs in about 0.01 s real, so a hook can invoke `smthz hook` directly instead of curl + an HTTP server.

### B.3 Design: launching TUI agents in PTY tabs

- **Catalog (SmthzCore, pure data):** port `TuiAgentConfig` fields for all 47 ids (detect/launch/expectedProcess/promptInjectionMode/draftPromptFlag/permission presets/trust kind), with Orca file citations as comments. Detection resolves `detectCmd` against the **session PATH** from `SessionEnvironment` (not the app's launchd PATH), then runs `--version` with a 3 s timeout off the main thread.
- **Launch (host-owned):** new RPC `agent.launch {agent, cwd, prompt?, mode: draft|submit, permission: default|auto|bypass, extraArgs, accountId?}`. The host builds argv/env, creates the session through the existing `SessionManager.create` path, and returns the session id. Prompt delivery:
  - `argv`: claude/codex take the prompt as an argument.
  - `draft`: `claude --prefill <text>`.
  - `stdin-after-start`: write after the PTY's first quiet period (500 ms without output, cap 20 s), mirroring Orca's `draftPasteReadyTimeoutMs`.
- **Env per launch:** `SMTHZ_SESSION_ID`, `SMTHZ_SOCKET`, `SMTHZ_AGENT_ID`, `SMTHZ_LAUNCH_TOKEN`, and `SMTHZ_HOOK_TOKEN`: a **scoped** token that authorises only `agent.hook` for this session, never the host capability token.
- **Trust preflight:** Orca pre-accepts the workspace trust dialog by writing the agent's user config [C]. Default for smthz: **off**, so the agent shows its own trust prompt in the PTY. This needs a user decision (U-B2).
- **CLI:** `smthz agent list` (detected roster + versions), `smthz agent launch --agent claude --cwd . [--prompt …] [--draft] [--permission auto]`.

### B.4 Design: status hooks

- **Claude:** inject per launch with `--settings <state-dir>/hooks/claude.json` [M]. Claude-compatible agents (openclaude, qoder, qoder-cn, qwen, codebuddy) use their own `.claude`-style settings dirs (`claude/hook-settings.ts:26` [C]); whether each accepts `--settings` is unverified [U], and the fallback is Orca's settings-file edit under U-B2. The file maps the 13 Orca events to the command `smthz hook --agent claude`. **No global file edits.** The user's own hooks keep running [M]. The hook script must print `{}` on stdout because permission hooks fail closed on empty stdout (`claude/hook-script.ts`, issue #14818 [C]).
- **Codex:** no per-launch hook flag was found in `codex --help` [M]. Orca's route is `~/.codex/hooks.json` + trust hash entries in `~/.codex/config.toml` [C]. Offer it as an opt-in "Install Codex status hooks" action (U-B2). Without it, rely on OSC 7501 (Codex sends it without a probe, state only [C]).
- **Others:** OSC 7501 where emitted [C]; title-based activity as the last fallback (Orca `createAgentStatusTracker` [C]).
- **Ingest:**
  - `smthz hook --agent <id>` reads the stdin JSON payload (≤ 1 MiB), adds env metadata and sends RPC `agent.hook` with the scoped token. It exits 0 within 1.5 s whatever happens (Orca's curl uses `--max-time 1.5`).
  - The host maps events to `idle | working | blocked(kind) | done | error`, keeps the tool name/input preview, prompt, `session_id` and `transcript_path`, and publishes through `agent.status.list` and the existing `session.subscribe` stream (or a new `agent.status.subscribe`).
- **OSC 7501 in the host:** a stateful scanner on PTY output in `SessionManager` (it must survive split sequences, max 4096 bytes [C]). When it sees `ESC]7501;?` it writes the reply into the PTY input. Doing this host-side makes status work without the app attached. During `session.replay` it must **not** reply (Orca's `shouldReply` guard [C]).
- **Precedence:** a hook event owns the row; OSC fills in when hooks are absent or silent for 2 minutes on a state the program left [C].

### B.5 Native chat: go/no-go per path

| Path | Protocol | Node needed? | Evidence | Verdict | Effort |
|---|---|---|---|---|---|
| **Chat-over-PTY (transcript view)**: read the agent's JSONL transcript, composer writes into the PTY | Claude `~/.claude/projects/*.jsonl` (path delivered by the SessionStart hook [M]); Codex rollout files [C] | No | Hook gives `transcript_path` [M]; decoders in `native-chat/transcript-line-decoders-{claude,codex}.ts` [C] | **GO first.** Lowest risk; the terminal stays the source of truth (Orca's default Chat UI) | 5 wd |
| **Codex structured** | `codex app-server` JSON-RPC over stdio | No | Handshake + `model/list` [M]; schema generator -> Swift Codable codegen | **GO.** Pin a Codex version range; regenerate types per release (protocol is `[experimental]`) | 8 wd |
| **Claude structured** | `claude -p --input-format stream-json --output-format stream-json --permission-prompt-tool stdio` + `control_request`/`control_response` | Not required [M] (the SDK is a wrapper around this stdio protocol); optional Node sidecar | `initialize` handshake [M]; `can_use_tool` [U] | **Conditional GO:** U-B3 decides Swift-native (smaller, no Node, tracks an undocumented wire contract) vs an isolated Node sidecar running `@anthropic-ai/claude-agent-sdk` (official API, needs a bundled Node runtime, which the project rules allow only for isolated, justified adapters) | 8 wd (+3 for sidecar) |
| **ACP** (grok, omp, opencode, antigravity) | JSON-RPC 2.0 over stdio, public spec | No | Not runnable here (no ACP agent installed) [U]; Orca dialects in `acp/acp-dialects/*` [C] | **GO later**, behind roster detection; test against a fake agent fixture | 6 wd |

**Common pieces for structured chat:**
- **Process supervision:** reuse the PTY session machinery but with pipes. Process-group kill and an exit-proof check like Orca's `claude-child-exit-proof-ladder.ts`.
- **Permissions UI:** the server request (`can_use_tool` / `item/*/requestApproval`) becomes a SwiftUI card with allow once / always / deny, with a timeout that defaults to deny.
- **Questions:** `AskUserQuestion` / `item/tool/requestUserInput` cards.
- **Attachments:** images become base64 content blocks.
- **Auth:** never read tokens; each agent CLI owns its credentials. Accounts mean pointing `CLAUDE_CONFIG_DIR` / `CODEX_HOME` at per-account dirs; login runs the CLI's own login in a PTY tab.
- **Journal:** chat events go to the host EventJournal so the app can reconnect.

### B.6 Reductions and decisions (agents)

- **R-A1** Codex status hooks need an opt-in global edit (`~/.codex/hooks.json` + `config.toml` trust). Without it, Codex shows state only (OSC 7501) with no tool/prompt previews.
- **R-A2** Workspace-trust preflight is off by default. Agents show their own trust prompt on first launch in a folder (Orca auto-accepts).
- **R-A3** Native chat ships in stages: transcript view first, Codex structured next, Claude structured after U-B3, ACP last. Grok/OMP transcript decoders, Claude Agent Teams (`orca claude-teams`, tmux shim) and rewind (which Orca does through the SDK, `claude/claude-rewind-transcript.ts`) are deferred.
- **R-A4** Only claude and codex can be verified on this machine. The other 45 roster entries are ported from Orca's config without live verification.

User decisions requested (also listed in §C):
- **U-B1** Accept browser reductions R-B1..R-B12.
- **U-B2** May smthz edit agents' global config (Codex hooks/trust, workspace-trust preflight), or only per-launch flags?
- **U-B3** Claude structured chat: Swift-native stream-json client (recommended, no Node) or an isolated Node sidecar with the official SDK?

### B.7 Agent WP specs (worker-ready)

Order: **AG1 ‖ AG3a** (pure SmthzCore, disjoint) -> **AG2** (owns HostService/HostClient/CLI main) -> **AG3b** (RPC wiring) -> **AG4** (app UI) -> CHAT0 -> CHAT1 -> CHAT2/3.

**AG1 AGENT-ROSTER (3 wd)**
- Scope: new `Sources/SmthzCore/Agents/AgentCatalog.swift`, `AgentDetection.swift`, `Tests/SmthzCoreTests/AgentCatalogTests.swift`, `AgentDetectionTests.swift`. Nothing else.
- Content: `AgentID` enum with the 47 ids and display names (`R/src/shared/tui-agent.ts`, `tui-agent-display-names.ts`); `AgentConfig` (detect/launch/expectedProcess/promptInjectionMode/draftPromptFlag/permissionArgs auto+bypass/trustKind) from `tui-agent-config.ts` + `tui-agent-permissions.ts`; `AgentDetector.detect(path:) async -> [DetectedAgent(id, executable, version?)]` with a 3 s version timeout and concurrency ≤ 4.
- Acceptance: all 47 ids present with non-empty detectCmd; claude/codex configs equal Orca's values; detection finds fake executables in a temp PATH dir and parses `x.y.z` from `--version`; a hanging fake binary is killed at the timeout; no zombie processes.
- Tests: ≥ 10 `@Test`s; fake binaries are shell scripts in a temp dir.

**AG3a AGENT-STATUS-CORE (4 wd)**
- Scope: new `Sources/SmthzCore/Agents/ProgramStatusScanner.swift`, `AgentStatusStore.swift`, `AgentHookPayload.swift`, `ClaudeHookSettings.swift`, matching tests. Nothing else.
- Content: OSC 7501 scanner (stateful across chunks, 4096-byte cap, emits records and `queryDetected`; reply constant per `protocol.ts`); hook payload decoding for the Claude and Codex event names (§B.1); status store with precedence (hook > OSC, 2-minute silence rule) and states `idle/working/blocked(kind)/done/error`; `ClaudeHookSettings.json(command:)` producing the `--settings` file for the 13 events.
- Acceptance: scanner handles splits at every byte offset of a sample stream; replay mode suppresses replies; store transitions are table-tested; the generated settings JSON parses and lists every event with matcher `*` for tool events.

**AG2 AGENT-LAUNCH (4 wd, after AG1)**
- Scope: new `Sources/SmthzCore/Agents/AgentLaunch.swift`; `HostService.swift` + `HostClient.swift` (only the `agent.launch` and `agent.list` cases and client methods); new `Sources/smthz/AgentCommands.swift` + dispatch lines in `Sources/smthz/main.swift`; `Tests/SmthzCoreTests/AgentLaunchTests.swift`.
- Content: argv/env builder (§B.3), scoped hook token minted per launch and stored in host memory, prompt delivery modes, `--settings` injection for the Claude family (writes `<state-dir>/hooks/claude-<launch>.json` with mode 0600).
- Acceptance:
  - `smthz agent list` prints detected agents.
  - `smthz agent launch --agent claude --cwd <dir> --draft --prompt hi` creates a session whose `ps` argv shows `--prefill hi` and `--settings`.
  - A fake agent in tests receives the prompt in argv or through stdin after a quiet period.
  - Launch is idempotent per request id.
  - The coordinator e2e with real `smthzd`: launch `claude`, then `ps` shows the process on a tty; close leaves no strays.

**AG3b AGENT-HOOK-RPC (3 wd, after AG2 + AG3a)**
- Scope: `HostService.swift`/`HostClient.swift` (only `agent.hook`, `agent.status.list`, status subscribe); `SessionManager.swift` (only: run the scanner on output, write the query reply into input unless replaying); new `Sources/smthz/HookCommand.swift` + dispatch line; tests `AgentHookRPCTests.swift`.
- Acceptance:
  - `smthz hook --agent claude < payload.json` with the env from a launched session updates `agent.status.list` within 200 ms.
  - A wrong or missing token is rejected and the command still exits 0 within 1.5 s.
  - Printing `ESC]7501;?` in a session yields the reply bytes on its input.
  - Coordinator e2e: launching real `claude` in a temp dir -> a SessionStart row appears with `transcript_path`.

**AG4 AGENT-UI (4 wd, after AG3b)**
- Scope: `Sources/SmthzApp/RightSidebar/AgentsPanel.swift`, new `Sources/SmthzApp/Agents/*` (launcher menu/sheet, status badge view, restart chip), and the hook lines named by the coordinator in the tab item and sidebar card views.
- Acceptance: "New agent" menu lists detected agents; tab and workspace badges show working/blocked/done; the Agents panel lists live rows with last tool and prompt; the restart chip appears when the agent process exits; screenshots in light and dark mode.

**CHAT0 TRANSCRIPT VIEW (5 wd)**
- Scope: new `Sources/SmthzCore/Chat/Transcript{Reader,ClaudeDecoder,CodexDecoder}.swift` + tests with fixture JSONL; new `Sources/SmthzApp/Chat/*`.
- Acceptance: incremental tail of a growing JSONL (no re-read); user/assistant/tool blocks rendered; the composer writes into the PTY; Chat/Terminal toggle per agent tab.

**CHAT1 CODEX STRUCTURED (8 wd)**
- Scope: new `Sources/SmthzCore/Chat/Codex/*` (types generated from `codex app-server generate-json-schema`, plus a checked-in generator script under `scripts/`), app chat surface reuse.
- Acceptance: initialize, `thread/start`, `turn/start`, delta streaming, approvals card, interrupt, resume; a fake app-server fixture for tests; one live coordinator run (costs tokens, so it needs the user's OK).

**CHAT2 CLAUDE STRUCTURED (8 wd, after U-B3)** and **CHAT3 ACP (6 wd)**: same shape; fixtures recorded from real CLIs; a version gate refuses unknown major protocol changes.

---

## C. Decisions for the user (summary)

1. **U-B1**: accept browser reductions R-B1..R-B12 (§A.5).
2. **U-B2**: allow opt-in edits of agents' global config (Codex hooks.json/config.toml trust, workspace-trust preflight), or per-launch only (R-A1, R-A2).
3. **U-B3**: Claude structured chat via a Swift-native stream-json client (recommended) or an isolated Node sidecar with the official Agent SDK.
4. Live tests that spend model tokens (CHAT1/CHAT2 acceptance) need the user's OK.

## D. Hygiene notes

- Scratch dir `/tmp/smthz-exp-opus-browser` and its test servers were deleted after the run. The first scratch name `/tmp/smthz-exp-opus` collided with another worker's experiment dir (it wiped this worker's files mid-run). Future briefs should use `/tmp/smthz-exp-<wp-id>`.
- The probe's agent experiments created no files under `~/.claude/projects` (checked) and started no Codex thread.
- `NSPrintOperation.run()` on the main thread hangs a WKWebView app; any worker touching printing must use `runModal(for:)`.

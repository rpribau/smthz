# Editor engine experiment (WP-M1-EDITOR)

Status: research + throwaway prototypes, 2026-10-31. Author: Opus 5.5 worker (task_d211fcde029f).
Scope: choose the engine behind smthz's file editor, markdown editor, viewers and diff views, with measurements.
No product code was written. The prototypes lived in `/tmp/smthz-exp-opus-editor` and were deleted afterwards; the relevant code is summarised in the appendix.
This is PARITY-AUDIT WP 10. The audit called the output `docs/EDITOR-ENGINE.md`; the dispatch brief named this file, so this file is the deliverable.

## 1. Decision for the user (TL;DR)

**Recommendation: option (b), Monaco 0.55.1 bundled locally inside a `WKWebView`.** The renderer is isolated and served by a `WKURLSchemeHandler`; file state, saving and conflict detection stay in Swift. This is the only option that reaches Orca's editor feature set without a reduction: Orca itself is Monaco 0.55.1 (`reference/orca-1.4.238/package.json`: `"monaco-editor": "^0.55.1"`). Its per-frame cost on code files (about 0.3 ms per scroll render, under 1 ms per keystroke) matched the best native option.

- **Cost:** about 250 MB (plaintext) to 630 MB (TypeScript with the TS worker loaded) of WebContent memory per editor web view at 1–2 MB files. Add about 100 MB for the WebKit GPU process. The bundle grows by about 14 MB (or about 4–5 MB if language workers are dropped).
- **Rejected as the primary engine:**
  - **(a) TextKit 2 `NSTextView` + tree-sitter.** It is excellent on normal wrapped code files. It collapses on very long lines and in no-wrap mode (86 ms per keystroke, 3–18 GB footprint). It has no multi-cursor, minimap or diff editor, so each of those must be built.
  - **(c) Swift packages.** STTextView is GPL-3.0 or commercial and Runestone is iOS-only, so both are out.
- **Native alternative: CodeEditSourceEditor (MIT, part of option c).** It is the fastest and leanest option measured: open 65–72 ms, typing under 1 ms, about 84–124 MB, with multi-cursor, minimap, folding and regex find/replace. Against it:
  - no diff editor, and only about 37 languages;
  - it hangs on a 1 MB single-line file;
  - it needed packaging workarounds;
  - its grammar bundle (CodeEditLanguages) has no licence file.
- **Decision needed from the user (D-EDITOR-1).** Accept option (b), a WebKit-hosted Monaco editor, as the smthz editor engine. It is the 1:1 path. The alternative is option (c), CodeEditSourceEditor. It is native, with about 4–6× less memory, but it is a functional reduction (diff editor, changes view, combined diff, language breadth, long-line safety) until about 4–5 extra work packages are built. Option (a), plain TextKit 2, would need about 6–9 work packages (multi-cursor, minimap, diff editor, combined diff, language breadth, long-line handling) before parity. Either way the markdown rich editor (Orca uses Tiptap/ProseMirror) is a second, separate decision (D-EDITOR-2, §8).

## 2. What Orca's editor does (reference inventory)

Sources: `reference/orca-1.4.238/docs/site/content/docs/editing/{monaco,markdown,viewers,file-explorer}.mdx`, `src/renderer/src/components/editor/` (798 files), `src/renderer/src/lib/monaco-setup.ts`, `src/shared/constants.ts`.

| Area | Orca behaviour | Source |
|---|---|---|
| Engine | Monaco 0.55.1 via `@monaco-editor/react` 4.7, plus `shiki` 4.5 / `vscode-oniguruma` for extra TextMate grammars | `package.json`, `lib/monaco-languages/textmate-*` |
| Languages | Monaco built-ins (91 language ids measured in 0.55.1) plus Astro, JSONL, Nim, Quarto, Svelte, Typst, Vue, shell/markdown aliases, Solidity | `lib/monaco-languages/register-*.ts` |
| Language services | TS/JS diagnostics deliberately **off** (semantic, syntax, suggestions); tokenization kept; JSX preserve | `lib/monaco-setup.ts:46-80` |
| Autosave | On blur and after idle; default delay 1000 ms (`DEFAULT_EDITOR_AUTO_SAVE_DELAY_MS`); hold backstop 120 s | `shared/constants.ts:73`, `editor-autosave-holds.ts:82` |
| Conflict-safe writes | Saves carry a disk precondition; `blocked-stale` outcome; banner with compare/reload/overwrite; watcher reload coalescing; restored-tab conflict scan; non-UTF-8 autosave pause | `editor-save-disk-precondition.ts`, `editor-watcher-reload-coalescer.ts`, `editor-restored-tab-conflict-scan.ts`, `editor-non-utf8-autosave-pause.ts` |
| Large paste | Direct paste ≤ 64 KiB, chunked 16 KiB, cap 16 MiB | `monaco-large-text-paste.ts:9-11` |
| Find / go-to | Cmd-F (seeded from selection), Cmd-Shift-F worktree search, Cmd-D next occurrence, go-to-line, Cmd-Click definition where supported | `monaco.mdx`, `monaco-find-*.ts`, `monaco-codebase-search.ts` |
| Multi-cursor | Monaco native | `monaco.mdx` |
| Word wrap | On by default, Alt-Z toggle; separate diff word wrap | `monaco.mdx`, `diff-editor-word-wrap-options.ts` |
| Minimap | Optional, off by default (Settings → Appearance); diff editor forces it off | `MonacoEditor.tsx:287-288` |
| Font | Editor font follows the terminal font unless overridden | `monaco.mdx`, `MonacoEditor.font-family.test.tsx` |
| Changes view | In-tab HEAD-vs-working-tree diff toggle keeping cursor | `ChangesModeView.tsx` |
| Diff editor | Monaco DiffEditor: side-by-side/inline, hide unchanged regions, whitespace toggle, line numbers, word wrap, large-diff load prompt and fallback | `diff-editor-*.ts`, `LargeDiffLoadPrompt.tsx` |
| Combined diff | Multi-file review surface with on-demand section loading, height cache, comments | `combined-diff/`, `diff-section-*.ts`, `diff-comments/` |
| Conflict review | Merge-conflict decorations and review tree | `monaco-conflict-decorations.ts`, `EditorConflictReviewSurface.tsx` |
| View state | Per-tab view state retention, closed-tab model lifetime | `monaco-view-state-persistence.ts`, `closed-editor-*.ts` |
| Markdown | Rich editor (Tiptap 3.31 / ProseMirror: slash menu, `[[` links, tables, toggles as `<details>`, front matter, TOC, review annotations, KaTeX, lowlight code blocks, Mermaid), raw Monaco toggle Cmd-Shift-M, raw-first above 300 KB; 175 `rich-markdown*`/`RichMarkdown*` files | `markdown.mdx`, `package.json` (`@tiptap/*`, `katex`, `lowlight`, `mermaid`) |
| Viewers | HTML (sandboxed browser tab), Mermaid (`.mmd` pan/zoom), PDF (pdf.js 6.3, position restore), images (+ image diff), CSV/TSV table, Jupyter notebook (beta) | `viewers.mdx`, `ImageDiffViewer.tsx`, `csv/` |

## 3. Method

- Machine: Apple M5 Pro (15 cores), 24 GB, macOS 26.6. Toolchain: Xcode 27.1 (`DEVELOPER_DIR`), Swift 6.4, release builds, own `--scratch-path`. Other workers were building at the same time, so treat absolute numbers as ±30 %. The comparisons between options are the signal.
- Corpus (real code, concatenated non-test `.ts` from `reference/orca-1.4.238/src`):
  - `1mb.ts`: 1,048,576 bytes, 28,186 lines.
  - `50k.ts`: 50,000 lines, 1.85 MB, longest line 396 chars.
  - Stress: `1mb-oneline.json`: 1.05 MB on one line (minified JSON).
- Window 1200×800 pt, 13 pt monospaced font, word wrap **on** (Orca's default) unless stated "nowrap".
- Native measurements (TextKit 2, CodeEditSourceEditor) are synchronous CPU time inside the app process:
  - **open**: read file, create view, assign text, `window.displayIfNeeded()`.
  - **scroll step**: move the clip view 60 pt, then `displayIfNeeded()`; 300 steps.
  - **random jump**: 30 jumps to random offsets.
  - **typing**: insert one character in the middle of the document, then display; 100 times.
  - **memory**: `phys_footprint` delta of the app process (`task_info(TASK_VM_INFO)`).
- Monaco measurements:
  - **boot**: `WKWebView.load` until the AMD loader has loaded `editor.main` and the editor exists.
  - **open**: Swift `callAsyncJavaScript(bench.open(text))`, which transfers the 1 MB string over the bridge and creates the model, until 2 `requestAnimationFrame`s.
  - **sync render cost**: `setScrollTop(y); editor.render(true)` or `trigger('type'); editor.render(true)`, averaged over 300/100 iterations. WebKit clamps `performance.now()` to about 1 ms, so only averages are meaningful.
  - **rAF interval**: frame pacing, about 14 ms. It shows that the display link is never missed, not the cost.
  - **memory**: `footprint -p` of the new `com.apple.WebKit.WebContent` and `com.apple.WebKit.GPU` processes plus the app delta.
- The configuration mirrors Orca: TS diagnostics are off as in `monaco-setup.ts`, workers are mapped by label as in Orca's `getWorker`, and the minimap is off unless stated.
- Not measured, marked **unverified** below: real keyboard-to-photon latency, VoiceOver sessions, interactive IME with a real input method, Liquid Glass compositing over the editor, and Instruments hitch rate.

## 4. Results

### 4.1 Numbers

All times in ms, memory in MB. p50/p95 shown as `p50 / p95`.

| Metric | TextKit 2 `NSTextView` + tree-sitter | Monaco 0.55.1 in WKWebView | CodeEditSourceEditor 0.15.2 |
|---|---|---|---|
| Cold start of the engine | 0 (in-process) | **225–240** boot (WebContent spawn + loader); amortised by pre-warming one web view | 0 (in-process) |
| Open 1mb.ts to first paint | **21–27** | 76–108 (incl. 1 MB bridge transfer; model 9–10, first frames 48–71) | **65–69** (view sized first, then `setText`); **6,386** if the string is passed to `init` before the view has a frame (eager layout of all lines) |
| Open 50k.ts | **26** | 102 | 72 (late `setText`); 22,607 (string in `init`) |
| Scroll step 1mb.ts | 0.62 / 0.70 | **0.28 avg** sync render; rAF 14 / 15 (no missed frames) | 0.29–0.31 / 0.64–0.82 |
| Scroll step 50k.ts | 0.69 / 0.92 | 0.27 avg; rAF 14 / 15 | 0.31 / 0.83 |
| Random jump 50k.ts | 3.9 / 7.5 | 1.5 avg sync render | 1.7 / 6.5 |
| Typing 1mb.ts (char + display) | 3.1 / 4.0 (+ 6.8 / 7.5 tree-sitter incremental reparse, naive full UTF-16 copy) | **0.84 avg** incl. tokenization | 0.83 / 0.87 (sync part; re-highlight runs async) |
| Typing 50k.ts | 3.2 / 3.7 (+ 13.8 / 16.2 reparse) | **0.72 avg** | 0.34 / 0.76 |
| **50k.ts nowrap** open / jump / typing | **602 / 760 p50 (1441 p95) / 86 p50 (251 p95)**; no highlight: 700 / 375 / 86 | 76 / 1.6 avg / 0.91 avg | 72 / 1.6 p50 (5.9 p95) / 0.88 p50 |
| **1 MB single line** open / scroll / typing | 79 / 8.6 / **872 p50 (1005 p95)**; no highlight: 73 / 3.0 / **55** | 83 / **27.6 avg** / 10 avg (rAF 34 / 56: visibly janky) | **hangs**: main thread blocked > 90 s in `TreeSitterState.parseDocument` → `Parser.parse` (sampled), killed |
| Highlighting, 1mb.ts | tree-sitter full parse 47–55, full query 175–199 (132k captures), apply-all 68–78; viewport-only 3.7–6.2 | Monarch tokenizer, lazy per viewport (no up-front cost) | tree-sitter, async; first colour after 380 ms (1mb.ts), 664 ms (50k.ts), 12–22 ms (small files) |
| Memory, 1mb.ts (after open / final) | +6 / **+180–192** (all-document colour attributes + layout) | app +23; WebContent **467** (TS) / **249** (plaintext); GPU 107–112 | +25 / **+84** |
| Memory, 50k.ts | +9 / +220 | WebContent 633; GPU 110 | +35 / +124 |
| Memory, pathological | nowrap 50k: 2.97 GB (no highlight) – 6.3 GB; one-line: 3.6 GB (no highlight) – **18 GB** | one-line: WebContent 994 | eager-init path: 1.2 GB (1mb) / 2.3 GB (50k); one-line: not reached |
| Memory idle (2-line file) | +7 | WebContent 174 (plaintext) / 301 (TS worker); GPU 91–109 | +17 |
| Minimap on (1mb.ts) | n/a (must be built) | scroll 0.36 avg, typing 1.03 avg, WebContent 515 | minimap is on by default; with it: scroll 0.31, typing 0.85, +84 MB (no measurable cost) |
| Find all "const " | 4.3–8.3 (NSString scan) | 1–2 (`findMatches`, capped at 999 results by the default limit) | built-in find panel |

### 4.2 Capability probes (programmatic, in the prototypes)

| Probe | TextKit 2 NSTextView | Monaco | CodeEditSourceEditor |
|---|---|---|---|
| Is TextKit 2 active | yes (`textLayoutManager != nil`) | n/a | own line-virtualised layout (CodeEditTextView, CoreText line typesetting; not TextKit 2) |
| Multi-cursor: two carets, type "Z" | **0 chars inserted** (NSTextView ignores typing with discontiguous selections) | **2 inserted** | **2 inserted** |
| IME marked text (`setMarkedText`) | yes | not probed (WebKit composition events; Monaco handles `compositionstart/end`; **unverified** interactively) | yes |
| Accessibility | `AXTextArea`, full value (1,046,219 chars) | hidden `textarea` input area present; VoiceOver behaviour **unverified** | `AXTextArea`, full value |
| Built-in find/replace UI | yes (`usesFindBar`, incremental) | yes (find widget, regex/case/word, replace) | yes (find panel with replace; contains/word/prefix/suffix/regex) |
| Go-to-line action | must build | yes (`editor.action.gotoLine`) | must build |
| Folding | must build | yes | yes (line fold provider) |
| Minimap | must build | yes | yes |
| Diff editor | must build | yes (DiffEditor: side-by-side, inline, hide unchanged) | **no** |
| Languages out of the box | 1 grammar per tree-sitter package | 91 (+ Orca's 9 registrations) | 41 entries, about 37 languages (CodeEditLanguages) |

### 4.3 Observations behind the numbers

- **TextKit 2 height estimation drifts.** On `1mb.ts` the text view's height grew from 398,374 pt after open to 467,771 pt after a full scroll (+17 %); on 50k it grew from 703,197 to 754,959. The scroller thumb jumps as layout fills in. This is a known TextKit 2 behaviour and the reason STTextView and CodeEditTextView exist.
- **TextKit 2 lays out per paragraph.** A 1 MB line is one paragraph, so every keystroke re-lays the whole line: 55 ms without colour attributes, 872 ms with them, and footprint in the GB range. In no-wrap mode (`containerSize` width = ∞) the view laid out the whole document on open: the height was exactly 50,001 × 16 pt, it took 600–700 ms, and footprint reached GBs. A native editor needs its own line-virtualised layout or a long-line cut-off, as VS Code does with `stopRenderingLineAfter`, to be safe on generated or minified files, which are common in repos and agent output.
- **Full-document attribute highlighting is the wrong model natively.** It cost about 180 MB and 250 ms on 1 MB; the viewport-only path cost 4–6 ms. Any native path must highlight the viewport only, with incremental tree-sitter edits (the naive UTF-16 copy here cost 7–14 ms per keystroke; a real `readBlock` over the storage avoids it).
- **Monaco's cost is fixed memory, not latency.** WebContent sits at 174 MB idle (plaintext) and about 300 MB with the TS worker. Orca loads the TS worker for TS/JS even with diagnostics off; a smthz variant can map TS/JS to the plain editor worker and keep Monarch colouring, which saves about 130–200 MB per web view. *Implication:* use **one** web view per editor *area* (or per window) hosting multiple Monaco models, not one per tab. Monaco is designed for many models in one instance (Orca shares one model per file across tabs: `editor-save-disk-precondition.ts`, `editorTabModelUri`).
- **The Monaco bridge is cheap.** Transferring 1 MB as a `callAsyncJavaScript` argument plus model creation took under 110 ms end to end.
- **CodeEditSourceEditor, integrated correctly, is the fastest native option.** Measured: open 65–72 ms, scroll 0.3 ms, typing 0.3–0.9 ms, +84–124 MB. Its line-virtualised CoreText layout has none of TextKit 2's height-drift or no-wrap problems (no-wrap 50k behaved like wrap). Its weak points:
  - no diff editor;
  - a main-thread tree-sitter hang on a 1 MB single line;
  - 0.x API with sharp edges;
  - a heavy, licence-unclear grammar bundle.
- **The single-line 1 MB file degrades in Monaco too** (27 ms per scroll render, 10 ms typing), but it stays usable. TextKit 2 does not.

## 5. Options in detail

### 5.1 (a) TextKit 2 `NSTextView` + tree-sitter

- Licences: SwiftTreeSitter BSD-3-Clause, tree-sitter MIT, tree-sitter-typescript MIT (checked in the resolved checkouts, 0.25.0 / 0.25.10 / 0.23.2). Builds with Swift 6.4 / macOS 26 SDK. Prototype in Swift 5 language mode; SwiftTreeSitter compiled clean.
- Pros: fastest open, zero extra processes, best native IME/AX/services/spell/dictation, small memory on normal files, trivial Liquid Glass/theme fit (it is an AppKit view).
- Cons (measured): long-line and no-wrap pathologies, scroll-height drift, no multi-cursor.
- Cons (to build): minimap, diff editor, combined diff, folding, go-to-line UI, bracket matching, indentation rules, per-language grammars and queries (tree-sitter grammar per language, about 100 to match Monaco + Orca), comment toggling, find-in-selection, and so on.
- Effort to parity (estimate): 6–9 WPs before parity, and the diff editor alone is Monaco's largest subsystem.

### 5.2 (b) Monaco in WKWebView (recommended)

- Licence: `monaco-editor` 0.55.1 MIT (package.json + LICENSE); bundled deps `marked` 14.0.0 (MIT), `dompurify` 3.2.7 (Apache-2.0 OR MPL-2.0); `ThirdPartyNotices.txt` (64 KB) must ship. These are the same packages Orca uses. Add to `THIRD-PARTY-NOTICES.md` when adopted.
- Bundle size (measured on the npm package):
  - `min/` is 15 MB, of which 14 MB excluding NLS message files.
  - The largest pieces are `ts.worker` 7.0 MB, `editor.api` 3.7 MB, `css.worker` 1.0 MB, `html.worker` 0.7 MB, `json.worker` 0.4 MB, `editor.worker` 0.25 MB and `editor.main.css` 0.3 MB.
  - Dropping the TS/CSS/HTML workers (Orca disables TS diagnostics anyway) brings it to about 5 MB. English-only allows dropping the `nls.messages.*` files.
- Offline: everything is served from the app bundle through a custom scheme (`smthz-editor://`) with `WKURLSchemeHandler`, which is public API. Workers loaded from that scheme ran (TS/JSON workers started; no worker errors logged). No network and no Node; it fits AGENTS.md "WebKit only through public APIs".
- Isolation and state:
  - Non-persistent `WKWebsiteDataStore`.
  - JS↔Swift via `WKScriptMessageHandler` and `callAsyncJavaScript`.
  - Swift owns the file buffer of record, the disk baseline (mtime/size/hash), autosave timers, the save queue and conflict detection. JS is a view over models that Swift pushes and pulls.
  - Orca uses the same split between renderer models and main-process writes with disk preconditions (`editor-save-disk-precondition.ts`), so the save and conflict logic can be ported 1:1 into Swift and unit-tested without WebKit.
- Pros: Orca behaviours for free (multi-cursor, find/replace widget, go-to-line, folding, minimap, DiffEditor with hide-unchanged/inline/side-by-side, 91 languages, Monarch/TextMate, view state), best measured frame cost on code files, and graceful long-line degradation.
- Cons and risks:
  - Memory: about 250–630 MB per WebContent plus about 100 MB GPU. Mitigate with one shared web view per window and plain worker mapping.
  - Cold boot about 230 ms. Mitigate by pre-warming at app launch or on first workspace open.
  - Look and feel is web, not AppKit: context menus, scrollbars, focus ring and font smoothing. Monaco themes must be generated from smthz's `UITokens`/terminal theme. Liquid Glass applies only to the surrounding chrome, as DESIGN.md already limits it to navigation and controls.
  - VoiceOver and IME: Monaco has screen-reader mode and composition handling, but they are **unverified** in WKWebView. A manual check is required in the first editor WP.
  - Keyboard routing: AppKit menu key equivalents versus the web view need a defined routing (Cmd-F, Cmd-D, Alt-Z, Cmd-Shift-M).
  - Linux execution hosts are unaffected: the editor runs on the Mac client, and files come over host RPC.

### 5.3 (c) Existing Swift editor packages

| Package | Licence | Platforms | Status (2026-10) | Verdict |
|---|---|---|---|---|
| STTextView 2.4.1 | **GPL-3.0 or paid commercial** (LICENSE.md) | macOS 14+, iOS 16+ | active, 1.6k stars | Incompatible with smthz's MIT licence (GPL would relicense the app) unless a commercial licence is bought: **owner decision**, not recommended |
| Runestone 0.5.2 | MIT | **iOS 14 only** (`Package.swift` platforms) | active | Not usable on macOS |
| CodeEditSourceEditor 0.15.2 (+ CodeEditTextView 0.12.1, CodeEditLanguages 0.1.20, TextFormation, SwiftTreeSitter) | MIT (CodeEditLanguages has no SPDX licence on GitHub: **verify** before use) | macOS 13+ | active; last release 2025-09 | Prototyped (§4). Best native performance measured; no diff editor; 0.x API; see build notes |
| CodeEditorView (mchakravarty) | Apache-2.0 | macOS/iOS | active | Not prototyped: TextKit 2 based (inherits §4.3 risks), smaller feature set; no diff editor |

CodeEditSourceEditor build notes (measured):
- `swift package resolve` clones CodeEditLanguages, a **1.4 GB** git history (GitHub `size` 1,448,891 KB), and downloads a **375 MB** `CodeLanguagesContainer.xcframework` (prebuilt tree-sitter grammars, built on the maintainer's machine; the linker warns about missing debug objects under `/Users/Khan/...`) plus a 214 MB SwiftLint binary. Resolve took about 25 minutes on this connection.
- **Out of the box `swift build` fails.** CodeEditSourceEditor and CodeEditTextView run a SwiftLint *prebuild plugin* that crashes (`Loading sourcekitdInProc.framework ... failed`) because `xcode-select` points at the Command Line Tools on this machine (AGENTS.md environment fact). Workaround used: local copies of both packages with the plugin removed. It then built in 33 s (release, -j 4) under Swift 6.4 in Swift 5 language mode; no source changes needed.
- **CodeEditLanguages has no LICENSE file** in its repository (contents: Package.swift, Sources, xcframework zip, scripts). It bundles about 40 third-party grammars, each with its own licence. Legal status must be clarified, or grammars rebuilt from their upstream MIT repos, before shipping.
- API footguns found:
  - Theme colours must be concrete sRGB: catalog colours (`NSColor.textBackgroundColor`) throw `NSInvalidArgumentException` in `MinimapView.setTheme`.
  - Passing a large string to `TextViewController.init` before the view has a frame lays out every line synchronously (6.4 s / 22.6 s, 1.2–2.3 GB). Create it empty, size it, then `setText`.
  - The highlighter applies results on the main queue, so it needs a live main queue. A harness bug, spinning a nested run loop inside a main-queue block, first made highlighting look broken.
- Language list: 41 `CodeLanguage` entries (about 37 distinct languages; no Vue/Svelte/Astro/Nim/Typst/Quarto/Solidity/XML/Makefile/PowerShell).

## 6. Feature matrix vs Orca

Legend:
- ✅ out of the box.
- 🔧 must be built in Swift or JS, effort in brackets: S, M or L.
- ❌ reduction unless built.

"Reduction?" says whether the option, *as shipped in its first editor WP*, would be a functional reduction versus Orca that the user must accept.

| Orca feature | (a) TextKit 2 + tree-sitter | (b) Monaco/WKWebView | (c) CodeEditSourceEditor |
|---|---|---|---|
| Autosave on blur/idle (1 s), explicit save | 🔧 S (Swift) | 🔧 S (Swift, same code) | 🔧 S |
| Conflict-safe writes (disk precondition, stale banner, reload/compare/overwrite, watcher coalescing, non-UTF-8 pause) | 🔧 M (Swift, engine-independent) | 🔧 M (same Swift code) | 🔧 M |
| Go-to-line | 🔧 S | ✅ | 🔧 S |
| Find / replace in file (regex, case, word, seeded from selection) | ✅ basic `NSTextFinder`; regex 🔧 M | ✅ | ✅ find; replace; methods contains/word/starts/ends/regex (`Find/FindMethod.swift`) |
| Worktree search (Cmd-Shift-F) | 🔧 (rg, engine-independent) | 🔧 (same) | 🔧 (same) |
| Multi-cursor, Cmd-D next occurrence | ❌ 🔧 L (NSTextView does not support it) | ✅ | ✅ multiple carets (probed); Cmd-D next occurrence 🔧 S |
| Syntax highlighting, language list (about 100) | 🔧 L (grammar + query per language) | ✅ 91 + 9 Orca registrations 🔧 S | ⚠️ about 37 languages; rest 🔧 L |
| Folding, bracket matching, auto-indent | 🔧 M–L | ✅ | ✅ (TextFormation) |
| Minimap (optional) | 🔧 M | ✅ | ✅ |
| Word wrap toggle (Alt-Z) | ✅ (but no-wrap is pathological, §4.3) | ✅ | ✅ |
| Long / minified lines | ❌ (55–872 ms typing) 🔧 L | ✅ degraded but usable | ❌ hang > 90 s (synchronous tree-sitter parse on main thread) 🔧 M (size/line-length guard to skip highlighting, as Monaco/Orca do) |
| Editor font = terminal font | ✅ | ✅ (CSS font + bundled Geist Mono/terminal font) | ✅ |
| Changes view mode (HEAD vs working tree in tab) | 🔧 L (needs diff editor) | ✅ via DiffEditor | 🔧 L |
| Diff editor (side-by-side, inline, hide unchanged, whitespace, word wrap) | ❌ 🔧 L | ✅ | ❌ 🔧 L |
| Combined diff (multi-file review, comments) | 🔧 L (on top of diff editor) | 🔧 M (Orca's own React surface stacked on Monaco diff editors; port to Swift list + per-section Monaco or one Monaco page) | 🔧 L |
| Merge-conflict decorations/review | 🔧 M | 🔧 S (decorations API) | 🔧 M |
| Large paste chunking | ✅ native | 🔧 S (Orca's chunking) | ✅ |
| View-state per tab (cursor/scroll restore) | 🔧 S | ✅ (`saveViewState`) | 🔧 S |
| IME | ✅ (probed) | ⚠️ unverified | ✅ (probed `setMarkedText`) |
| VoiceOver | ✅ native AXTextArea | ⚠️ unverified (Monaco screen-reader mode) | ✅ `AXTextArea` (VoiceOver session unverified) |
| Offline bundling / size | ✅ (prototype binary with tree-sitter-typescript: 2.1 MB) | ✅ (14 MB of web assets, about 5 MB trimmed) | ✅ but the release executable with all grammars linked is **106 MB** (+ 0.35 MB query bundle) |
| Liquid Glass / theme fit | ✅ native | ⚠️ web content; theme generated from tokens; glass only on chrome | ✅ native |
| Markdown rich editor (Tiptap) | ❌ separate WP (§8) | ❌ separate WP (§8), same web stack | ❌ separate WP |
| Viewers (PDF, images, CSV, Mermaid, HTML, notebooks) | engine-independent (§9) | engine-independent | engine-independent |

**Reductions vs Orca if chosen without extra work:**
- (a) multi-cursor, diff editor/changes view, minimap, folding, language breadth, long-line safety, go-to-line.
- (b) none in the code editor itself. Open items are IME and VoiceOver verification, plus the markdown rich editor (shared with every option).
- (c) diff editor/changes view, language breadth beyond about 37, long-line hang, go-to-line, Cmd-D.

## 7. Risks

| Risk | Option | Severity | Mitigation |
|---|---|---|---|
| WebContent memory 250–630 MB per web view | b | M | One web view per window hosting many models; map TS/JS to the plain worker (diagnostics are off as in Orca); measure in the first WP; release models of closed tabs (Orca: `closed-editor-model-lifetime`) |
| Cold boot about 230 ms | b | L | Pre-warm a hidden web view after launch; keep it alive |
| IME/VoiceOver in WKWebView not verified | b | M | Acceptance test in WP-E1 (Japanese/Chinese IME, dead keys, VoiceOver read line/selection); fall back to Monaco `accessibilitySupport: 'on'` |
| Keyboard shortcut routing (menu vs web view) | b | M | Swift menu commands call JS actions; Monaco keybindings for the rest; share `Keybindings.swift` ids |
| Web look in a native app | b | L | Generate the Monaco theme from `UITokens`; hide Monaco context menu in favour of a native `NSMenu` via message handler |
| Long lines / no-wrap layout pathology | a, c? | H | Own layout or line cut-off; not needed for (b) |
| No multi-cursor in NSTextView | a | H | Custom text view (that is what (c) is) |
| GPL licence | STTextView | H | Do not use without a commercial licence |
| 1.4 GB git clone + 375 MB xcframework for CodeEditLanguages; SwiftLint prebuild plugin breaks `swift build` with the CLT `xcode-select` | c | M | Vendor CodeEditTextView/CodeEditSourceEditor without the plugin; build own grammar xcframework from upstream repos |
| CodeEditLanguages has no licence file | c | H | Do not ship until clarified; rebuild grammars from upstream MIT sources |
| Main-thread tree-sitter hang on huge single lines | c | H | Size/line-length guard that disables highlighting (Orca/Monaco do the same) |
| Monaco upstream churn (AMD loader is legacy in 0.55; ESM is primary) | b | L | Pin 0.55.1 like Orca; ship the prebuilt `min/` AMD bundle, or build an ESM bundle once with a pinned script (Node only at build time, already allowed) |

## 8. Markdown rich editor (separate decision D-EDITOR-2)

Orca's rich markdown editor is Tiptap 3.31 (ProseMirror) with about 175 dedicated files (slash menu, `[[` links, tables with key rules, toggles stored as `<details>`, front matter, TOC, review annotations, KaTeX, lowlight, Mermaid), plus a raw Monaco toggle and a 300 KB raw-first rule (`markdown.mdx`). No native Swift equivalent exists.

- **M-a (1:1, recommended with (b)):** host Tiptap in the same local web stack (MIT, bundled, no network), with Swift owning the file and save. Shares the theme bridge and keyboard routing with Monaco.
- **M-b (reduction):** raw Monaco + live preview (rendered HTML in WKWebView via `marked` + DOMPurify, Mermaid, KaTeX). Faster to ship; loses WYSIWYG editing, slash menu, table editing, and annotations on rendered text. Needs user acceptance.

Not measured in this experiment (Tiptap bundle size/perf is a follow-up spike inside WP-E5).

A hybrid (CodeEditSourceEditor for editing, a Monaco web view only for diffs and the markdown editor) is possible. It pays both costs (two engines, two themes and keybinding sets, the WebKit memory whenever a diff is open) and is not recommended unless the user rejects (b) but needs diff parity early.

## 9. Viewers (engine-independent)

PDF → PDFKit (native, position restore trivial). Images → `NSImageView`/SwiftUI `Image`, image diff → side-by-side native. CSV/TSV → SwiftUI `Table`, sortable with search. HTML preview → WKWebView with a scheme handler and folder grants (shares the browser WPs). Mermaid → `mermaid` (MIT) in a WKWebView. Notebooks → native cell list with a Monaco/web cell editor (beta in Orca too). None of these depend on the editor choice except notebook cells.

## 10. Work-package breakdown for the recommended path (b)

Each WP: Swift core logic in `SmthzCore` with tests; web assets as files bundled by `scripts/package-app.sh` (no `Package.swift` change needed for resources, as with Geist/Lucide); author verifies with the real app.

| WP | Scope | Depends | Size |
|---|---|---|---|
| E0 Bundle | Vendor `monaco-editor@0.55.1` `min/` (trimmed: drop TS/CSS/HTML workers and NLS if accepted), `ThirdPartyNotices`, pinned fetch script with checksum; `package-app.sh` copies to `Contents/Resources/Editor` | – | S |
| E1 Editor surface | `EditorWebView` (NSViewRepresentable around one WKWebView per window), `smthz-editor://` scheme handler serving only bundle files, JS bridge protocol (open/close model, content changes as edit deltas, view state, focus, commands), theme generated from `UITokens`, font from terminal settings, pre-warm. Acceptance: open 1 MB/50k files < 150 ms, IME + VoiceOver manual check, memory check | E0 | M |
| E2 Documents and save (Swift) | `EditorDocumentStore` in `SmthzCore`: buffer of record, disk baseline, autosave (1000 ms + blur), save queue, disk precondition `written / blocked-stale / failed`, watcher reload coalescing, non-UTF-8 pause, untitled lifecycle; port Orca's test cases (`editor-save-*.test.ts`) | – (parallel with E1) | M |
| E3 Editor features | Find widget seeding, go-to-line, Cmd-D, word wrap Alt-Z, minimap setting, large-paste chunking, view-state restore per tab, extra languages (Astro, Vue, Svelte, JSONL, Nim, Typst, Quarto via Monarch/TextMate), conflict banner UI, keyboard routing with `Keybindings.swift` | E1, E2 | M |
| E4 Diff | Monaco DiffEditor surface: changes-view toggle (HEAD vs working tree via `GitService`), side-by-side/inline, hide unchanged, whitespace, large-diff prompt; then combined diff (native list of file sections, lazy-loaded diff editors, comments later) | E1, GitService | L |
| E5 Markdown | D-EDITOR-2 outcome: rich Tiptap editor (M-a) or raw + preview (M-b); TOC, front matter, `[[` links, 300 KB raw-first rule, Cmd-Shift-M toggle | E1, E2 | L (M-a) / M (M-b) |
| E6 Viewers | PDFKit, images + image diff, CSV/TSV table, Mermaid, HTML preview (with browser WPs), notebook (beta) | E2 | M–L |
| E7 Merge conflicts | Conflict decorations and review tree | E4 | M |

## 11. Appendix: prototype summary (deleted after the run)

- `bench/` (SwiftPM, Swift 5 mode, macOS 15 deployment): one AppKit executable.
  - `textkit` mode: `NSTextView.scrollableTextView()` (TextKit 2), tree-sitter parse, highlights query with `tree-sitter-typescript/queries/highlights.scm` + `tree-sitter-javascript@v0.23.1/queries/highlights.scm`, viewport and full-document colouring, timing loops as in §3.
  - `monaco` mode: `WKWebView` + `WKURLSchemeHandler` serving `monaco-editor/min` and an `index.html` (AMD loader, label→worker map as Orca, TS diagnostics off as Orca, `bench.open`/`bench.run` JS measuring model creation, rAF pacing and `render(true)` costs), memory via `footprint -p` on new WebKit processes.
- `cese/` (SwiftPM): `TextViewController(string:language:configuration:cursorPositions:)` from CodeEditSourceEditor 0.15.2 in an AppKit window, the same loops.
  - Local copies of CodeEditSourceEditor/CodeEditTextView without the SwiftLint plugin.
  - Theme colours converted to sRGB.
  - Reported numbers use "create empty, add to the sized window, then `setText`". The eager-init numbers are shown for reference.
  - The harness starts from a `Timer`, so that the async highlighter can deliver on the main queue.
  - The highlight probe counts distinct foreground colours in the first 4,000 characters (≥ 3 means highlighted).
  - The one-line hang was attributed with `sample` (main thread in `TreeSitterState.parseDocument` → `Parser.parse`).
- Raw outputs are reproduced in §4.1. Every run was a fresh process; each number is one run, except 1mb.ts TextKit and Monaco, which ran twice (ranges shown).

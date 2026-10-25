# Desktop parity ledger

Source root: `reference/orca-1.4.238`. This inventory comes from source/contract/documentation sampling, not runtime proof or a line-by-line audit. Dark, experimental and shipped behavior must be distinguished when deriving command-level cases. The older module-organization codebase map is a locator, not current coverage evidence.

Status: **Not started** means no accepted implementation evidence. Add scenario-level rows and evidence as each domain is implemented. Allowed outcomes are proved, unproven, approved native equivalent, explicitly approved reduction, or deferred by agreed scope. A mock or disabled control does not establish parity.

| Family | Reference locations (relative to source root) | Status |
|---|---|---|
| Shell, onboarding, menus, settings, navigation, windows, tab groups/splits | `src/main/startup`, `src/main/window`, `src/main/menu`, `src/renderer/src/app-shell`, `src/shared/workspace-layout` | Not started |
| Repositories, projects, folders, nested worktrees, setup/archive, sparse/shared paths | `src/main/ipc/repos`, `src/main/ipc/worktrees`, `src/main/git`, `src/main/persistence`, `src/shared/new-workspace` | Not started |
| Persistent PTYs, streams, shell env/readiness, ANSI/Unicode/IME/OSC, history | `src/main/daemon`, `src/main/runtime/terminal`, `src/main/ipc/pty`, `src/renderer/src/components/terminal-pane` | Not started |
| Agent roster, discovery, launch/hooks, status, children, stop/resume/hibernate | `src/shared/tui-agent.ts`, `src/main/agent-launch`, `src/main/agent-hooks`, `src/main/providers` | Not started |
| Structured chats, attachments, permissions/questions, queues, forks and provider options | `src/main/native-chat`, `src/main/claude`, `src/main/codex`, `src/main/acp`, `src/shared/agent-session-capabilities.ts` | Not started |
| Agent accounts, homes, credentials, login, model catalog, usage/rate limits | `src/main/credentials`, `src/main/managed-data-accounts`, `src/main/claude-accounts`, `src/main/codex-accounts`, `src/main/usage` | Not started |
| Files, search, watcher, editor/multicursor/minimap and conflict-safe writes | `src/main/ipc/filesystem`, `src/main/ripgrep`, `src/renderer/src/components/editor`, `src/shared/file-write-disk-precondition.ts` | Not started |
| Markdown/math/diagrams, HTML, PDF/images/CSV, notebooks | `src/renderer/src/components/editor`, `src/main/notebook`, `resources/notebook`, `docs/site/content/docs/editing` | Not started |
| Source control, stage/commit/rebase, diffs, comments/conflicts and agent review | `src/main/git`, `src/main/source-control`, `src/renderer/src/components/editor/combined-diff`, `src/renderer/src/components/diff-comments` | Not started |
| GitHub/GitLab/Gitea/Bitbucket/Azure/Linear/Jira tasks, reviews/checks | `src/main/github`, `src/main/gitlab`, `src/main/gitea`, `src/main/bitbucket`, `src/main/azure-devops`, `src/main/linear`, `src/main/jira` | Not started |
| Runs/tasks/DAGs/dispatches, mail/acks/asks, lifecycle, retries and federation | `src/main/runtime/orchestration`, `src/main/runtime/rpc/methods/orchestration`, `src/cli` | Not started |
| Automation schedules/timezones, run history, prechecks/session reuse | `src/main/automations`, `src/shared/automation-schedules.ts`, `src/renderer/src/components/automations` | Not started |
| SSH, paired runtimes, host authority, reconnect and remote updates | `src/main/ssh`, `src/main/managed-server`, `src/main/orcad`, `src/main/runtime/rpc` | Not started |
| Workspace environment recipes and provisioning/cleanup | `src/main/ephemeral-vm`, `src/shared/ephemeral-vm*` | Not started |
| Browser/profile/site permissions/devtools/design/automation/capture/network/remote | `src/main/browser`, `src/main/orcad`, `src/shared/browser-client-automation-protocol.ts`, `src/renderer/src/components/browser-pane` | Not started; WebKit viability gate |
| Ports, localhost forwarding, URL/process/workspace ownership | `src/main/ports`, `src/shared/workspace-ports*` | Not started |
| Skills discovery, guides, install/update/rollback and sharing | `src/main/skills`, `src/shared/skill*`, `skills`, `skill-guides` | Not started |
| Plugins, manifests, capabilities, panels, workers and updates | `src/main/plugins`, `src/shared/plugins`, `resources/plugins` | Not started; Node compatibility gate |
| Artifacts, publication/sharing, own account/profile/org and storage | `src/main/artifacts`, `src/main/orca-profiles`, `cloud`, `src/main/skills/skill-cloud*` | Not started; some server implementations absent |
| Session/history discovery, search/FTS, usage insights and memory | `src/main/ai-vault`, `src/main/ai-vault-search`, `src/main/memory`, `src/main/stats` | Not started |
| Dictation/audio/models/local and hosted transcription | `src/main/speech`, `src/renderer/src/components/dictation` | Not started |
| macOS computer use, AX/screenshots/input and helper permissions | `native/computer-use-macos`, `src/main/computer` | Not started |
| Desktop iOS Simulator and Android emulator tools | `src/main/emulator`, `src/renderer/src/components/emulator-pane`, `src/cli` | Not started |
| Attention/unread/activity, notifications, resources, dock/tray and pet | `src/main/notifications`, `src/main/stats`, `src/main/dock`, `src/renderer/src/components/activity`, `src/renderer/src/components/pet` | Not started |
| Startup/recovery/backup, diagnostics/privacy, signed install/update/CLI routing | `src/main/startup`, `src/main/persistence`, `src/main/updater`, `src/main/observability`, `src/main/cli` | Not started |

For each implemented operation cover: local Git, ordinary folder, SSH and paired macOS/Linux as applicable; success and invalid input; cancellation; disconnection; restart/recovery; identity isolation; meaningful output/UI behavior; validation command and artifact. Provider capabilities vary: recognition/TUI launch does not imply structured-chat parity.

# The Airc Agent on your own Claude Code or Codex

Status: built (2026-11-18, agentcli: 1cd508e4 protocol layer, then the backend and its checks; artifacts/agentcli/REPORT.md). Memory is not used with the CLI backends yet. Builds on docs/design/agent.md (the panel, the tools, the risk gate). The UX
around it (provider choice, first-run connect) is asideux's docs/design/agent-ux.md; this document is the backend and the
wiring into today's panel, without restyling it.

The owner wants the in-browser chat to use the person's Claude and ChatGPT subscriptions, "best case we connect to Claude
Code and Codex directly", as T3 Code does. Airc doesn't sign in for the person. It **launches the CLI the person already
installed and logged in to**, exactly as they would run it in Terminal, and gives that CLI one thing: Airc's own browser
tools, over the `airc-mcp` helper that ships in the bundle.

## 1. Backends

`AgentBackend` (Settings › AI › Agent › "Use") picks one of three:

| Backend | Who runs the loop | Model access | Tools |
|---|---|---|---|
| **API key** (existing) | Airc (`AgentRunCenter`) | the person's key, Messages / Responses API | in process (`AgentBridge`) |
| **Claude Code** | the person's `claude`, headless | whatever `claude` is logged in with (Pro/Max/Team, Console key, Bedrock…) | Airc's MCP tools only |
| **Codex** | the person's `codex app-server` | whatever `codex` is logged in with (ChatGPT plan, API key) | Airc's MCP tools only |

Whatever the backend, the panel, the Agents folder row, Watch, Take over, Activity, the approval card and Stop look and
work the same. The difference is only who decides the next step.

## 2. One gate for every backend

The CLI calls Airc's tools over MCP, so it reaches them through the helper, not in process. To keep **one** code path for
the risk gate:

```
 Airc.app                                                       person's CLI (child process group)
 ┌──────────────────────────────────────────────────────┐       ┌──────────────────────────────────┐
 │ AgentRunCenter ── AgentCLIRun ── stdin/stdout ───────┼──────▶│ claude -p --input/output stream- │
 │      │   (steps, partial text, usage, Stop)          │◀──────┤ json   |  codex app-server       │
 │      │                                               │       │          │ spawns (stdio MCP)    │
 │  gate(call) ◀── per-run AgentServer ◀── 0600 socket ─┼───────┤  airc-mcp --socket <run> (token) │
 │      │          (MCP 2025/2026, tools = offered list)│       └──────────────────────────────────┘
 │  AgentBridge.call (same tools, window, Activity)     │
 └──────────────────────────────────────────────────────┘
```

- For each conversation Airc opens a **per-run Unix socket** (0600, random name in the per-user temporary folder) served
  by a second `AgentServer` instance, and a random 32-byte run token. The CLI is told (in its MCP config, which Airc
  writes to a 0600 file) to start the bundled helper as `airc-mcp --socket <that socket> --client claude-code-airc`
  with `AIRC_MCP_TOKEN=<token>` in the server's `env`. The helper puts the token in its hello; anything else that opens
  the socket without it is refused.
- That server lists exactly the panel's tools (`AgentBridge.offered`, the `window` argument stripped) and answers
  `tools/call` through **`AgentRunCenter.gate`**: the same checks the API-key loop makes before running a call: Stop
  requested, the step budget, the "never use" sites, the schema check, the risk probe and **the approval card** (5 min →
  Deny), then `AgentBridge.call` (the run's one window, Activity began/finished, metadata-only log line) and the
  injection warning (added to the result as Airc's note). A declined action returns the same tool error text the model
  gets on the API path ("The person declined…"), and the run stops after the CLI's turn ends.
- The session is named **"Claude Code (in Airc)"** / **"Codex (in Airc)"** in the Agents folder, Watch and Activity;
  its key is the panel's (`airc-panel`), so Stop in the folder/Watch/Dock stops the panel run.
- **Approval.** External apps get the one-time "Allow <app> to use Airc?" prompt because they come from outside. Here
  the person chose the backend in Settings › AI › Agent and typed the task into Airc's panel, so that choice is the
  approval; there's no second prompt, and the run works with "Let AI apps use Airc" off (like the API-key panel, it's
  the person asking). Every risky action still needs its yes on the card, because the tools are Airc's.

## 3. Claude Code

**Finding it.** `AgentCLILocator` looks in order: the login shell's `PATH` (`$SHELL -l -c 'command -v claude'`, read
once, 3 s timeout, because apps started from the Dock get a minimal PATH), `~/.local/bin`, `~/.claude/local`,
`/opt/homebrew/bin`, `/usr/local/bin`, npm's global prefix (`~/.npm-global/bin`, `~/.volta/bin`, `~/.bun/bin`).

**Status** (Settings shows it, refreshed when Settings or the panel opens; at most every 30 s):
- `claude --version` → "2.1.322 (Claude Code)" → version.
- `claude auth status --json` (exit 0/1; `{"loggedIn": bool, "authMethod", "apiProvider", "subscriptionType"?}`): local
  only, no model request, no tokens. Airc reads `loggedIn`, the method and plan for the label ("Claude Code 2.1, logged
  in (Max)"); it never reads or shows the email and never touches the credential store.
- States: **ready** "Claude Code 2.1.322, logged in" · **not logged in** "Run `claude` in Terminal and log in
  (/login)." · **not installed** "Install Claude Code: `curl -fsSL https://claude.ai/install.sh | bash`, or
  `npm install -g @anthropic-ai/claude-code`" · **too old** (no `--input-format`/`auth status`: before 2.0) "Update
  Claude Code: `claude update`" · **broken** (non-zero, timeout) with the first line of stderr.

**Running it.** One process per conversation, kept alive between tasks (multi-turn), in an empty working folder Airc
owns (`<data folder>/AgentCLI/work`, so no project `CLAUDE.md` or settings apply):

```
claude -p --input-format stream-json --output-format stream-json --verbose --include-partial-messages
       --mcp-config <0600 file: {"mcpServers":{"airc":{"command":<helper>,"args":[...],"env":{"AIRC_MCP_TOKEN":…}}}}>
       --strict-mcp-config              # none of the person's other MCP servers
       --tools ""                       # no built-in tools: no Bash, Read, Edit, Write, WebFetch, Task…
       --allowedTools mcp__airc         # Airc's tools need no Claude Code prompt (Airc gates them)
       --disallowedTools Bash,Edit,Write,MultiEdit,NotebookEdit,Read,Glob,Grep,WebFetch,WebSearch,Task,Agent
       --permission-mode dontAsk        # anything not allowed is denied, never prompted (nobody could answer)
       --disable-slash-commands
       --append-system-prompt <Airc's agent rules, the same text as the API path>
       [--max-turns <N + 10>]           # only with the person's "Stop after N steps" (off by default)
       [--resume <session id>]          # after Stop or a crash: the same conversation, a new process
```

- Input: one line per task, `{"type":"user","message":{"role":"user","content":[{"type":"text","text":…}]},
  "parent_tool_use_id":null,"session_id":…}`.
- Output (one JSON object per line), mapped to the panel:
  - `system/init` → session id, model, `mcp_servers[airc].status` (not "connected" → error "Airc's tools didn't start").
  - `stream_event` (`content_block_delta`/`text_delta`) → the live line.
  - `assistant` → its `text` blocks become a "say" step; a `tool_use` whose name isn't `mcp__airc__*` → Airc stops the
    turn (interrupt, then kill) and says so: belt and braces over `--tools ""`.
  - `user` (`tool_result`) → nothing to show (Airc already showed the step when the call went through its gate).
  - `result` → turn end: `subtype` success → the final answer; `error_max_turns` (only with the person's step cap: `--max-turns` is passed only then) → "Stopped after N steps…";
    `is_error` with "login"/"/login"/"API key"/"401" in the text → "not logged in" state; usage and `total_cost_usd`
    (shown as "≈ $… on your Claude Code plan or key" only when the CLI reports it).
- **Stop**: a `control_request` `{"subtype":"interrupt"}` on stdin; if no `result` within 1.5 s, SIGTERM to the
  process group, SIGKILL 2 s later (the helper is in the same group, so it goes too). The next task starts a new process
  with `--resume <session id>`.
- **Crash** (exit before `result`, or stdout closed): the run ends with "Claude Code quit unexpectedly (exit n): <last
  stderr line>". Next task resumes the session.

## 4. Codex

**Finding it**: as above with `codex` (also `/Applications/Codex.app/Contents/Resources/codex`).

**Status**: `codex --version` ("codex-cli 0.165.0"), then a short `codex app-server` probe: `initialize` →
`account/read` → `{"account": {"type":"chatgpt","planType":…} | {"type":"apiKey"} | null, "requiresOpenaiAuth"}`, then
the process is closed. No turn, no tokens. `account == null && requiresOpenaiAuth` → **not logged in** "Run `codex` in
Terminal and sign in (Sign in with ChatGPT)." Not installed → "Install Codex: `npm install -g @openai/codex` or
`brew install codex`."

**Running it**: `codex app-server` (JSON-RPC 2.0 over stdio, newline-delimited, no `"jsonrpc"` member), what the IDE
extensions and T3 Code use, launched with `--disable shell_tool --disable unified_exec --disable apps --disable plugins
--disable multi_agent --disable image_generation -c web_search="disabled"`:

1. `initialize {clientInfo:{name:"airc", title:"Airc", version}}` → `initialized`.
2. `config/read` → the names of the person's own `mcp_servers`; each is disabled for this thread.
3. `thread/start {cwd: <Airc's work folder>, approvalPolicy:"never", sandbox:"read-only",
   developerInstructions: <Airc's agent rules>, config:{mcp_servers:{airc:{command, args, env:{AIRC_MCP_TOKEN},
   tool_timeout_sec:330},
   <theirs>:{enabled:false}}}}` → thread id.
4. Per task: `turn/start {threadId, input:[{type:"text", text}]}` → turn id.
5. Notifications: `item/agentMessage/delta` → live line; `item/completed` `agentMessage` → a "say" step;
   `item/started` `mcpToolCall` with `server != "airc"`, or any `commandExecution`, `fileChange`, `webSearch`,
   `dynamicToolCall`, `collabAgentToolCall`, `imageGeneration` → Airc interrupts the turn and says so;
   `thread/tokenUsage/updated` → usage; `error` (not `willRetry`) → the message; `turn/completed` → `completed` (final
   answer = last agent message), `interrupted` (Stop), `failed` (`turn.error.message`, "401"/"login" → not logged in).
6. Server → client requests: `item/commandExecution/requestApproval`, `item/fileChange/requestApproval`, legacy
   `execCommandApproval`/`applyPatchApproval`, `item/permissions/requestApproval` → **declined**;
   `mcpServer/elicitation/request` → accept only for `serverName == "airc"` (Airc's own card decides), else decline;
   `item/tool/requestUserInput`, `item/tool/call`, anything unknown → JSON-RPC error.
- **Stop**: `turn/interrupt {threadId, turnId}`; no `turn/completed` within 1.5 s → kill the process group, the next
  task starts a fresh app-server and `thread/resume`s the thread (or starts a new thread when resume fails).
- **Step limit**: none by default (2026-11-23). With the person's "Stop after N steps", Airc's gate enforces it for every
  backend (Codex has no turn cap flag): past N a tool call answers "The person's step limit for this task is reached:
  stop and tell the person what you did so far", and Airc interrupts the turn if the CLI keeps going.

## 5. Policy: what Airc does and doesn't do with the person's accounts

- Airc **never handles** Claude or ChatGPT credentials: no sign-in UI, no OAuth, no reading `~/.claude`,
  `~/.claude.json`'s tokens, `~/.codex/auth.json` or Keychain items, no copying them, no environment variables with
  keys. The CLI reads its own login, as it does in Terminal. Airc reads only what the CLI prints about itself
  (`--version`, `auth status` / `account/read`: logged in yes/no, method, plan name), and never the email.
- Airc passes the CLI no `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` and removes those from the child's environment, so the
  CLI uses the login the person chose in it (an exported key in the person's own shell profile still applies, as in
  Terminal).
- Usage counts against the person's plan or key, under the provider's terms they accepted when they installed and
  logged in to the CLI. Airc shows what the CLI reports.

**What the owner should know** (sources: artifacts/agentpanel/REPORT.md Part A, Anthropic's and OpenAI's pages as of
2026-11):
1. **Anthropic.** The Agent SDK overview says: "Unless previously approved, Anthropic does not allow third party
   developers to offer claude.ai login or rate limits for their products, including agents built on the Claude Agent
   SDK." Airc offers no claude.ai login and ships no Claude Code: it runs the copy the person installed, with the login
   they made in it. Headless mode (`-p`, stream-json) is documented for scripting and integrations, and other
   open-source apps (T3 Code, editors via ACP) do exactly this. But "rate limits for their products" is broad: driving
   a subscription-logged-in Claude Code from a third-party app is a **grey area** Anthropic could read as offering
   claude.ai rate limits. Recommendation: ship it as "your own Claude Code", never "Claude in Airc", keep the API-key
   path first-class, and ask Anthropic (partnerships) for a written OK before marketing it; be ready to switch it off by
   a release. Branding: use "Claude Code" only to name the person's own tool ("Uses your Claude Code"); no Claude logo.
2. **OpenAI.** `codex app-server` is OpenAI's documented integration surface for IDEs and other clients (the VS Code
   extension and T3 Code use it); Codex with a ChatGPT plan is meant for the person's own use, which this is (their
   machine, their task). Plan limits apply (Plus shares a 5-hour window across Codex surfaces). Lower risk than (1).
3. Both CLIs send the person's task, page text and screenshots from the tools to Anthropic/OpenAI, as the API-key path
   does; Settings says so.
4. Neither CLI is required: the app checks for them at run time and works without them (the public build compiles and
   runs with neither installed).

## 6. Code

| Where | What |
|---|---|
| AircKit `AgentCLI.swift` | Kinds, locator candidates, version/status parsing, argument and MCP-config builders, `ClaudeStreamParser` (stream-json → events) and `CodexRPC` (JSON-RPC lines → events, requests and the answers to server requests). Pure, unit-tested. |
| Agent/AgentCLIProcess.swift | posix_spawn in its own process group, stdin/stdout/stderr pipes, line reader, interrupt → SIGTERM → SIGKILL of the group, exit status. |
| Agent/AgentCLIDetect.swift | Locator + status probes off the main thread, cached for Settings and the panel. |
| Agent/AgentCLIRun.swift | One conversation on a CLI: the per-run socket server and token, the MCP config, the process, events → `AgentRunCenter`, Stop, crash, resume. |
| Agent/AgentRun.swift | `AgentBackend` dispatch in ask/continue/stop; `gate(call)` shared by the API loop and the CLI's MCP calls. |
| Agent/AgentModelSettings.swift, Panel/AgentModelSection.swift | `values.backend`; Settings › AI › Agent "Use": API key / Claude Code / Codex with the detected state and the fix. No restyle: same rows. |
| AircMCP/main.swift | `AIRC_MCP_TOKEN` → hello `token`. |
| Debug/AgentPanelCheck.swift, tools/agentcli/fake-claude, fake-codex | Fake CLIs (Python 3) speaking the same protocols and driving Airc's MCP tools through the real helper; `--script agentpanel` cases for both. |

T3 Code (MIT, © 2026 T3 Tools Inc.) was read for the protocols (its Codex app-server client, Claude capability probe and
launch flags). No code is copied: Airc's side is Swift and written from the CLIs' own `--help`, Codex's generated JSON
schema (`codex app-server generate-json-schema`) and probes against logged-out scratch homes. So NOTICE needs no entry;
if code is ported later, it gets one.

## 7. Tests

- AircKit `AgentCLITests`: version strings, `auth status` JSON (in/out, API key, Bedrock), `account/read` (chatgpt,
  apiKey, null), the Claude argument list (no built-in tools, strict MCP, allowlist, resume), the MCP config, every
  stream-json message kind incl. partial deltas split per token, foreign tool use, max turns, login errors; Codex
  requests/notifications/server requests incl. declines, interrupted/failed turns, usage.
- `--script agentpanel` CLI cases (both engines, posted and real input), with `tools/agentcli/fake-claude` and
  `fake-codex` put first on a scratch PATH: streaming text, MCP tool calls on the fixture pages (open, read, click),
  the Pay approval (Deny → the fake sees the tool error; Allow → POST /paid), Stop mid-turn (interrupt honoured; and a
  fake that ignores interrupt → process group killed, helper gone), CLI crash mid-turn, not installed, not logged in,
  a foreign tool attempt (stopped), multi-turn (second task in the same process / `--resume` after Stop), and that no
  fake ever sees `ANTHROPIC_API_KEY`/`OPENAI_API_KEY`.

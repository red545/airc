# Airc Agent UX: the agent pane

Status: design, 2026-11-17. Replaces the UI half of docs/design/agent.md §6 (the ⌥⌘A child panel). The run loop, tools,
risk gate, memory and safety in agent.md stay. The backend that drives the person's own Claude Code or Codex is
docs/design/agent-cli.md (agentcli). Low-fi mockups: `artifacts/asideux/mockups.html` (frames M1–M6, cited below).

## 0. Why, and what we take from agent browsers

The owner (2026-11-17): our agent UX is bad; it should feel like the best agent browser, and ideally run on the
person's own Claude Code or Codex. A teardown of a leading agent browser (Aside: public site, help centre, changelogs and
a public hands-on video; details in artifacts/asideux/REPORT.md) shows a UX that works because of six things:

1. **The chat is part of the window, not a floating panel.** It sits as a card beside the page, opens from the
   toolbar or a shortcut, and keeps its state when you change tabs.
2. **Tasks live in the sidebar.** Each conversation is a sidebar row with a clear state (running, waiting for you,
   finished and unread). The pages the agent works in are grouped with it, and "Show all" opens the full list.
3. **Progress reads like a story.** Short prose from the agent, interleaved with one-line steps ("Opening …",
   "Downloading …") with the site's icon on a thin rail. The live page is a thumbnail you can click into. When done,
   the steps fold into one summary line.
4. **Waiting for you is loud, everywhere.** Approvals and questions show in the chat, as a popover on the sidebar row and
   in previews, so a task never sits idle unseen.
5. **The composer carries the controls.** Page attachment chip, @ for tabs, model picker and effort on the composer,
   and follow-ups while the agent works (send later, or interrupt now).
6. **Bring your own plan is a first-class choice.** Providers grouped as "your subscriptions", "API keys", with a
   clear Connect flow and plan usage next to the model picker.

What we don't copy: their brand, wording, art and credits/plans; the agent tabs mixed into the person's tab list (Airc's
agent windows stay off-screen, which is calmer); voice; routines; desktop computer use.

## 1. Model: tasks

A **task** is one conversation with the agent: the person's prompt, follow-ups, the agent's answers and steps, its
approvals, and the agent pages it used. (agent.md's `AgentRun` becomes one run *inside* a task; a follow-up starts the
next run in the same task.)

```
AgentTask
  id, title (editable), createdAt, updatedAt
  spaceID + profileID   – where it was started; it acts in that profile
  provider              – .claudeCode | .codex | .apiAnthropic | .apiOpenAI (+ model, level)
  status                – .draft | .running | .waitingApproval | .waitingAnswer | .takenOver
                          | .paused(reason) | .done | .stopped | .failed(reason)
  unread                – finished/changed since the person last looked
  items[]               – .prompt | .text | .steps(group) | .approval | .question | .warning | .memory | .error
  pages[]               – agent windows (AgentWindow ids) it opened, with title + host
  backendSession        – opaque resume handle from the backend (Claude Code session id, Codex thread id)
```

- **Store:** `<data folder>/Agent/Tasks/<id>.json`, metadata and text only (no screenshots, no page text, no keys);
  file 0600. Same never-stored rules as AgentLog. Delete removes the file and closes its agent windows.
- **Title:** the first prompt cut to ~48 characters at a word boundary. No extra model call. Double-click to rename.
- **Several at once:** up to 3 tasks run at the same time (more start as "Queued"). Each has its own agent window(s).
- **Private windows:** no tasks, no pane (unchanged).

## 2. Entry points

| Where | What it does |
|---|---|
| **⌥⌘A** (View › Airc Agent) | Toggle the pane in this window; opening focuses the composer. If a task is shown, it stays. |
| **⇧⌥⌘A** (View › New Agent Task) | Open the pane on a new, empty task (check ShortcutCenter for collisions first). |
| Toolbar ✦ button (sidebar top row, next to the address field) | Same as ⌥⌘A. Hidden while the pane is open. |
| **Command Bar** "Ask Airc to …" (M6) | For prompts (askai's rule). ↩ opens the pane and starts the task; **⌥↩** starts it in the background (only a sidebar row appears). Shown whenever any provider is ready (cached flag, Perf `cb.agentrow`). |
| **Sidebar Agents folder** `⊕` | New task in the pane. Clicking a task row opens it in the pane (§7). |
| Page context menu "Ask Airc about this page" / selection "Ask Airc about this" | New task with the page (or selection quote) attached. |
| Later (phase 3): Little Airc | A compact pane in Little Airc for asking from anywhere; same task store. |

## 3. The pane

**Placement (M1).** A card in the window's content area, on the side away from the sidebar (sidebar left → pane right;
sidebar right → pane left). Same corner radius, shadow and 8 pt gap as the web content card and split-view cards, so
it reads as part of the window (Arc's split view look), not a panel floating over it. Width 400 pt default, 340–560
(and at most 45 % of the content width); drag the inner edge, double-click it to reset; width remembered per window.
Below 900 pt window width the pane overlays the content card (same card, with a shadow) instead of squeezing the page.
Full-screen and the sidebar's hidden mode keep the pane. Open/closed and the shown task are per **window and Space**:
switching Space shows that Space's last pane state (Arc keeps per-Space state the same way); switching tabs never
changes it.

**Expand (⤢).** Shows the task in the content area as a full tab-like view (transcript centred at 720 pt, live pages as
cards on the right). For long reading; the pane closes while expanded. ⤢ again or Esc returns.

**Header (44 pt).** Task title (editable), then icon buttons: History ◷ (opens all tasks, §7), New ✎ (⇧⌥⌘A), Expand ⤢,
Close ✕ (⌥⌘A). The header shows the Space's icon when the task belongs to another Space than the one shown (rare;
§7).

**Live page card (M1).** While a task runs or waits, the top of the transcript holds a card with the agent's current
page: the same source `AgentWatchView` uses (`AgentPageDriver.liveLayer`, the engine's own output with no copies,
else `watchFrame` copies), scaled to the pane width − 24 pt at 16:10, with the agent's cursor dot. Caption row (28 pt): site
icon, "Site · Page — current step", **Take over**. Clicking the picture opens **Watch** in the content area (existing).
⌃ collapses it to the caption strip (remembered). Several pages: the card shows the one acted on last; a "2 pages ▾"
menu switches. Hosting runs only while the pane is visible and the window is on screen; if hosting isn't available
(engine or OS), the frame copies run at most 2 per second here. Hidden after the task ends (the pages stay as chips in the answer).

**Transcript.** Bottom-anchored, lazy list (SwiftUI `List`/`LazyVStack` in an `NSHostingView`; keep row views cheap).
Items:
- **Prompt:** right-aligned bubble (chip colour), with attachments as chips above it.
- **Agent text:** plain, Markdown (bold, lists, links, tables, code); streams at most every 50 ms (agent.md).
  Links open a normal tab in the current Space.
- **Steps group (M1):** one row per tool call, 22 pt, 12 pt secondary text, 16 pt site icon on a 1 pt vertical rail.
  Caption from `AgentRedaction` (the Watch captions: "Opening shop.example.com", "Typing in ‘Search’", "Signing in
  with your saved login", "Reading ‘Your orders’"). The running step shimmers (Reduce Motion: static bullet).
  Consecutive reads collapse ("Read 3 pages"). Thinking shows only as the shimmer on "Thinking…" while nothing else
  streams; thinking text is never shown.
- **Done summary (M3 C):** when a run ends, its step groups fold into one line "▸ Done in 2m 14s · 18 steps · 3 sites"
  (or "Stopped after …"); click to expand. Pages used appear as **site chips** in the answer; a chip opens that agent
  page as a normal tab in the current Space.
- **Approval card (§6), question card (§6), warning line** ("The page asked the agent to: …", agent.md),
  **memory line** ("Remembered in sites.md: … Undo", agent.md §5), **error banner** (§9).
- **Footer actions** under the last answer: Copy, Open pages, and (Claude Code/Codex) "Continue in Terminal" in ⋯.

**Composer (bottom, M1/M3 A).** 2–8 lines, grows with text. Placeholder "Ask Airc to…" (new task) / "Reply…" (done) /
"Tell it something while it works…" (running) / "Or tell it what to change…" (approval pending).
- **Chips row** inside the field: the current page attached by default when the pane opens from a normal page (title +
  host, ✕ removes; kept per tab while drafting); `@` lists this Space's tabs to attach; pasted long text becomes a
  file chip. An attached page is read once at send time (`read_page` on that tab, fenced as untrusted page content,
  same rules as agent.md) and its URL is given; the agent acts on its own copy in its agent window.
- **Controls row:** provider pill "Claude Code · Opus 5.5 ⌄" (§8 menu, M3 F), level pill "Quick ⌄ / Keep going"
  (agent.md §4; per-provider effort mapping is agentcli's), elapsed + steps while running, and the round **Send ↑**
  button, which becomes **Stop ■** while running.
- **Keys:** ↩ send, ⇧↩ newline, ↑ in an empty field recalls the last prompt, Esc blurs (Esc twice while running =
  Stop), ⌘. Stop. While running: ↩ sends the text **at the next step** (delivered at the next turn boundary, no
  interruption; shown as a pending bubble you can edit or remove until it's delivered); **⌘↩ interrupts** (stops the
  current turn at once, then sends). Hint under the field: "↩ send at the next step · ⌘↩ interrupt".
- Drafts survive closing the pane and switching tabs.

**Empty states.**
- *Connected, new task (M3 A):* ✦ mark, "What should Airc do?", one line on what it does and that it asks before
  paying, sending, posting or deleting; three suggestions from the current page by static rules (summarize, find X on
  this site, compare), no model call.
- *Nothing connected (M3 B):* "Connect your AI" with the three provider rows (§8), best option first. Typing still
  works; Send keeps the text and opens the top row's Set up.
- *No page (new tab page, Easel, PDFs):* no page chip, generic suggestions.

## 4. Live progress outside the pane

- **Sidebar row** (§7) shows state glyph + title + the current step as its second line ("Adding ‘Oat milk’ to the cart").
- **Dock:** badge with the number of tasks waiting for the person; nothing for running ones (calm).
- **Notifications** (only when no Airc window is key or the task's window is hidden): "Task done: <title>" and
  "<title> needs your OK". Uses the notification permission Airc already has; never in test builds (no prompts).
- **Watch** (existing) gets the task title as its heading and the same Take over / Stop.

## 5. Agent pages

Agent windows stay off-screen and never take focus (agent.md, docs/user/agents.md). That is calmer than mixing agent
tabs into the person's tab list, and we keep it. They appear only as **child rows under their task** in the Agents
folder (M1), titled by agentrows' rules (site + kind of work, no content). Clicking a child row opens Watch. Pages a
finished task left open close with the task's row (agentrows' auto-close) unless the person took one over.

## 6. Approvals, questions, takeover, stop

**Approval (M2).** The risk gate (agent.md §3) is unchanged and runs inside Airc for every backend: Claude Code and
Codex reach pages only through the Airc MCP tools, so the same `AgentRisk` check pauses the call. The request shows:
1. pinned **above the composer** (never scrolls away): "✋ Send on mail.example.com?", one line on what and where, the
   relevant text quoted when it's a message ("To: Ada · ‘Friday 12:30 works…’"), **Deny** and **Allow once**;
2. inline in the transcript after it's answered ("Allowed: Send on mail.example.com" / "Denied …");
3. as a **popover on the task's sidebar row** when the pane is closed or shows another task (arrow to the row; Open
   task / Deny / Allow once), opened once when the request arrives if the window is key, otherwise the row pulses once
   and keeps the ✋ glyph;
4. in **Watch** (existing mirror).
One answer clears all. Nothing is pre-selected. Esc = Deny; ⌘↩ = Allow once only while the card has focus (it takes
focus when it appears if the composer is empty). Typing in the composer and sending = Deny plus that text, sent at
once ("Not like that: …"). 5 minutes unanswered = Deny (agent.md), but the task then waits ("Denied after 5 minutes.
Tell it how to go on.") instead of failing.

**Backend permission prompts.** Claude Code / Codex asking to run their own tools (shell, file edits) must not happen:
agentcli restricts them to the Airc MCP tools. If a backend still sends a permission request, it's auto-denied and
logged as a warning line; the person is never asked about tools Airc doesn't control.

**Questions.** When the agent asks the person something (a plain-text question at the end of a run, or a backend
"ask the user" request), the task goes to `.waitingAnswer`, the row shows "Needs your answer", and the composer
placeholder reads "Answer…". Choice questions show as buttons above the composer (fixed choices only, plus "Something
else…" which focuses the field).

**Sign-in steps.** Saved logins: `fill_saved_login` as today. MFA, passkeys and CAPTCHAs: the task waits with "Needs
you on account.example.com: a sign-in code" and **Open page** (= take over, below).

**Take over (M3 D).** From the live card, Watch or the row's menu. The agent page moves into the person's current
Space as a normal tab (selected), and the task pauses ("You have the page"). The pane shows a banner with **Hand back**
and **Stop task**. Hand back returns the page to the agent window and continues with "The person used the page; read
it again before continuing", plus anything typed. Closing the taken-over tab = Stop. (Agent windows can move pages to
a normal window today; the reverse move is new and needs a small change on both engines' tab-move code.)

**Stop.** Stop ■, Esc Esc, ⌘., the row's ⋯ › Stop, Watch's Stop. Stops at once (the backend kills or interrupts its
turn), keeps everything done so far, and the task stays open for a follow-up ("Stopped by you").

## 7. Sidebar and history

**Agents folder (M1, M2).** The existing folder above the Space bar (it hides when empty). Rows, top to bottom:
waiting for you, running, finished-unread, then the 3 most recent other tasks of this Space; then external apps'
sessions (agentrows' titled rows); then **Show all**. Row = 30 pt (44 with the second line):

| State | Glyph (leading) | Second line |
|---|---|---|
| running | small spinner | current step |
| waiting for OK / answer | ✋ (amber) | "Waiting for your OK" / "Needs your answer" |
| taken over | hand-off glyph | "You have the page" |
| done, unread | blue dot | first line of the answer, ≤ 40 chars |
| done, seen / stopped | provider icon (✦ for the pane, app icon for external apps) | none |
| failed / paused | ! (red) | short reason ("Plan limit until 18:00") |

Click: open the task in the pane (external-app rows open Watch, as today). Disclosure ▸ shows the task's pages (§5).
Context menu: Rename, Stop, Archive, Delete…, Copy answer. Drag a row to reorder is not offered (state order wins).
Finished pane tasks leave the folder 5 minutes after they were seen (agentrows' setting) and stay in history; running
or waiting ones never leave.

**All tasks (M5).** "Show all" or ◷ opens `airc://agents` as a tab: search, status chips (Running, Waiting, Done,
Stopped), Space filter (This Space / All), one table for pane tasks and external apps' sessions (the existing Activity
data), with Archive and Delete. Opening a pane task from here shows it in the pane of the current window (switching to
its Space if it belongs to another one). Settings › Agents › Activity keeps the audit view (every tool call and
approval) and links here.

**Spaces.** A task belongs to the Space it was started in and acts in that Space's profile. The Agents folder of a
Space lists that Space's tasks plus external apps using its profile.

## 8. Providers: your plan or your key

**The four choices**, in this order everywhere (pane menu, first-run card, Settings › AI › Agent):

| Shown as | Subtitle | Backend (agentcli) |
|---|---|---|
| **Claude Code** | "Your Claude plan" | the person's `claude` CLI, headless, stream-json |
| **Codex** | "Your ChatGPT plan" | the person's `codex` CLI, `app-server` JSON-RPC |
| **Anthropic API key** | "Billed to your key" | existing Messages API client |
| **OpenAI API key** | "Billed to your key" | existing Responses API client |

Default: the first that is ready, in that order. Per task, the pill can switch provider for the *next* run (the
transcript stays; the new backend gets the conversation as context).

**Provider menu (M3 F).** Groups "Your plans" and "API keys"; each row shows status and the model. Not-ready rows
stay listed with their fix ("Sign in…", "Install…", "Add a key…"). Model submenu per provider (the backend's model
list: Codex `model/list`, Claude Code's documented aliases; API providers from `AgentModels`). Plan usage when the
backend reports it ("62 % left this week", Codex `account/rateLimits/read`; Claude Code when it exposes it). ⌃1–⌃4
pick while the menu is open. "Manage in Settings…".

**Detection.** On opening the pane or Settings (never on launch, never per keystroke), agentcli checks each CLI and
reports one of: `notInstalled`, `tooOld(version, minimum)`, `needsSignIn(version)`, `ready(version, planLabel?)`,
`broken(message)`. Search order: the login shell's PATH, then `~/.local/bin`, `~/.claude/local`, `/opt/homebrew/bin`,
`/usr/local/bin`, npm's global bin. The found path is shown in Settings (with `~`), never sent anywhere. Cache the
result; Re-check button.

**Connect flow (M4).** Airc never asks for, sees or stores a Claude or ChatGPT password or token: the CLI signs in with
its own flow and keeps its own credentials.
- *Not installed:* **Install…** opens the vendor's install page in a new tab and offers Copy for the documented install
  command. "Check again" (and an automatic re-check when Airc becomes active).
- *Needs sign-in:* **Sign in…**. Claude Code: Airc writes a one-time `.command` file that runs the CLI's own login
  command (today `claude auth login`; agentcli confirms) and opens it in Terminal (the existing "Hand to Claude Code"
  path: no Apple Events, no Automation prompt). Codex: agentcli starts the app-server's `account/login/start` and Airc
  opens the returned sign-in URL in a normal tab (the CLI listens on its own loopback port). Then a sheet "Waiting for
  Claude Code to finish signing in…" polls status every 3 s for up to 10 minutes, with Cancel.
- *Too old:* says which version is needed and how to update (link + copy command).
- *Ready:* "Signed in · <plan label if reported> · version". ⋯: Use as default, Sign out (runs the CLI's logout after a
  confirm), Show logs.
- *API key:* the existing key field, Test and model picker (agent.md §2), moved into the same list.

**Plan wording.** The subtitles say whose plan pays. Under the providers: "Claude Code and Codex run on this Mac with
your own sign-in. Airc gives them only its browser tools; your tasks and the pages they read go to that provider under
your plan's terms." This replaces "Hand to Claude Desktop / Claude Code" in the pane (§10).

## 9. Errors and limits (M3 E)

Every error keeps the task, says what happened in one sentence, and offers the next step. Banner at the top of the
transcript (red outline), task status `.failed`/`.paused`, row glyph !.

| Case | Message | Actions |
|---|---|---|
| Plan limit (backend reports reset time) | "Your Claude plan's limit is reached. It resets at 18:00." | Use <other ready provider> instead · Continue at 18:00 (auto-resume, cancellable) |
| Signed out / token revoked | "Claude Code is signed out." | Sign in… · Use … instead |
| CLI missing or crashed | "Codex stopped unexpectedly (exit 1)." | Try again · Show logs · Use … instead |
| Network / provider 5xx | retried once silently (agent.md), then "Couldn't reach Anthropic." | Try again |
| Step/time budget | "Stopped: step limit (25)." | Continue (same budget again) |
| Refusal | "The model declined this task." | Rephrase (focus composer) |
| Site in the never-use list | "Stopped at bank.example.com: on your list of sites the agent never uses." | Open Settings |

## 10. What changes from today

- The child `NSPanel` (`Agent/Panel/AgentPanel.swift`) becomes the in-window pane card; its SwiftUI content is reused
  where it fits (approval card, memory lines, live partial line).
- "Connect your AI" + "Hand to Claude Desktop / Claude Code" become the provider list (§8). Handing to Claude
  Desktop stays only in Settings › Agents (connector setup), not in the pane.
- `AgentRunCenter` (one run) becomes `AgentTaskCenter` (many tasks, each with runs); approvals keyed by task.
- The Agents folder's "Airc Agent · site" rows become task rows (§7), with pages as children; agentrows' work on
  external-app rows (no row until a real action, titles, auto-close) applies unchanged.
- The Command Bar row shows for any ready provider, not only with an API key.

## 11. Build notes (both engines)

- Everything here is native AppKit + SwiftUI and engine-independent. The only engine-touching parts are the live page
  (existing Watch hosting) and Take over / Hand back (moving a tab between an agent window and a normal window; reuse
  the tab-move code both engines already use for "Move to window").
- Pane container: an `NSView` card in the window's content stack next to the web content card (same layout code as
  split view), hosting an `NSHostingView`. No new window, so no focus or Space issues (the old panel's child-window
  problems go away).
- Cost when closed: none (no hosting view, no timers). While open and idle: no timers. While running: transcript
  updates ≤ 20 Hz, live card hosting only while visible. Perf sections `agentpane.open`, `agentpane.stream`.
- Accessibility: the transcript is a VoiceOver list; each step row reads "Step: Opening shop.example.com"; the
  approval card is announced (`NSAccessibility.post(.announcementRequested)`) and is a focus target; all icon buttons
  have labels and tooltips with shortcuts.
- Light/dark and the window's tint: use the sidebar/content materials and existing colour tokens; amber only for
  waiting, red only for errors, the accent for the unread dot and primary buttons.

## 12. Backend contract (for agentcli)

The pane needs these from every backend (API, Claude Code, Codex), as one Swift event stream per run:

- `text(delta)`, `thinking` (on/off, no text), `step(started: tool, args) / step(finished: result summary, error?)`
  (Airc MCP calls are observed in Airc itself, so captions come from AgentRedaction, not the backend);
- `approvalNeeded` comes from Airc's risk gate, not the backend; the backend's tool call simply blocks until answered;
- `question(text, choices?)`, `usage(tokens?, planRemaining?, resetsAt?)`, `ended(.done | .stopped | .failed(kind,
  message, resetsAt?))`, `resumeHandle(String)`;
- commands: `start(prompt, attachments, model, level)`, `send(text, mode: .nextStep | .interrupt)`, `stop()`,
  `resume(handle)`; `status()` for detection (§8) and `login()`/`logout()`.

## 13. Phases

1. **Pane + providers** (with agentcli): pane card, transcript with steps and done summary, composer with page chip,
   provider pill, Quick/Keep going, Stop, approval pinned above the composer, first-run and connect flow, errors, the
   Command Bar row for any provider. Task store, one task per window at a time.
2. **Tasks in the sidebar:** task rows with states, page child rows, row approval popover, `airc://agents`, several
   tasks at once, Take over / Hand back, Dock badge and notifications.
3. **Polish:** send-at-next-step / interrupt, @ tab mentions, questions with choices, Expand view, Little Airc
   compact pane, "Continue in Terminal".

## 14. Tests

- `--script agentpane` (test builds, both engines), with agentcli's fake `claude` / `codex` executables and
  `FakeModelServer`: open/close/resize/persist per Space; first-run states for each detection result (fake CLIs that
  report not installed / too old / signed out / ready); a task streams text and steps, done summary folds; approval in
  pane, row popover and Watch (one answer clears all; Esc denies; nothing pre-selected); Stop in each place; take over
  then hand back; plan-limit error with "Use … instead"; Command Bar ⌥↩ background start; task file holds no secret
  (fixture key and fixture page password absent). Real driver clicks for buttons; no Terminal launch in tests (the
  `.command` path is checked by its file content).
- Snapshots for the marketing set: pane running (M1), approval (M2), first-run (M3 B), sidebar with task rows.
- AircKit unit tests: task store encode/decode and the never-stored rules, title shortening, row ordering by state.

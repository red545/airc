# AI apps and agents

AI apps like Claude Desktop and Claude Code can use Airc to browse for you. They open pages, read them, click and type,
in the sites you're already signed in to. Airc has a built-in connector for this, using MCP (the Model Context Protocol
that these apps speak). It's on by default: **Settings › Agents › Let AI apps use Airc**.

An app works in its own **agent windows**. They never come to the front, never take your keyboard or mouse, and sit off
screen. Your own windows and tabs stay as they are. While an app is connected, Airc's Dock icon wears a small ✦, and
while it works, the sidebar shows **✦ Claude is using Airc** (the app's name) in a row just under the window's close and
minimize buttons, never over them. Click it to see what it means, **Watch** what the app is doing, or **Stop** it (it can come back once you allow it
again in **Settings › Agents**).

## Ask Airc (the Airc Agent)

You can also ask Airc itself. Click **✦** at the top of the sidebar (in the toolbar row, after Back and Forward), press **⌥⌘A**, or
pick **View › Airc Agent**, and the agent pane opens beside the page, on the
side away from the sidebar (drag its inner edge to make it wider, double-click the edge for the default; **⇧⌥⌘A** starts a
new task). Type what you want done, like "find the cheapest train to Graz on Friday and fill in the booking form", and
press Return. Or type it in the Command Bar and pick **Ask Airc to…**. The page you're on goes with the task as a chip
(✕ removes it).
The agent works right in your window, in the profile your current Space uses, so your signed-in sites work. When the task
starts, its page opens as a new tab in Today and becomes the selected tab, full size, with a soft glow in your Space's
colour around it and a slim bar on top: "Airc Agent is using this tab · **Take over** · **Stop**". A small pulse shows
where the agent clicks. If the task is about the page you're on ("summarise this page", "fill in this form"), the agent
works in that tab itself. The pane beside it shows each step as one line with the site's icon, and asks for your OK.

- **While it works,** your clicks and typing on that page are paused ("Take over to use this page"); scrolling to look is
  fine (the agent looks again before its next click). **Take over** gives you the tab at once and pauses the task; **Hand
  back** lets the agent go on from the page as you left it (what you typed, where you scrolled, its history). **Stop** ends
  the task; its tabs stay as your ordinary tabs.
- **Switch tabs whenever you like.** The agent keeps going in its tab, and the pane shows a small live picture of it until
  you come back; click the picture, the tab's row in Today or the task's row in the Agents folder to bring it back. When
  the agent opens a second tab, that one is in Today too; only the tab you pick is in the main view.
- **Several tasks at once.** Start another task while one works (✎ New in the pane, ⌘T → Ask, or a reply in another
  task's view): each runs in its own tab with its own row in the Agents folder, its own Recent tasks card, its own
  approvals and its own **Watch**, **Take over** and **Stop**. Stopping one leaves the others running. The bar on a page
  and the pane act on that page's task; picking a task's row shows it in the pane. Up to 3 run at the same time (Settings
  › AI › Agent; 0 for no limit); more wait as **Queued** and start by themselves when one ends. In the Command Bar,
  **⌥↩** starts a task in the background: its page becomes a row in Today and nothing else moves. Tasks never switch your
  Space or take another window to the front by themselves.
- **Each Space keeps its own task in the pane.** Switch Spaces and the pane shows the task you last had there (or a new,
  empty one); come back and yours is still there, with whatever you'd typed. Tasks keep running whichever Space you're in.

When it's done, the steps fold into "Done in … · N steps", and
the sites it used are chips under the answer. The task also shows in the sidebar's **Agents** folder; when it waits for
your OK and the pane is closed, its row says so and asks there. **◷** in the pane lists all tasks (`airc://agents`, one
✦ tab per Space, reused).
Opening a task from its row, a Recent tasks card or ⌘T while its page is still a tab of the window shows that tab with
the task in the pane, so a task never gets a second tab.

- **Your own AI.** **Use your ChatGPT subscription** (through your own Codex: **Sign in with ChatGPT**), **your own Claude
  Code** (it uses your Claude account), or an **API key** (Anthropic or OpenAI). Airc never sees your sign-in. The first
  time, the pane lists them in that order with what each needs; the pill under the field switches between them.
  - **Install…** (Codex or Claude Code isn't on this Mac): the pane shows the install command from the tool's own docs,
    with **Copy** and **Open in Terminal** (Terminal shows the command and runs it only when you press Return; close
    the window to cancel). Airc never installs anything by itself and never asks for an administrator
    password. When you come back to Airc it looks again (or press **Check again**), and **Use it** picks it.
    Codex: `npm install -g @openai/codex` ([docs](https://developers.openai.com/codex/cli); or
    `brew install --cask codex`). Claude Code: `curl -fsSL https://claude.ai/install.sh | bash`
    ([docs](https://code.claude.com/docs/en/setup); or Homebrew `brew install --cask claude-code`). Airc finds them on your PATH, in
    `~/.local/bin`, Homebrew's folders and npm's global folder.
  - **Sign in with ChatGPT** / **Sign in…** (it's signed out, or a task stopped because its sign-in expired): Airc starts
    the tool's own sign-in. Codex: ChatGPT's sign-in page opens in a tab (Codex itself waits for it on this Mac), so the
    agent runs on your ChatGPT subscription. Claude Code: Terminal opens with `claude auth login`. The pane says
    **Waiting for sign-in…** and, once the tool reports it's signed in, your task goes on
    by itself. Airc never sees your password or token; **Cancel** stops waiting.
  - **Add key…** (an Anthropic or OpenAI API key): paste it right in the pane and **Save**; it stays in your Mac's
    Keychain and goes only to that provider (**Get a key** opens its key page). **Settings › AI › Agent** has the key,
    the model (Claude Opus 5.5 by default) and the rest.

  Whichever you pick, the task you typed before connecting goes on by itself once you're connected. The ✦ button turns
  the accent colour while the pane is open and shows a small dot while a task runs; right-click it for **New Task**,
  **Watch** and **Settings › Agents**. After your first onboarding, a one-time hint points at it ("Ask Airc to do things
  for you"); **Not now** dismisses it for good. In a narrow sidebar the toolbar row drops Reload first, then
  Forward, then Back; ✦ stays longest. With the sidebar hidden, ✦ comes back with the sidebar (hover the window's edge),
  and ⌥⌘A works with it hidden too.

  Your task, the pages the agent reads and its screenshots go from your Mac to that provider; nothing goes through
  Airc's servers. Answers stream in as they're written.
- **Claude Desktop and Claude Code as apps.** To have them drive Airc from their own window instead, set up the connector
  in **Settings › Agents** (below); their work then shows in the Agents folder like any app's.
- **It asks before risky actions.** Before anything that looks like paying, sending a message or email, posting,
  deleting or changing your account, the agent stops and shows a card above the field: **Allow once** or **Deny** (Esc).
  The same question shows in **Watch** and on the task's row in the Agents folder; answer it in any of them. Deny ends
  the task. Every answer stays in the task. When several tasks wait, each asks for itself: an answer only ever goes to
  the task it belongs to, and the folder's "needs you" goes to each in turn.
- **No step limit.** A task keeps going until it's done, you stop it, or it needs you (an approval, or a page only you
  can handle). Quick or Thorough sets how hard the model thinks on each step; neither has a limit. The pane shows the
  time and steps as it works. **Stop** (■, Esc twice, or ⌘.) ends a task at once. If you want a cap, set **Settings ›
  AI › Agent › Stop after** to 25, 50, 100 or 200 steps (it's Off by default); at the cap, **Continue** gives it that
  many more. If something goes wrong, the pane says what once, under the last step, and offers the next step: **Try
  again** or **Use … instead** (another provider that's ready).
- **Tell it something while it works.** Type in the field and press ↩: the message waits under the steps ("Sends at
  the next step") and the agent reads it at its next step, or right after its answer if it was already writing one. Click
  the message (or ✎) to edit it, ✕ not to send it. **⌘↩** stops what it's doing and sends the message now. If you stop
  the task first, the message stays ("Sends with your next message") and goes with your reply, as its own line.
- **Follow-ups stay in the task's tab.** A reply after it's done, after you stopped it, or after **Continue** goes on in
  the same tab; no new tab is opened for it.
- **Pages can't give it orders.** What a page says is never an instruction. When a page contains text aimed at an AI
  agent, the pane shows "The page asked the agent to: …", and the agent doesn't follow it.
- **Never use these sites.** Sites listed in Settings › AI › Agent stop the agent before it acts there.
- **Memory (off by default).** Turn on **Settings › AI › Agent › Memory** and the agent keeps short notes between tasks:
  `people.md`, `sites.md` and dated `notes/<date>.md` in `~/Library/Application Support/Airc/Memory`, plain Markdown you
  can open (**Open Folder**) and edit. At the start of a task it reads them (they go to your AI provider with the task);
  after a task the pane lists what it used and each line it wrote, with **Undo**. It never keeps passwords, card or
  account numbers, one-time codes, keys, anything typed into a password or code field, or text copied from a page while
  it showed one; those lines are refused. Notes are facts, never instructions: a note that tells the agent to do
  something is ignored. **Clear…** deletes them all.
- The agent never sees saved passwords, cookies or private windows; it signs in with **fill_saved_login** like any app.

### Ask from the Command Bar

Press **⌘T** and type what you want done, then press **Tab** (or click **Ask** at the end of the field): the bar switches
from Search to **Ask**. Tab only switches where it has nothing else to do, so it still lists the actions on an empty
field, starts a site's search ("yt", Tab) and accepts a completion, as in Arc; in Ask, Tab always goes back to Search and
keeps what you typed. Under the field, the chips say what the task gets:

- **+** attaches one of this Space's tabs (type **@** to attach the page you're on);
- **This Mac**: it runs here, in a background window of your Space's profile;
- **Asks first**: it asks you before it pays, sends, posts or deletes anything, and never sees your passwords;
- on the right, who runs it (your ChatGPT subscription through Codex, your own Claude Code, or an API key) and **Quick**
  or **Thorough** (how hard it thinks; neither has a step limit).

Press **Return** and the task starts in its own tab. Below the chips, **Recent tasks** shows this Space's newest tasks as
cards: one that works says "Working for 3m 48s" with its last steps and its page live; a finished one says when it ended,
with the start of its answer and the last page it saw. Click a card to open the task.

### Your tasks in the sidebar

The **Agents** folder lists this Space's tasks: **New Task** first, then each task on one row, with its page's icon (or
✦), a spinner while it works, an amber ✋ while it waits for you (with **Waiting for your OK** or **Sign in to …**
under it) and a blue dot when it finished and you haven't looked yet. Each task has one row: the page it works on isn't
listed again. Hover a working task for **Watch** (its page, live) and **Stop**; its menu also has **Take Over the Page**.
Other apps' work follows, one row per app session. **Show all** opens every task (`airc://agents`), each listed once.
Click a task to open it; when it waits for you, the click goes to what it waits for.

### The task view

A task opened from the sidebar, a card or the Command Bar fills the page area: its steps on a timeline ("Opened
cornershop.example", "Filling a saved login", "Read 3 pages"), the answer as it's written, and, while it works, the
agent's page floating live beside the steps (click it to Watch; **Take over** on hover). A step that opened a page shows
that page under it, and a saved login shows only that it was your saved login for that site, never the password. When the
agent looked for a page you saw before, the step says so ("Searched your history: ‘kyoto ryokan’ · 4 results") with what it
found as small rows (title, site, and whether it's an open tab, a pinned tab, a Favorite or from your history); click a
row to open that page in a new tab. Click a
run's "Worked for …" line to fold its steps. At the bottom, **Reply, @ for context** goes on with the same task (with the
same chips, and **■ Stop** while it works), also while other tasks run; a reply to a task from before Airc last quit
starts a new task that refers to it. When the agent
needs your OK, the card sits above the composer: **Deny** (Esc) or **Allow once**. The pane (⌥⌘A) stays the compact
form of the same task.

Airc keeps each task's title, its steps' one-line captions, the prompts, the agent's answers and the rows a history
search found (titles and addresses) in `~/Library/Application Support/Airc/Agent/Tasks`, never page text, what was typed
into pages or keys. The pictures on the cards and under "Opened …" steps are small JPEGs in `Agent/Tasks/Pictures` next
to them, so a finished task still shows them after you quit and reopen Airc: at most 24 per task and 24 MB in all (the
oldest tasks' go first), and deleting a task deletes its pictures. All of it is readable only by you.

### Finding pages you saw before

Ask for "that article about Kyoto ryokans I read last week" or "the tab with my flight booking", and the agent searches
your history and your open tabs, pinned tabs and Favorites, using the same local index as the Command Bar. It only ever
searches the profile of the Space you asked in, never another profile's history and never a private window's (private
windows have no agent, and their pages aren't in your history). It needs no OK, like reading a page; what it finds goes to
your AI as part of the task (titles and addresses, without sign-in parts or token-like values), and nothing new is
stored. Sites on your "never use" list are left out. Outside apps (Claude Desktop, other MCP apps) can't use it.

## Setting it up

To get there: press ⌘T and type "claude" (or "mcp", "agent", "connect"), then pick **Connect Claude and other AI apps…**;
or **Help › Use Airc with Claude…**; or, until an app has connected, the sidebar's **+** menu › **Connect Claude…**. Each
opens **Settings › Agents** with setup on top. Until an app has connected, the setup section is always first.

The quickest way is **Add to Claude Desktop**. Then restart Claude Desktop, and ask it to open a page in Airc.

**Settings › Agents › Set up** has three ways:

- **Add to Claude Desktop** asks first, then adds Airc to Claude Desktop's settings file
  (`~/Library/Application Support/Claude/claude_desktop_config.json`). It keeps everything else in that file and saves
  a copy of the old one next to it, named `….airc-backup-<date>`. Quit and reopen Claude Desktop afterwards. If the
  file isn't valid JSON, Airc leaves it alone and says so.
- **Add to Claude Code** runs `claude mcp add --scope user airc -- …` for you when it finds Claude Code's command, after
  asking. Otherwise **Copy** gives you the command to paste in Terminal:

  ```bash
  claude mcp add --scope user airc -- "$HOME/Library/Application Support/Airc/bin/airc-mcp"
  ```

- **Other apps** (Cursor, Codex, VS Code and other MCP apps): **Copy JSON** gives the usual `mcpServers` entry to paste
  into their MCP settings.

Each one points at `~/Library/Application Support/Airc/bin/airc-mcp`. That's a link Airc keeps pointing at the helper
inside the app (`Airc.app/Contents/Helpers/airc-mcp`), so it keeps working after updates and if you move the app.
Airc has to be running for an app to use it.

Then ask the app for something, for example "Use Airc to find my last order on example.com".

## Asks once per app

The first time an app connects, Airc asks: **Allow ‘Claude’ to use Airc?** It says which profiles the app can use, and
who signed the app. **Allow** or **Don't Allow**: Airc remembers the answer for that app. When Airc isn't the app in
front, the question shows in the top-right corner like a notification, without bringing Airc forward. If nobody answers
in two minutes, the connection is refused and Airc asks again next time.

**Settings › Agents › Apps** lists every app you answered, allowed or not, and when an allowed app last used Airc.
**Remove** forgets the answer, ends the app's connections and closes its windows. It's asked again the next time.

Airc tells apps apart by what actually runs, never by the name an app gives itself (any program can call itself
"claude-code"; the question shows such a name only as "calls itself ‘…’"):

- **A signed app or tool**: the developer's signing identity (Claude is signed by Anthropic) and the app's identifier. An
  update to the app keeps its approval.
- **A script** (a shell script, `python3 agent.py`, `node cli.js`): the script file's path and contents. Approving one
  script approves no other script run by the same `node` or `python3`, and a script that changes is asked again.
- **An unsigned program**: its path and a fingerprint of its code; a changed program is asked again.
- **Over SSH**: the computer it connects from.
- What Airc can't pin down, such as code typed straight into `python3 -c` or SSH from this Mac to itself, is asked on
  every connection and nothing is remembered.

Programs that only start other programs (`sh -c`, `env`, `npx`, `time`) don't count: the app is whatever started them.
A program that connects to Airc directly is identified as itself, so it can't borrow another app's approval.

If you allowed apps before Airc 0.1.31, apps that were told apart only by path and name (scripts, `node`, `python3`) are
asked once more.

What this protects against: any program on your Mac quietly driving your signed-in accounts through Airc. What it can't
protect against: a program already running as you can change another app's settings or tamper with it. Approval is
your consent, not a lock against software you already run.

## Profiles and logins

Each connection works in one profile and uses its logins, cookies and extensions, as you would. Every profile is open to
agents by default; switch one off in **Settings › Agents › Profiles**, and that profile's agent windows close.
**Private windows are never open to agents**: agent tools only reach the windows the app opened itself.

An app can't change your settings, read your history, or see your tabs and windows.

### Rules per app

In **Settings › Agents › Apps**, **Rules…** next to an allowed app sets:

- **Profile**: the one profile the app may use. With **Any open profile** (the default), the app chooses when several
  are open, or gets the only one. With a profile set, the app works only there: asking for another one is refused, and
  its windows in other profiles close.
- **Never open these sites**: sites (with their subdomains) the app may never open. Airc refuses to load them, and if a
  link or redirect lands on one, nothing the app does acts on or reads that page until it goes elsewhere.

Sites on the Airc Agent's **Never use these sites** list (**Settings › AI**) are closed to every app as well.

## Uploads and downloads

Agents get your files only when you say so. **upload_file** fills a page's file field with files from:

- the app's own folder, `Downloads/Airc Agents/<the app>`: what its pages downloaded, or what it put there itself;
- the folder you choose in **Settings › Agents › Files agents may upload** (and its subfolders).

Anything else is refused, including a link that points out of those folders, hidden files and files over 200 MB.

What an agent's page downloads goes to the app's own folder, not your Downloads list, and **list_downloads** tells the
app where it is. Airc doesn't keep a risky file (an app, a disk image, a script) for an agent: it's discarded, and the
agent is told to ask you. **Settings › Agents › Agents' downloads › Show in Finder** opens the folder. Both engines
work the same way.

## Needs you

When an agent's page asks for you, its row in the Agents folder says **Needs you · Sign in** (a sign-in form, a sign-in
or single sign-on page, and with Chromium pages a "401 Unauthorized" answer) or **Needs you · Captcha**, and the Agents
folder shows an orange badge. If it still needs you a few seconds later (the agent may fill a saved login itself), Airc
shows a notification, once you allow Airc's notifications. Open the row to see the page; **Take over** lets you sign in
right there. Your sign-in is the profile's, so the agent can go on in its own windows afterwards. The agent is told that
the page waits for you, so it doesn't type passwords or keep trying. Airc only checks for a visible password field, a
captcha frame, the page's address and its status: never what the page says.

### Passkeys and other prompts from an agent's page

When an agent's page asks for a passkey, Airc asks you first, where you're looking: "Claude wants to use your passkey
for example.com", with the site's address and **Allow** / **Not now**. If you're watching that page, the question
shows in Watch, over the page; otherwise the row says **Needs you · Passkey**, Airc shows a short notice in your window
(and a notification when Airc isn't in front), and clicking it opens Watch with the question. **Not now** keeps it in
Needs you, so you can answer later, until the agent gives up (the page stops asking, or the agent closes it).
**Allow** lets the page go on to the passkey itself, which you then confirm with Touch ID or your Mac's password, as
always: Airc never answers it for you, and no agent can answer it (its clicks and keys only reach its page). After
**Take over** the question stays with the page in your window. Any other window the browser opens for an agent's page
(a passkey sheet, a permission question) shows over Watch too, never on another desktop: until you open Watch, the
row says **Needs you · Prompt**.

### One click to where you answer

Whatever an agent waits for, an approval ("Pay on …?") or a page that needs you, one click takes you there: the
notification, Airc's own message at the top of the page (**Show**), the task's row in the Agents folder or the folder's
orange badge, the **✦** button (its dot turns orange while something waits), the Dock icon (its badge counts what waits)
or its menu, and the "… needs you" row an outside app's work shows under the window's header. Airc comes to the front,
even from another app, a full-screen app or another desktop, and shows the task's window on its Space:

- an approval: the agent pane on that task with the approval card's **Allow once** ready: **Return** allows it once,
  **Esc** denies, typing writes to the agent instead;
- a sign-in or a captcha: the agent's page itself over your page, with **Take over** ready: **Return** makes it your
  tab so you can sign in.

When several wait, the first click goes to the one waiting longest, the next click to the next one.

## Passwords: filled, never shown

An app can sign in with a login you saved in Airc: it clicks the username or password field and asks Airc to fill it
(`fill_saved_login`). Airc fills the form in the page. No tool ever returns a saved password, a passkey, a cookie or a
Keychain item to the app:

- reading a page (`read_page`, `find_element`) hides the values of password fields, fields whose name says password,
  one-time code, card number or PIN, and card fields;
- there's no tool that runs scripts in a page, reads cookies or storage, or opens Airc's settings pages;
- agent windows can't copy, cut or paste: the clipboard stays yours.

Filling saved logins works on the Chromium engine (the normal Airc download).

## Follow along

While an agent works in a profile, the sidebar of a window showing that profile has an **Agents** folder, just above
the downloads and players. It has one row per app session that did something (an app working on three pages is one
row, on the page that matters most: one that needs you, else the latest): an app that only connects (as Claude Code
does with every tool it knows, each time it starts) or only opens a blank window gets no row. Each row's title says
what happened, with the site's icon: the main site and the kind of work, such as **Gmail · read 3 pages** or **Corner
Shop · filled a form, paid (approved)**, or your task for the Airc Agent. Under it is the app (and the device, for
other devices), and what it's doing when that says more, such as **Claude · Clicking ‘Archive’** or **Claude Code on
studio · Done · 3 min ago**. Titles name sites and kinds of work only, never what a page said or what was typed. A
spinner shows while the app works, and an amber ✋ when its page needs you. When the app is done, its rows say **Done** and go by
themselves after 5 minutes (**Settings › Agents › Keep finished agents for**: 1, 5 or 30 minutes, or until you clear
them); a row you're watching, or whose page you took over and are looking at, stays until you leave it. They stay
listed in **Settings › Agents › Activity**. **Clear** (on the folder's header) removes finished rows at once, and the
folder goes away when it's empty. Click the header to fold or unfold the folder; Airc remembers which. Private windows
never show it.

When an agent starts, a small banner says so, such as **Claude is using Airc · Gmail**. It never takes your keyboard or
brings a window forward.

- **Watch**: click a row. The agent's page shows live in your window, read-only: a dot shows where the agent points and
  rings where it clicks, the field it types into is outlined, and a caption says what it's doing, such as
  "Clicking ‘Archive’" or "Typing in ‘Search mail’". Captions name buttons and fields only, never what's typed or a
  password. The agent keeps working exactly as before, in its own window. Press Esc, the ✕, or pick one of your tabs
  to stop watching.
- **Take over** (in Watch, or the row's menu): the agent's page becomes one of your tabs, the same page in the same
  state, in the Space you're in (or the first Space of the agent's profile). The app is told "the person took over" the
  next time it uses that window; the window's other tabs stay the app's.
- **Stop** (in Watch, the row's ■ button on hover, or its menu): the app's agent windows close, and Airc refuses its calls and
  new connections with a clear message until you choose **Allow Again** (the row's menu, or **Settings › Agents ›
  Apps**).

**Settings › Agents › Show agent pages in front** (off by default): an agent's page opens live in your window, in
Watch, as soon as the agent opens it, instead of only off screen. The agent's own window stays off screen and never
takes focus, so the agent works the same either way.

**Settings › Agents › Activity** lists what each app did in the last 7 days: when, the site (its name only, never the
page's address) and what kinds of things, such as "Clicked 4×, Typed in a field 2×, Read the page". Never what a page
said, what was typed or a button's name. It's kept on this Mac in `AgentActivity.json` (readable only by you), for 7
days; **Clear History** empties it.

Watching costs nothing while nobody watches. While you watch, Chromium pages show the engine's own output, with no
copies; WebKit pages are copies of the page's picture, up to 15 times a second, and only while the window is on screen.
Watch shows the page as soon as it has one ("Waiting for …" only shows before that).

## Stop and off

- **Dock menu › Agents › Stop Agents** (or **Settings › Agents › Stop Agents**) ends every connection and closes every
  agent window, other devices' included. Apps can connect again.
- **Settings › Agents › Let AI apps use Airc** off: no app can connect until you turn it back on. Airc removes its
  socket, and apps say that agents are off in Airc.

## What Airc keeps

`AgentLog.jsonl` in Airc's data folder lists each call: the time, the app, the tool, the profile, the site's host, how
long it took and how many bytes went back. Never what was typed, what a page said or a page's full address. Apps'
answers are in `Agents.json`. The Activity history is in `AgentActivity.json`. All three are readable only by you.

## The tools

| Tools | What they do |
|---|---|
| `list_profiles`, `use_profile` | The profiles open to agents; choose one for the connection (one profile open: chosen for you) |
| `open_window`, `close_window`, `list_windows`, `open_tab`, `select_tab`, `close_tab`, `list_tabs` | Agent windows and their tabs |
| `navigate`, `go_back`, `go_forward`, `reload`, `wait_for_load` | Loading pages (http and https only) |
| `read_page`, `find_element` | A page's text, or its links, buttons and fields with where to click them. Page text is marked as untrusted |
| `screenshot`, `zoom`, `left_click`, `type`, `key`, `scroll`, … `computer` | Anthropic's computer-use tools, acting on the agent window |
| `fill_saved_login` | Fills a saved login into the page's sign-in form |
| `search_history` | The Airc Agent only (not listed to outside apps): finds pages in the profile's history and tabs |
| `upload_file`, `list_downloads` | Fills a file field with files you allowed; the files the app's pages downloaded |

## From your other devices

Claude Code on another computer can use Airc on your Mac over [Tailscale](https://tailscale.com), the private network
that links your devices. Both need to be on the same Tailscale network.

1. On the Mac: **Settings › Agents › Other devices › Allow other devices on your Tailscale network**. It's off until you
   turn it on, and it needs **Let AI apps use Airc** on too. The line under the switch says where Airc listens, for
   example `http://100.101.102.103:47830` (the Mac's Tailscale address, or its MagicDNS name when the Mac can look it
   up). If Tailscale isn't connected on the Mac, it says so, and nothing
   listens until it is.
2. Press **Pair a Device**. Airc shows a one-time code (like `K7QF-M2XD`) and a command to copy.
3. Paste the command in Terminal on the other computer. It trades the code for that device's own key, then adds Airc to
   Claude Code with it:

   ```bash
   t=$(curl -fsS -X POST http://100.101.102.103:47830/pair -H 'X-Airc-Pairing-Code: K7QF-M2XD' -H "X-Airc-Device: $(hostname)") \
     && claude mcp add --transport http --scope user airc http://100.101.102.103:47830/mcp --header "Authorization: Bearer $t"
   ```

4. Ask Claude Code to use Airc. The first time, the Mac asks **Allow ‘Claude Code on ‹device›’ to use Airc?**, as for
   any app.

Other MCP apps work too: `POST /pair` with the code (header `X-Airc-Pairing-Code`) answers with the device's key, and
`/mcp` is MCP's Streamable HTTP with that key as `Authorization: Bearer ‹key›`.

How it's kept safe:

- Airc listens only on the Mac's Tailscale addresses (`100.x.y.z` and `fd7a:115c:a1e0:…`), and only for packets that
  came through Tailscale. Your Wi-Fi, other networks and the internet can't reach it. Tailscale encrypts the traffic
  between your devices, so Airc uses plain HTTP inside it.
- A code works once, for 10 minutes. Wrong codes are limited (5 a minute from one device, and 20 burn the code).
- Each paired device has its own key. Airc keeps only a fingerprint of it (SHA-256), in its Keychain item, and compares
  it in constant time. A request without a valid key gets "401 Unauthorized" and nothing else.
- Everything else is as for an app on the Mac: asked once per app, the profiles you opened to agents, saved passwords
  only filled, never a private window, its pages in the Agents folder where you can Watch or Stop them.
- **Revoke** next to a device ends its key at once, closes what it was doing, and forgets its approval. Pairing again
  asks again. Turning the switch off closes the network socket.

`AgentLog.jsonl` notes pairings, refusals and revokes with the device's name and Tailscale address, never a key or a
code.

### Over SSH

`airc-mcp` also works over SSH: on the other computer, run the app's MCP command as
`ssh <your Mac> '"$HOME/Library/Application Support/Airc/bin/airc-mcp" --client <name>'`. Nothing listens on the
network; the app is asked about as "‹name› (over SSH)".

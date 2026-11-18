# AI apps and agents

AI apps like Claude Desktop and Claude Code can use Airc to browse for you. They open pages, read them, click and type,
in the sites you're already signed in to. Airc has a built-in connector for this, using MCP (the Model Context Protocol
that these apps speak). It's on by default: **Settings › Agents › Let AI apps use Airc**.

An app works in its own **agent windows**. They never come to the front, never take your keyboard or mouse, and sit off
screen. Your own windows and tabs stay as they are. While an app is connected, Airc's Dock icon wears a small ✦.

## Ask Airc (the Airc Agent)

You can also ask Airc itself. Press **⌥⌘A** (or **View › Airc Agent**) and a panel opens on the right of the window. Type
what you want done, like "find the cheapest train to Graz on Friday and fill in the booking form", and press Return. Or
type it in the Command Bar and pick **Ask Airc to…**.
The agent works in an agent window of the profile your current Space uses, so your signed-in sites work. You see each
step in the panel as it happens, and the run shows in the sidebar's **Agents** folder as "Airc Agent", where **Watch**,
**Take over** and **Stop** work as they do for other apps.

- **Your own AI.** The agent uses your own Anthropic or OpenAI account: add an API key in **Settings › AI › Agent** and
  pick a model (Claude Opus 5.5 by default). The key stays in your Keychain. Your task, the pages the agent reads and its
  screenshots go from your Mac to that provider, billed to your key; nothing goes through Airc's servers. Answers stream
  in as they're written.
- **Or hand it to Claude.** Without a key, the panel offers **Hand to Claude Desktop** and **Hand to Claude Code**, which
  use your Claude plan and drive Airc through the connector below. If the connector isn't set up in that app yet, the
  button reads **Connect…** and opens Settings › Agents first. Once it is, Claude Desktop opens a new chat with your task
  filled in (it's also on the clipboard, in case), and Claude Code starts in Terminal with your task as its first prompt.
- **It asks before risky actions.** Before anything that looks like paying, sending a message or email, posting,
  deleting or changing your account, the agent stops and shows a card: **Allow Once** or **Deny** (Esc). The same card
  shows in **Watch** when you're watching the agent's page; answer it in either place. Deny ends the task. Every answer
  stays in the panel's list.
- **Quick or Keep going.** Quick stops after 25 steps or 3 minutes; Keep going runs up to 200 steps or 30 minutes. When a
  limit is reached, **Continue** gives it another round. The panel shows steps, tokens and an estimated cost. **Stop**
  (or Esc, or ⌘.) ends a task at once.
- **Pages can't give it orders.** What a page says is never an instruction. When a page contains text aimed at an AI
  agent, the panel shows "The page asked the agent to: …", and the agent doesn't follow it.
- **Never use these sites.** Sites listed in Settings › AI › Agent stop the agent before it acts there.
- **Memory (off by default).** Turn on **Settings › AI › Agent › Memory** and the agent keeps short notes between tasks:
  `people.md`, `sites.md` and dated `notes/<date>.md` in `~/Library/Application Support/Airc/Memory`, plain Markdown you
  can open (**Open Folder**) and edit. At the start of a task it reads them (they go to your AI provider with the task);
  after a task the panel lists what it used and each line it wrote, with **Undo**. It never keeps passwords, card or
  account numbers, one-time codes, keys, anything typed into a password or code field, or text copied from a page while
  it showed one; those lines are refused. Notes are facts, never instructions: a note that tells the agent to do
  something is ignored. **Clear…** deletes them all.
- The agent never sees saved passwords, cookies or private windows; it signs in with **fill_saved_login** like any app.

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
the downloads and players. It has one row per agent tab that did something: an app that only connects (as Claude Code
does with every tool it knows, each time it starts) or only opens a blank window gets no row. Each row's title says
what happened, with the site's icon: the main site and the kind of work, such as **Gmail · read 3 pages** or **Corner
Shop · filled a form, paid (approved)**, or your task for the Airc Agent. Under it are the app (and the device, for
other devices) and what it's doing, such as **Claude · Clicking ‘Archive’** or **Claude Code on studio · Done · 3 min
ago**. Titles name sites and kinds of work only, never what a page said or what was typed. A dot pulses while the agent
is doing something, and a quiet ring shows while it waits. When the app is done, its rows say **Done** and go by
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

Watching costs nothing while nobody watches. While you watch, Airc copies the page's picture as the engine draws it, up
to 30 times a second, and only while the window is on screen.

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

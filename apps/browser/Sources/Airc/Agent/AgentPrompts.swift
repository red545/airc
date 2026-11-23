// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import AircKit
import SwiftUI

/// Prompts from an agent's page that only the person can answer (watchfix, owner report 2026-11-23). An outside agent's
/// page on a sign-in site asked for a passkey; the engine's passkey sheet came up for the agent's window, which is off
/// screen, so macOS put it on another Space, top left, with no word of which agent, site or why, and the person
/// dismissed it. Now:
///
/// - **Before the engine asks** (both engines): a passkey request (`navigator.credentials.create`/`get` with
///   `publicKey`; not the passive kinds, `mediation: 'conditional'` autofill and ambient `uiMode`, which show nothing
///   unless the person picks) from a page in an agent window waits for the person. The page part `agentprompts` holds
///   the call and posts `ask`; Airc shows "<Agent> wants to use your passkey for <site>" with the requesting frame's
///   origin (as the engine committed it, not what the page says) and Allow / Not now, where the person is looking:
///   inside Watch over the page when Watch shows it, else as a "Needs you" item (the row, the badge, Airc's toast, a
///   notification when Airc isn't in front) that opens Watch with the prompt (AgentAttention). Allow lets the call go
///   on to the engine's own passkey UI and user verification, unchanged (Touch ID or the Mac's password: UV is always
///   required, touchpasskeys); nothing is ever approved without the person, and no agent tool reaches the prompt (it's
///   Airc's UI; agent input goes to the page). "Not now" puts it back in Needs you, reopenable until the agent gives
///   up: the page's own abort signal or timeout, a navigation away, the tab or window closing.
///   A page outside agent windows is answered at once (nothing changes for the person's own tabs).
/// - **When the engine asks anyway** (Chromium's passkey sheet, a permission bubble: any window the engine hangs on the
///   agent window): the agent window never shows it. It hangs, centred under the bar, on the Watch that shows that page,
///   and only while Watch is open; otherwise it waits off screen as "Needs you" until Watch opens.
/// - **Take over** keeps both: the page and its waiting request move to the person's window, where the same prompt shows
///   over the page and the engine's sheet goes with the page.
final class AgentPrompts {
    static let shared = AgentPrompts()
    static let changed = Notification.Name("AircAgentPromptsChanged")
    /// The row's "Needs you · Passkey" while its page waits for a passkey answer.
    static let reason = "Passkey"

    struct Prompt: Equatable, Identifiable {
        /// The page's request id (made by the page part).
        let id: String
        /// "get" (sign in with a passkey) or "create" (save a new one).
        let op: String
        /// The requesting frame's committed origin and its host.
        let origin: String
        let site: String
        let client: String
        let profileID: String
        let windowID: Int
        let agentTab: Int
        let rowID: String
        let frame: String
        let isMainFrame: Bool
        let since: Date
        var dismissed = false
        /// The person allowed it, but the engine refused while the page was out of view (Chromium): Take over to finish.
        var refused = false

        var title: String { "\(client) wants to use your passkey for \(site)" }
        var detail: String {
            if refused {
                return "Your Mac only lets a page you can see use a passkey. Take over to finish it on this page; \(client) can go on after."
            }
            let what = op == "create" ? "save a new passkey" : "sign in with a passkey"
            return "\(client) is working on \(site), and the page asks to \(what). Only you can allow it; next, you confirm with Touch ID or your Mac's password."
        }
    }

    private final class WeakTab { weak var tab: EngineTab?; init(_ t: EngineTab) { tab = t } }

    private(set) var prompts: [Prompt] = []
    private var pages: [String: WeakTab] = [:]
    /// Answered prompts, for a request the engine then refused (`refused`).
    private var retired: [String: Prompt] = [:]
    private var installed = false
    private var sweep: Timer?
    /// What each request was answered, and why (checks read it).
    private(set) var answered: [(id: String, go: Bool, why: String)] = []
    /// The prompt over a taken-over page (in the person's window).
    private var pageOverlays: [ObjectIdentifier: AgentPromptPageOverlay] = [:]

    // MARK: The page part

    /// Every page from now on (once the first agent window opens): the request wrapper. Pages outside agent windows are
    /// answered at once.
    func install() {
        guard !installed, let scripts = PageScripts.shared else { return }
        installed = true
        scripts.set("agentprompts", source: Self.source, frames: true) { [weak self] tab, m in self?.received(tab, m) }
        scripts.pushNow()
    }

    /// The wrapper. `ask` and `gone` carry the request id; `answer` lets it go on (`go`) or ends it as the engine would
    /// (NotAllowedError). The page's AbortSignal and timeout are honoured while it waits (default 5 min, at most 10).
    static let source = """
    function (post) {
      var C = navigator.credentials, P = C && Object.getPrototypeOf(C);
      if (!P || typeof P.get !== 'function' || typeof P.create !== 'function') return null;
      var waiting = Object.create(null), next = 1;
      var tok = Math.random().toString(36).slice(2) + Date.now().toString(36);
      function like(f, original) {
        try { Object.defineProperty(f, 'toString', { value: function () { return Function.prototype.toString.call(original); } }); } catch (e) {}
        return f;
      }
      function notAllowed() { return new DOMException('The operation either timed out or was not allowed.', 'NotAllowedError'); }
      function gated(op, original) {
        return like(function (options) {
          var self = this, args = arguments, pk = null, passive = false, rp = '', timeout = 0, signal = null;
          try {
            pk = options && options.publicKey;
            passive = !!options && (options.mediation === 'conditional' || options.mediation === 'immediate' || options.uiMode !== undefined);
            signal = options && options.signal || null;
            if (pk) { rp = String(op === 'create' ? (pk.rp && pk.rp.id) || '' : pk.rpId || ''); timeout = +pk.timeout || 0; }
          } catch (e) { pk = null; }
          if (!pk || passive) return original.apply(self, args);
          var id = tok + '-' + (next++);
          return new Promise(function (resolve, reject) {
            var done = false, timer = 0;
            function finish() { done = true; delete waiting[id]; if (timer) clearTimeout(timer); }
            function giveUp(why) { if (done) return; finish(); post('gone', JSON.stringify({ id: id })); reject(why); }
            // An engine that refuses at once (NotAllowedError before any UI: Chromium won't run a passkey request
            // for a page it counts as out of view) doesn't end the request: Airc offers Take over, then asks again.
            function answer(go) {
              if (done) return; finish();
              if (!go) return reject(notAllowed());
              var t0 = Date.now(), p;
              try { p = original.apply(self, args); } catch (e) { return reject(e); }
              Promise.resolve(p).then(resolve, function (e) {
                if (e && e.name === 'NotAllowedError' && Date.now() - t0 < 700 && !(signal && signal.aborted)) {
                  done = false; waiting[id] = answer;
                  timer = setTimeout(function () { giveUp(notAllowed()); }, 300000);
                  post('refused', JSON.stringify({ id: id, op: op, why: String(e.message || '').slice(0, 200) }));
                } else reject(e);
              });
            }
            waiting[id] = answer;
            if (signal) {
              if (signal.aborted) { finish(); return reject(signal.reason !== undefined ? signal.reason : new DOMException('The operation was aborted.', 'AbortError')); }
              try { signal.addEventListener('abort', function () { giveUp(signal.reason !== undefined ? signal.reason : new DOMException('The operation was aborted.', 'AbortError')); }, { once: true }); } catch (e) {}
            }
            var t = timeout > 0 ? Math.min(Math.max(timeout, 30000), 600000) : 300000;
            timer = setTimeout(function () { giveUp(notAllowed()); }, t);
            post('ask', JSON.stringify({ id: id, op: op, rp: rp.slice(0, 200) }));
          });
        }, original);
      }
      P.get = gated('get', P.get);
      P.create = gated('create', P.create);
      addEventListener('pagehide', function () { for (var k in waiting) post('gone', JSON.stringify({ id: k })); });
      return function (kind, json) {
        if (kind !== 'answer') return;
        var a = null;
        try { a = JSON.parse(json); } catch (e) { return; }
        var f = a && typeof a.id === 'string' ? waiting[a.id] : null;
        if (typeof f === 'function') f(a.go === true);
      };
    }
    """

    private func received(_ tab: EngineTab, _ m: EnginePageMessage) {
        guard let data = m.json.data(using: .utf8), let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = j["id"] as? String, !id.isEmpty, id.count < 80 else { return }
        switch m.kind {
        case "ask":
            guard !prompts.contains(where: { $0.id == id }) else { return }
            guard let (w, agentTab) = Self.agentPlace(of: tab) else {
                return reply(tab, frame: m.frame, origin: m.origin, main: m.isMainFrame, id: id, go: true, why: "not an agent page")
            }
            let rowID = AgentActivityModel.rowID(window: w.id, tab: agentTab)
            let site = m.host ?? (URL(string: m.origin)?.host) ?? "this site"
            let p = Prompt(id: id, op: (j["op"] as? String) == "create" ? "create" : "get", origin: m.origin, site: site,
                           client: w.clientName ?? w.client, profileID: w.profileID, windowID: w.id, agentTab: agentTab, rowID: rowID,
                           frame: m.frame, isMainFrame: m.isMainFrame, since: Date())
            prompts.append(p)
            pages[id] = WeakTab(tab)
            AgentCenter.shared.onEvent?("prompt-ask \(id) \(rowID) \(p.op) \(site)")
            AgentCenter.shared.log(["event": "prompt", "client": p.client, "kind": "passkey", "site": site])
            AgentActivity.shared.setNeedsYou(rowID, Self.reason)
            startSweep()
            post()
            AgentAttention.promptAsked(p)
        case "gone":
            remove(id, why: "the page gave up")
        case "refused":
            // The person allowed it, the engine refused before showing anything: the prompt comes back, saying why
            // (in Watch with Take over; over a taken-over page, with Allow to try again).
            // Only an agent page can be out of view; WebKit has no passkeys at all (Apple's browser entitlement): there the
            // engine's answer is final and goes to the page.
            guard prompt(id) == nil, var p = retired[id], Self.agentPlace(of: tab) != nil, !(tab is WebKitTab) else {
                return reply(tab, frame: m.frame, origin: m.origin, main: m.isMainFrame, id: id, go: false, why: "the engine refused it")
            }
            p.refused = true
            p.dismissed = false
            prompts.append(p)
            pages[id] = WeakTab(tab)
            AgentCenter.shared.onEvent?("prompt-refused \(id) \((j["why"] as? String ?? "").prefix(80))")
            if AgentActivity.shared.model.row(p.rowID)?.isLive == true { AgentActivity.shared.setNeedsYou(p.rowID, Self.reason) }
            startSweep()
            post()
        default: break
        }
    }

    /// The agent window and its tab id showing `tab`, if it's an agent's page.
    static func agentPlace(of tab: EngineTab) -> (AgentWindow, Int)? {
        for w in AgentCenter.shared.windows.values {
            if let t = w.tabs.first(where: { $0.tab === tab }) { return (w, t.id) }
        }
        return nil
    }

    private func reply(_ tab: EngineTab, frame: String, origin: String, main: Bool, id: String, go: Bool, why: String) {
        let json = "{\"id\":\"\(id.filter { $0.isLetter || $0.isNumber || $0 == "-" })\",\"go\":\(go)}"
        let sent = main ? PageScripts.shared?.callDocument(tab, frame: frame, origin: origin, part: "agentprompts", kind: "answer", json: json)
                        : PageScripts.shared?.callFrameDocument(tab, frame: frame, origin: origin, part: "agentprompts", kind: "answer", json: json)
        if answered.count < 200 { answered.append((id, go, why)) }
        if why != "not an agent page" { AgentCenter.shared.onEvent?("prompt-answer \(id) \(go ? "allow" : "deny") \(why) sent \(sent ?? false)") }
    }

    // MARK: The person's answers

    func prompt(_ id: String) -> Prompt? { prompts.first { $0.id == id } }
    func page(_ id: String) -> EngineTab? { pages[id]?.tab }
    func hasPending(row: String) -> Bool { prompts.contains { $0.rowID == row && AgentActivity.shared.model.row(row)?.isLive == true } }

    /// Allow: the page's call goes on to the engine (its own passkey UI and user verification).
    func allow(_ id: String) {
        guard let p = prompt(id) else { return }
        guard let tab = page(id), !tab.isClosed else { return remove(id, why: "the page is gone") }
        // A request the person answers in their own window (taken over): the page has the focus the engine wants.
        if Self.agentPlace(of: tab) == nil { tab.focus() }
        drop(id)
        reply(tab, frame: p.frame, origin: p.origin, main: p.isMainFrame, id: id, go: true, why: "the person allowed it")
        AgentCenter.shared.log(["event": "prompt-allowed", "client": p.client, "kind": "passkey", "site": p.site])
        // The engine's own sheet (if it shows one) lands where the person is: over Watch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.watchChanged() }
    }

    /// "Not now": out of the way, still in Needs you until the agent gives up.
    func dismiss(_ id: String) {
        guard let i = prompts.firstIndex(where: { $0.id == id }), !prompts[i].dismissed else { return }
        prompts[i].dismissed = true
        AgentCenter.shared.onEvent?("prompt-dismissed \(id)")
        post()
    }

    /// Back in front (a Needs you click).
    func reopen(_ id: String) {
        guard let i = prompts.firstIndex(where: { $0.id == id }), prompts[i].dismissed else { return }
        prompts[i].dismissed = false
        AgentCenter.shared.onEvent?("prompt-reopened \(id)")
        post()
    }

    private func drop(_ id: String) {
        guard let i = prompts.firstIndex(where: { $0.id == id }) else { return }
        let p = prompts.remove(at: i)
        retired[id] = p
        pages[id] = nil
        if !prompts.contains(where: { $0.rowID == p.rowID }) { AgentActivity.shared.setNeedsYou(p.rowID, nil) }
        AgentAttention.Notifications.withdraw("agent-prompt-" + id)
        post()
    }

    private func remove(_ id: String, why: String) {
        guard prompt(id) != nil else { return }
        AgentCenter.shared.onEvent?("prompt-gone \(id) \(why)")
        drop(id)
    }

    private func startSweep() {
        guard sweep == nil else { return }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(t, forMode: .common)
        sweep = t
    }

    /// The agent gave up when its page or window went; a taken-over page's prompt follows it to the person's window.
    #if AIRC_TESTING
    /// The marketing shot: a prompt on a row without a page behind it (never answered, removed by `removeForMarketing`).
    private var synthetic: Set<String> = []
    func addForMarketing(rowID: String, client: String, site: String, origin: String, windowID: Int, tab: Int, profileID: String) {
        let p = Prompt(id: "marketing", op: "get", origin: origin, site: site, client: client, profileID: profileID, windowID: windowID,
                       agentTab: tab, rowID: rowID, frame: "", isMainFrame: true, since: Date())
        synthetic.insert(p.id)
        prompts.append(p)
        AgentActivity.shared.setNeedsYou(rowID, Self.reason)
        post()
    }
    func removeForMarketing() {
        let rows = prompts.filter { synthetic.contains($0.id) }.map(\.rowID)
        prompts.removeAll { synthetic.contains($0.id) }
        synthetic = []
        rows.forEach { AgentActivity.shared.setNeedsYou($0, nil) }
        post()
    }
    #endif

    private func tick() {
        for p in prompts {
            #if AIRC_TESTING
            if synthetic.contains(p.id) { continue }
            #endif
            guard let tab = page(p.id), !tab.isClosed else { remove(p.id, why: "the page closed"); continue }
            if Self.agentPlace(of: tab) == nil, Self.controller(holding: tab) == nil { remove(p.id, why: "the page left Airc's windows") }
        }
        syncPageOverlays()
        if !sheets.isEmpty { watchChanged() }
        if prompts.isEmpty, sheets.isEmpty {
            sweep?.invalidate()
            sweep = nil
        }
    }

    private func post() {
        syncPageOverlays()
        NotificationCenter.default.post(name: Self.changed, object: nil)
        AgentAttention.promptsChanged()
    }

    // MARK: A taken-over page

    /// The person's window that has the page as one of its tabs (after Take over), and the tab's id.
    static func controller(holding tab: EngineTab) -> (WindowController, String)? {
        for c in AgentCenter.shared.app?.controllers ?? [] {
            if let id = c.shownTabID, c.engineTab(for: id) === tab { return (c, id) }
        }
        for c in AgentCenter.shared.app?.controllers ?? [] {
            for id in c.store.state.tabs.keys where c.engineTab(for: id) === tab { return (c, id) }
        }
        return nil
    }

    /// The prompt over a taken-over page, in the window that shows it now.
    private func syncPageOverlays() {
        var want: [ObjectIdentifier: (WindowController, Prompt)] = [:]
        for p in prompts where !p.dismissed {
            guard let tab = page(p.id), Self.agentPlace(of: tab) == nil, let (c, id) = Self.controller(holding: tab), c.shownTabID == id else { continue }
            if want[ObjectIdentifier(c)] == nil { want[ObjectIdentifier(c)] = (c, p) }
        }
        for (k, o) in pageOverlays where want[k] == nil || want[k]?.1 != o.prompt {
            o.removeFromSuperview()
            pageOverlays[k] = nil
        }
        for (k, (c, p)) in want where pageOverlays[k] == nil {
            let o = AgentPromptPageOverlay(prompt: p, theme: c.currentPalette.resolved)
            o.frame = c.card.bounds
            o.autoresizingMask = [.width, .height]
            c.card.addSubview(o, positioned: .above, relativeTo: nil)
            pageOverlays[k] = o
            AgentCenter.shared.onEvent?("prompt-shown-in-window \(p.id)")
        }
    }

    /// The prompt shown over a taken-over page in `c` (checks).
    func pageOverlay(in c: WindowController) -> AgentPromptPageOverlay? { pageOverlays[ObjectIdentifier(c)] }

    // MARK: The engine's own windows on an agent window

    struct Sheet {
        weak var window: NSWindow?
        weak var agent: AgentHostWindow?
        let since: Date
        var shownOver: Int?
    }
    private(set) var sheets: [Sheet] = []

    /// AgentHostWindow.addChildWindow: the engine hangs a window (a passkey sheet, a bubble) on the agent window. It never
    /// shows there; it goes over the Watch showing that page, or waits.
    func engineChild(_ child: NSWindow, of agent: AgentHostWindow) {
        if placing { return }
        // A dialog, not a layer of the page itself: a window as large as the agent window (an overlay the engine keeps
        // over the page) stays with it.
        #if AIRC_TESTING
        if !seenChildren.contains(where: { $0.window === child }) { seenChildren.append(WeakWindow(child)) }
        #endif
        let a = agent.frame.size, c = child.frame.size
        AgentCenter.shared.onEvent?("engine-child \(NSStringFromClass(type(of: child))) \(Int(c.width))x\(Int(c.height)) opaque \(child.isOpaque) alpha \(child.alphaValue) mouse \(!child.ignoresMouseEvents) level \(child.level.rawValue)")
        guard c.width < a.width - 8 || c.height < a.height - 8 else { return }
        if !sheets.contains(where: { $0.window === child }) {
            sheets.append(Sheet(window: child, agent: agent, since: Date()))
            AgentCenter.shared.onEvent?("engine-sheet \(child.windowNumber) on agent window")
            // The engine moves and resizes its window as its steps change (relative to the agent window): placed again.
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                sheetObservers.append(NotificationCenter.default.addObserver(forName: name, object: child, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { if self?.placing == false { self?.watchChanged() } }
                })
            }
        }
        startSweep()
        watchChanged()
    }

    private var placing = false
    #if AIRC_TESTING
    final class WeakWindow { weak var window: NSWindow?; init(_ w: NSWindow) { window = w } }
    /// Every window the engine hung on an agent window (agentwatch2 describes them).
    private(set) var seenChildren: [WeakWindow] = []
    #endif
    private var sheetObservers: [NSObjectProtocol] = []

    /// The Watch that shows a page of `agent`'s window, if one is open.
    private func watch(showing agent: AgentHostWindow) -> AgentWatchView? {
        guard let w = AgentCenter.shared.windows.values.first(where: { $0.window === agent }) else { return nil }
        for c in AgentCenter.shared.app?.controllers ?? [] {
            if let v = c.sidebar.agents.watch, let row = AgentActivity.shared.model.row(v.rowID), row.window == w.id, row.tab == w.activeTabID { return v }
        }
        return nil
    }

    /// Watch opened, closed or moved: each engine window goes over its Watch, or out of sight until one opens.
    func watchChanged() {
        sheets.removeAll { $0.window == nil || $0.agent == nil || $0.window?.isVisible == false }
        if sheets.isEmpty, !sheetObservers.isEmpty {
            sheetObservers.forEach(NotificationCenter.default.removeObserver)
            sheetObservers = []
        }
        placing = true
        defer { placing = false }
        for i in sheets.indices {
            guard let child = sheets[i].window, let agent = sheets[i].agent else { continue }
            if let v = watch(showing: agent), let host = v.window {
                let r = v.convert(v.imageRect(), to: nil)
                let page = host.convertToScreen(r)
                let size = child.frame.size
                let origin = CGPoint(x: (page.midX - size.width / 2).rounded(), y: (page.maxY - size.height - 8).rounded())
                if child.parent !== host {
                    child.parent?.removeChildWindow(child)
                    host.addChildWindow(child, ordered: .above)
                }
                child.setFrameOrigin(origin)
                child.orderFront(nil)
                if sheets[i].shownOver != host.windowNumber { AgentCenter.shared.onEvent?("engine-sheet-over-watch \(child.windowNumber)") }
                sheets[i].shownOver = host.windowNumber
            } else {
                if child.parent !== agent {
                    child.parent?.removeChildWindow(child)
                    agent.attachHeld(child)
                }
                child.setFrameOrigin(AgentWindow.offscreenFrame(child.frame.size).origin)
                sheets[i].shownOver = nil
            }
        }
        syncSheetRows()
    }

    /// Engine windows that wait for the person (no Watch shows their page), for Needs you.
    var heldSheets: Int { sheets.filter { $0.window?.isVisible == true && $0.shownOver == nil }.count }

    /// The row whose page an engine window waits on.
    private func row(of s: Sheet) -> String? {
        guard let agent = s.agent, let w = AgentCenter.shared.windows.values.first(where: { $0.window === agent }), let tab = w.activeTabID else { return nil }
        return AgentActivityModel.rowID(window: w.id, tab: tab)
    }

    /// The row's page has an engine window waiting (Needs you · Prompt) or shown over Watch.
    func holdsSheet(row: String) -> Bool { sheets.contains { $0.window?.isVisible == true && self.row(of: $0) == row } }
    private var sheetRows: Set<String> = []

    /// Rows that got or lost an engine window: their Needs you follows.
    private func syncSheetRows() {
        let now = Set(sheets.filter { $0.window?.isVisible == true }.compactMap { row(of: $0) })
        guard now != sheetRows else { return }
        let changed = now.symmetricDifference(sheetRows)
        sheetRows = now
        for r in changed { AgentActivity.shared.setNeedsYou(r, nil) }
    }
}

/// The prompt itself: the same card in Watch and over a taken-over page. Nothing is pre-selected (no default button), so
/// a stray Return never allows it; Esc is Not now.
struct AgentPromptCard: View {
    let prompt: AgentPrompts.Prompt
    let theme: ResolvedTheme
    let answer: (Bool) -> Void
    /// In Watch: the page is still the agent's, so a refused request offers Take over.
    var takeOver: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "person.badge.key.fill").foregroundStyle(theme.accent.color)
                Text(prompt.title).aircFont(AircFont.title3).foregroundStyle(theme.surfaceText.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .testAnchor("agentprompt-title")
            }
            Text(prompt.detail).aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            Text(prompt.origin).aircFont(AircFont.caption).foregroundStyle(theme.surfaceTextTertiary.color)
                .lineLimit(1).truncationMode(.middle)
                .testAnchor("agentprompt-origin")
            HStack {
                Spacer()
                Button("Not now") { answer(false) }.buttonStyle(.airc(.secondary)).testAnchor("agentprompt-notnow")
                    .help("Keep it in Needs you: you can answer it later, until \(prompt.client) gives up")
                if prompt.refused, let takeOver {
                    Button("Take Over") { takeOver() }.buttonStyle(.airc(.secondary)).testAnchor("agentprompt-takeover")
                        .help("Make this page one of your tabs, then use your passkey there")
                } else {
                    Button(prompt.refused ? "Try Again" : "Allow") { answer(true) }.buttonStyle(.airc(.secondary)).testAnchor("agentprompt-allow")
                        .help("Let the page ask for your passkey. You confirm with Touch ID or your Mac's password next.")
                }
            }
        }
        .padding(14)
        .frame(maxWidth: 440, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.surface.color).shadow(color: .black.opacity(0.2), radius: 10, y: 3))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.accent.color.opacity(0.45)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(prompt.title). \(prompt.detail)")
        .testAnchor("agentprompt-card")
    }
}

/// The prompt over a taken-over page in the person's window: only the card takes clicks; the page stays usable around it.
final class AgentPromptPageOverlay: NSView {
    let prompt: AgentPrompts.Prompt
    private var host: AircFirstClickHostingView<AnyView>?

    init(prompt: AgentPrompts.Prompt, theme: ResolvedTheme) {
        self.prompt = prompt
        super.init(frame: .zero)
        let id = prompt.id
        let card = AgentPromptCard(prompt: prompt, theme: theme) { allow in
            if allow { AgentPrompts.shared.allow(id) } else { AgentPrompts.shared.dismiss(id) }
        }
        let h = AircFirstClickHostingView(rootView: AnyView(card.frame(width: 440).testAnchorRoot().aircTheme(theme)))
        h.safeAreaRegions = []
        addSubview(h)
        host = h
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    /// The card, centred near the bottom of the page.
    override func layout() {
        super.layout()
        guard let h = host else { return }
        let size = h.fittingSize
        h.frame = CGRect(x: ((bounds.width - size.width) / 2).rounded(), y: max(0, bounds.height - size.height - 24).rounded(),
                         width: size.width, height: size.height)
    }

    /// Clicks outside the card reach the page.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let h = host, h.frame.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }
}

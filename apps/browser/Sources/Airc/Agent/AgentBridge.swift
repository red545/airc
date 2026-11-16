// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircKit

/// The Airc Agent's tools (docs/design/agent.md, "Architecture"): the MCP server's own `AgentTool`s, run in process with
/// a panel session, exactly as `AgentMCP.handle` runs a `tools/call`: same profile checks and agent windows, same
/// Agents folder rows, Watch captions and Activity history, same metadata-only log line. On top: the risk probe that asks
/// the page what an acting call would hit, and the conversion of an `AgentResult` into what the model reads.
final class AgentBridge {
    static let clientKey = "airc-panel"
    static let clientName = "Airc Agent"
    /// The MCP tools the model gets, by name (1:1, same schema minus `window`). The run owns its window and profile, so
    /// the window and profile tools aren't offered; the low-level and legacy shapes neither (fewer ways around the gate).
    static let offered = ["navigate", "go_back", "go_forward", "reload", "wait_for_load", "read_page", "find_element",
                          "list_tabs", "open_tab", "select_tab", "close_tab", "fill_saved_login", "screenshot", "zoom",
                          "left_click", "double_click", "triple_click", "left_click_drag", "mouse_move", "scroll", "type", "key", "wait"]
    private static var nextSession = 900_000

    let center: AgentCenter
    let session: AgentSession
    private(set) var windowID: Int?

    init(center: AgentCenter = .shared, profileID: String) {
        self.center = center
        AgentBridge.nextSession += 1
        session = AgentSession(id: AgentBridge.nextSession, persistent: true)
        session.client = AgentBridge.clientName
        session.clientName = AgentBridge.clientName
        session.clientKey = AgentBridge.clientKey
        session.via = "panel"
        session.profileID = profileID
    }

    /// The model's tool list: the MCP tools named in `offered`, in that order.
    var specs: [AgentToolSpec] {
        AgentBridge.offered.compactMap { name in
            center.tools.first { $0.name == name }.map {
                AgentToolSpec(name: $0.name, description: $0.description, schema: AgentToolSpec.strippingWindow($0.schema))
            }
        }
    }

    var window: AgentWindow? { windowID.flatMap { center.windows[$0] } }

    /// Opens the run's agent window (the MCP `open_window`, same code), once.
    func openWindow(_ done: @escaping (String?) -> Void) {
        if window != nil { return done(nil) }
        center.ensureDriver()
        center.admitPanel(session)
        guard let tool = center.tools.first(where: { $0.name == "open_window" }) else { return done("Airc isn't ready.") }
        tool.run([:], session) { [weak self] result in
            guard let self else { return }
            if result.isError { return done(Self.text(result)) }
            self.windowID = (result.structured?["window"] as? Int) ?? self.session.currentWindow
            done(self.windowID == nil ? "No agent window." : nil)
        }
    }

    /// Ends the session: its window closes (Done, or Stopped in the Agents folder).
    func end(_ how: AgentTabRow.End) {
        center.endPanel(session, how)
        windowID = nil
    }

    /// One tool call, as `tools/call` runs it: Activity began/finished, the log line, and a timeout so a page that never
    /// answers can't hold the run.
    func call(_ name: String, _ args: [String: Any], _ done: @escaping (AgentResult) -> Void) {
        guard AgentBridge.offered.contains(name), let tool = center.tools.first(where: { $0.name == name }) else {
            return done(.error("Unknown tool: \(name)."))
        }
        var a = args
        a["window"] = windowID   // the run's one window, whatever the model sent
        let started = CFAbsoluteTimeGetCurrent()
        let call = AgentActivity.shared.began(name, a, session: session, center: center)
        var answered = false
        let finish: (AgentResult) -> Void = { [weak self] result in
            guard !answered else { return }
            answered = true
            if let self { self.center.logCall(name, self.session, result, (CFAbsoluteTimeGetCurrent() - started) * 1000) }
            if let call { AgentActivity.shared.finished(call, isError: result.isError) }
            done(result)
        }
        let waits = (a["duration"] as? NSNumber)?.doubleValue ?? 0
        DispatchQueue.main.asyncAfter(deadline: .now() + max(60, min(300, waits) + 30)) { finish(.error("\(name) timed out: the page didn't answer.")) }
        tool.run(a, session, finish)
    }

    // MARK: The risk probe

    /// What kind of action a call is, for the gate: nil for calls that can't commit anything by themselves.
    static func gatedAction(_ name: String, _ args: [String: Any]) -> String? {
        switch name {
        case "left_click", "double_click", "triple_click": return "click"
        case "key":
            let k = (args["text"] as? String ?? "").lowercased()
            return k == "return" || k == "enter" || k == "kp_enter" || k.hasSuffix("+return") || k.hasSuffix("+enter") ? "key-submit" : nil
        case "type":
            let t = args["text"] as? String ?? ""
            return t.hasSuffix("\n") || t.hasSuffix("\r") ? "key-submit" : nil
        case "navigate", "open_tab": return "navigate"
        default: return nil
        }
    }

    /// Asks the page what the call would hit and classifies it. `done(nil, facts)`: no approval needed.
    func probe(_ name: String, _ args: [String: Any], _ done: @escaping (AgentRisk?, AgentElementFacts?) -> Void) {
        guard let action = Self.gatedAction(name, args) else { return done(nil, nil) }
        if action == "navigate" {
            let f = AgentElementFacts(pageURL: args["url"] as? String ?? "")
            return done(AgentRisk.classify(f, action: action), f)
        }
        guard let w = window, let tab = w.activeTab, !tab.isClosed else { return done(nil, nil) }
        var point = w.cursor
        if let c = args["coordinate"] as? [Any], c.count == 2, let x = (c[0] as? NSNumber)?.doubleValue, let y = (c[1] as? NSNumber)?.doubleValue {
            point = CGPoint(x: x, y: y)
        }
        let script = action == "click" ? Self.probeScript(x: point.x, y: point.y) : Self.probeScript(x: nil, y: nil)
        var answered = false
        let finish: (Any?) -> Void = { value in
            guard !answered else { return }
            answered = true
            guard let o = agentJSON(value), !o.isEmpty else {
                // No answer from the page: an acting call we can't see into is treated as unknown, not as safe, only
                // on a known payment or mail place.
                let f = AgentElementFacts(role: "button", submitsForm: true, pageURL: tab.url?.absoluteString ?? "")
                return done(AgentRisk.classify(f, action: action), f)
            }
            let f = AgentElementFacts(json: o)
            done(AgentRisk.classify(f, action: action), f)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { finish(nil) }
        w.driver.evaluate(tab, script, completion: finish)
    }

    /// The element under (x, y) (or the focused one), climbed to its control, and its form: facts only, never a value.
    static func probeScript(x: CGFloat?, y: CGFloat?) -> String {
        let pick = x.map { "document.elementFromPoint(\(Double($0)),\(Double(y ?? 0)))" }
            ?? "(function(){var e=document.activeElement;while(e&&e.shadowRoot&&e.shadowRoot.activeElement)e=e.shadowRoot.activeElement;return e;})()"
        return """
        (function(){var e=\(pick);if(!e)return JSON.stringify({});
        var c=e.closest('button,a[href],input,textarea,select,[role=button],[role=link],[role=menuitem],[role=textbox],[contenteditable=""],[contenteditable=true]')||e;
        function r(e){var r=e.getAttribute('role');if(r)return r.toLowerCase();var t=e.tagName.toLowerCase();if(t==='a')return'link';if(t==='button')return'button';
          if(t==='textarea'||e.isContentEditable)return'textbox';if(t==='input'){var y=(e.type||'text').toLowerCase();return(y==='submit'||y==='button'||y==='image'||y==='reset')?'button':'textbox';}return'';}
        function words(e){return[e.getAttribute('aria-label'),e.getAttribute('title'),e.getAttribute('data-tooltip'),
          (e.tagName==='INPUT'&&/^(submit|button|reset)$/i.test(e.type))?e.value:null,(e.innerText||'').slice(0,200)].filter(Boolean).join(' ').replace(/\\s+/g,' ').trim();}
        var f=c.form||c.closest('form');var t=(c.getAttribute('type')||'').toLowerCase();var tag=c.tagName.toLowerCase();
        var submits=!!f&&((tag==='button'&&(t===''||t==='submit'))||(tag==='input'&&(t==='submit'||t==='image'))||(tag==='input'&&!/^(checkbox|radio|button|reset|file)$/.test(t)&&\(x == nil ? "true" : "false")));
        var fields=[];if(f){var all=f.querySelectorAll('input,textarea,select');for(var i=0;i<all.length&&i<40;i++){var g=all[i];
          fields.push([g.getAttribute('autocomplete'),g.getAttribute('name'),g.id,g.type,g.getAttribute('placeholder'),g.getAttribute('aria-label')].filter(Boolean).join(' ').toLowerCase());}}
        return JSON.stringify({role:r(c),tag:tag,text:words(c),type:t,submits:submits,formAction:f?(f.getAttribute('action')||''):'',
          formMethod:f?(f.getAttribute('method')||'get'):'',fields:fields,url:location.href,title:document.title});})()
        """
    }

    // MARK: Results for the model

    /// Text and images of a result; `untrusted`: the page's own text in it (for the injection check).
    static func output(_ r: AgentResult, callID: String) -> (AgentToolOutput, untrusted: [String]) {
        var texts: [String] = []
        var images: [String] = []
        var untrusted: [String] = []
        for part in r.content {
            if part["type"] as? String == "image", let d = part["data"] as? String { images.append(d); continue }
            guard let t = part["text"] as? String else { continue }
            texts.append(t)
            if (part["_meta"] as? [String: Any])?["airc/untrusted"] as? Bool == true { untrusted.append(t) }
        }
        return (AgentToolOutput(callID: callID, texts: texts, images: images, isError: r.isError), untrusted)
    }

    static func text(_ r: AgentResult) -> String {
        r.content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
}

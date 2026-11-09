// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import AppKit

extension WindowController {
    /// Arc's "Peek Email…" (⌘E in Arc 1.171's menu; ⌘E is Extensions in Airc, so it has no key of its own yet): on a
    /// page that just emailed you a sign-in code or link, the newest one from your mail (the mail preview of a pinned
    /// tab or Favorite in this Space's profile) goes into the page. A code is typed into the field you're in, or copied
    /// if no field has focus; a link opens in Peek. With nothing from that site in the last 15 minutes, your inbox
    /// opens in Peek.
    func peekEmail(_ done: ((PeekEmailResult) -> Void)? = nil) {
        ServicePreviewCenter.shared.peekEmail(from: self, done)
    }
}

enum PeekEmailResult: Equatable {
    case typed(String)
    case copied(String)
    case link(URL)
    case inbox(URL)
    /// No mail preview account in this profile (or none opened).
    case noAccount
    /// The page shown isn't a web page.
    case noPage
}

extension ServicePreviewCenter {
    /// The mail accounts of the window's Space's profile: its Favorites and the Space's pinned tabs on a mail site with
    /// a provider, opened in the profile. The first item showing each account.
    func mailAccounts(in c: WindowController) -> [(account: PreviewAccount, itemID: String, url: String)] {
        let profile = c.store.profile(ofSpace: c.currentSpaceID).id
        let pinned = c.store.state.items.values.filter { $0.spaceID == c.currentSpaceID && $0.kind != .folder && $0.kind != .split }
            .sorted { $0.id < $1.id }
        var out: [(PreviewAccount, String, String)] = []
        for item in c.store.favorites(ofProfile: profile) + pinned {
            guard let url = item.savedURL, PreviewService.detect(url)?.family == .mail,
                  let a = account(for: url, profileID: profile), !out.contains(where: { $0.0 == a }) else { continue }
            out.append((a, item.id, url))
        }
        return out.map { (account: $0.0, itemID: $0.1, url: $0.2) }
    }

    /// Asks each account now (a person asked), then answers once all have.
    func fetchNow(_ accounts: [PreviewAccount], _ done: @escaping () -> Void) {
        var left = accounts.count
        guard left > 0 else { return done() }
        for a in accounts {
            guard let p = provider(for: a.service) else { left -= 1; if left == 0 { done() }; continue }
            #if AIRC_TESTING
            if p.fetchesRemotely { stats.remoteFetches.append(a) }
            #endif
            p.fetch(a) { [weak self] state in
                self?.storeAnswer(state, for: a)
                left -= 1
                if left == 0 { done() }
            }
        }
    }

    func peekEmail(from c: WindowController, _ done: ((PeekEmailResult) -> Void)?) {
        func finish(_ r: PeekEmailResult, _ toast: String?) {
            if let toast { c.showToast(toast) }
            done?(r)
        }
        guard let id = c.shownTabID, let page = c.engineTab(for: id), let u = page.url, let host = u.host,
              u.scheme == "https" || u.scheme == "http" else { return finish(.noPage, "Peek Email works on a web page") }
        let accounts = mailAccounts(in: c)
        guard let first = accounts.first else {
            return finish(.noAccount, "Pin your email, or add it to Favorites, to use Peek Email")
        }
        fetchNow(accounts.map(\.account)) { [weak self, weak c] in
            guard let self, let c else { return }
            let mail = accounts.flatMap { a -> [PreviewMail] in
                if case .mail(let m)? = self.state(a.account)?.content { return m }
                return []
            }
            switch SignInMail.find(in: mail, host: host, now: self.now()) {
            case .code(let code)?:
                Self.type(code, into: page) { typed in
                    if typed { return finish(.typed(code), "Entered the code from your email") }
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(code, forType: .string)
                    finish(.copied(code), "Copied the code from your email")
                }
            case .link(let link)?:
                Self.peek(link, from: page, in: c)
                finish(.link(link), nil)
            case nil:
                let inbox = URL(string: first.url) ?? URL(string: "https://mail.google.com/")!
                Self.peek(inbox, from: page, in: c)
                finish(.inbox(inbox), "No sign-in email from \(URLRules.displayHost(u.absoluteString)) in the last 15 minutes")
            }
        }
    }

    static func peek(_ url: URL, from page: EngineTab, in c: WindowController) {
        #if AIRC_TESTING
        if let hook = shared.peekForTesting { return hook(url) }
        #endif
        c.openPeek(url, from: page)
    }

    /// Types `code` into the page's focused field (an input that takes text, a text area or an editable element), as
    /// typing would: the page sees its input events. false when no such field has focus.
    static func type(_ code: String, into page: EngineTab, _ done: @escaping (Bool) -> Void) {
        let literal = (try? String(data: JSONEncoder().encode(code), encoding: .utf8)) ?? "\"\""
        let script = """
            (function(c){var e=document.activeElement;while(e&&e.shadowRoot&&e.shadowRoot.activeElement)e=e.shadowRoot.activeElement;
            if(!e||e===document.body)return false;var t=(e.tagName||'').toLowerCase();
            var ok=(t==='input'&&!/^(checkbox|radio|button|submit|reset|hidden|file|image|range|color)$/i.test(e.type||''))||t==='textarea'||e.isContentEditable;
            if(!ok)return false;e.focus();
            try{if(document.execCommand('insertText',false,c))return true}catch(x){}
            var d=Object.getOwnPropertyDescriptor(Object.getPrototypeOf(e),'value');
            if(d&&d.set){d.set.call(e,(e.value||'')+c);e.dispatchEvent(new Event('input',{bubbles:true}));return true}
            return false})(\(literal))
            """
        page.evaluate(script) { r in DispatchQueue.main.async { done((r as? Bool) ?? ((r as? NSNumber)?.boolValue ?? false)) } }
    }

}

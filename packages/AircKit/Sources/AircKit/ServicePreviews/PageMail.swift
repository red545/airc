// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// S04: a mail card's unread messages, read the way Arc got them: from the account's own page, already signed in, in
/// its own profile. No account of Airc's, no sign-in, no new network permission, nothing sent anywhere else.
///
/// The app runs `script(for:)` in a loaded Gmail or Outlook page of that account (Previews/PageMailProvider.swift)
/// and hands its answer to `state(from:service:now:)`. The script only reads:
/// - Gmail: the inbox's own Atom feed (`/mail/u/N/feed/atom`, the unread messages of the signed-in account, same
///   origin, the page's own cookies), and the inbox list in the page (unread rows) when the feed gives nothing;
/// - Outlook: the message list in the page (its unread rows).
/// It changes nothing in the page: no clicks, no marking read, no storage.
public enum PageMail {
    /// The most messages a card lists (Gmail's feed gives at most 20).
    public static let limit = 30
    /// The most of the feed the page hands back (a real feed is a few kB).
    public static let maxFeedBytes = 400_000

    /// The script for a page of `service`: an expression whose value (a promise) is a JSON string. nil for services
    /// whose content isn't mail. `token` names this read: `cancelScript(token:)` stops it (its feed request is
    /// aborted, and a read whose token was cancelled before it ran never asks anything).
    public static func script(for service: PreviewService, token: Int = 0) -> String? {
        let body: String
        switch service {
        case .gmail: body = gmailScript
        case .outlookMail: body = outlookScript
        default: return nil
        }
        return body.replacingOccurrences(of: "__AIRC_TOKEN__", with: String(max(0, token)))
    }

    /// Stops read `token` in the page it runs in (the same script world): aborts its feed request, and marks it so
    /// that, if it hasn't started yet, it never does.
    public static func cancelScript(token: Int) -> String {
        """
        (function(){var st=window.__aircPageMail=window.__aircPageMail||{dead:{}};st.dead[\(max(0, token))]=1;
        if(st.cur===\(max(0, token))&&st.ctl){try{st.ctl.abort()}catch(e){}}return true})()
        """
    }

    /// The answer of a read that was cancelled before or while it ran.
    public static func wasCancelled(_ answer: String?) -> Bool { answer?.contains("\"cancelled\":true") == true }

    /// Shared by both: text of an element, trimmed and with runs of white space made one space.
    static let helpers = """
        var T=__AIRC_TOKEN__,st=window.__aircPageMail=window.__aircPageMail||{dead:{}};
        if(st.dead[T])return JSON.stringify({cancelled:true});
        st.cur=T;st.ctl=typeof AbortController==='function'?new AbortController():null;
        function tx(e){return e?String(e.textContent||'').replace(/\\s+/g,' ').trim():''}
        function when(s){if(!s)return null;var t=Date.parse(s);return isNaN(t)?null:t}
        """

    static let gmailScript = """
        (async function(){\(helpers)
        var out={v:1,service:'gmail',rows:[],rowsFound:false,title:String(document.title||'')};
        var n=(location.pathname.match(/\\/mail\\/(?:u|b)\\/(\\d+)/)||[])[1]||'0';
        try{
          var r=await fetch(location.origin+'/mail/u/'+n+'/feed/atom',{credentials:'same-origin',cache:'no-store',redirect:'manual',signal:st.ctl?st.ctl.signal:undefined});
          out.feedStatus=r.status;
          if(r.type==='opaqueredirect'||r.status===401||r.status===403){out.signedOut=true}
          else if(r.ok){out.feed=(await r.text()).slice(0,\(maxFeedBytes))}
        }catch(e){out.feedError=String(e).slice(0,200)}
        if(st.dead[T])return JSON.stringify({cancelled:true});
        var rows=document.querySelectorAll('tr.zA');
        out.rowsFound=rows.length>0;
        for(var i=0;i<rows.length&&out.rows.length<\(limit);i++){
          var tr=rows[i];if(!tr.classList.contains('zE'))continue;
          var s=tr.querySelector('[email]');
          var idEl=tr.querySelector('[data-legacy-thread-id]');
          var id=idEl?idEl.getAttribute('data-legacy-thread-id'):(tr.getAttribute('data-thread-id')||tr.id||'');
          var d=tr.querySelector('.xW [title]');
          out.rows.push({id:id,sender:s?(s.getAttribute('name')||tx(s)):'',address:s?s.getAttribute('email'):null,
            subject:tx(tr.querySelector('.bog')),snippet:tx(tr.querySelector('.y2')).replace(/^[-\\u2013\\u2014]\\s*/,''),
            ms:d?when(d.getAttribute('title')):null,url:id?location.origin+'/mail/u/'+n+'/#inbox/'+encodeURIComponent(id):null});
        }
        return JSON.stringify(out);
        })()
        """

    static let outlookScript = """
        (async function(){\(helpers)
        var out={v:1,service:'outlook',rows:[],rowsFound:false,title:String(document.title||'')};
        if(/(^|\\.)login\\.(live|microsoftonline)\\.com$/.test(location.hostname))out.signedOut=true;
        var n=(location.pathname.match(/\\/mail\\/(\\d+)\\//)||[])[1];
        var base=location.origin+'/mail/'+(n!==undefined?n+'/':'');
        var seen=new Set(),rows=[];
        document.querySelectorAll('[role="listbox"] [role="option"],[data-convid]').forEach(function(e){
          var r=e.closest('[data-convid]')||e;if(!seen.has(r)){seen.add(r);rows.push(r)}});
        out.rowsFound=rows.length>0;
        for(var i=0;i<rows.length&&out.rows.length<\(limit);i++){
          var e=rows[i],label=String(e.getAttribute('aria-label')||'');
          var unread=/^\\s*unread\\b/i.test(label)||e.getAttribute('data-unread')==='true'||
            !!e.querySelector('[title="Mark as read"],[aria-label="Mark as read"]');
          if(!unread)continue;
          var id=e.getAttribute('data-convid')||e.getAttribute('data-item-id')||e.id||'';
          var s=e.querySelector('[title*="@"]');
          var t=e.querySelector('time[datetime]'),ms=t?when(t.getAttribute('datetime')):null,dateText=t?tx(t):'';
          if(ms===null){e.querySelectorAll('[title]').forEach(function(x){if(ms===null&&x!==s){var v=when(x.getAttribute('title'));
            if(v!==null&&/\\d/.test(x.getAttribute('title'))){ms=v;dateText=tx(x)}}})}
          var sender=s?tx(s):'',texts=[];
          e.querySelectorAll('span,div').forEach(function(x){
            if(x.children.length||x.closest('button,[role="button"]'))return;var v=tx(x);
            if(v&&v!==sender&&v!==dateText&&texts.indexOf(v)<0)texts.push(v)});
          var subject=texts.shift()||'';
          var snippet=texts.sort(function(a,b){return b.length-a.length})[0]||'';
          out.rows.push({id:id,sender:sender,address:s?s.getAttribute('title'):null,subject:subject,snippet:snippet,ms:ms,
            url:id?base+'inbox/id/'+encodeURIComponent(id):null});
        }
        return JSON.stringify(out);
        })()
        """

    /// What the page's answer means for the card. nil when the page gave nothing usable (no feed and no list in it:
    /// it's on another view, or still loading), so the card keeps what it had.
    public static func state(from answer: String, service: PreviewService, now: Date) -> PreviewState? {
        guard let data = answer.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if o["cancelled"] as? Bool == true { return nil }
        if o["signedOut"] as? Bool == true { return .signedOut }
        if service == .gmail, let feed = o["feed"] as? String, let mail = atom(feed) {
            return .ready(.mail(ordered(mail)))
        }
        guard o["rowsFound"] as? Bool == true else { return nil }
        let rows = o["rows"] as? [[String: Any]] ?? []
        var out: [PreviewMail] = []
        for (i, r) in rows.enumerated() {
            let id = (r["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "row\(i)"
            guard !out.contains(where: { $0.id == id }) else { continue }
            // A row without a time keeps its place (the page lists newest first).
            let date = (r["ms"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? now.addingTimeInterval(-Double(i))
            out.append(PreviewMail(id: id, sender: clean(r["sender"]), senderAddress: (r["address"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                   subject: clean(r["subject"]), snippet: clean(r["snippet"]), date: date, url: r["url"] as? String))
        }
        return .ready(.mail(ordered(out)))
    }

    /// Newest first; equal times keep the page's order.
    static func ordered(_ mail: [PreviewMail]) -> [PreviewMail] {
        Array(mail.enumerated().sorted { ($0.element.date, -$0.offset) > ($1.element.date, -$1.offset) }.map(\.element).prefix(limit))
    }

    private static func clean(_ v: Any?) -> String {
        ((v as? String) ?? "").replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Gmail's Atom feed: its entries (the unread messages), or nil when it isn't a feed.
    public static func atom(_ xml: String) -> [PreviewMail]? {
        guard let data = xml.data(using: .utf8) else { return nil }
        let reader = AtomReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), reader.isFeed else { return nil }
        return reader.entries.enumerated().map { i, e in
            let id = e["id"].flatMap(threadID) ?? e["id"] ?? "entry\(i)"
            let date = (e["issued"] ?? e["modified"] ?? e["updated"]).flatMap(isoDate) ?? .distantPast
            var url = e["link"]
            if let u = url, u.hasPrefix("http://mail.google.com/") { url = "https://" + u.dropFirst("http://".count) }
            return PreviewMail(id: id, sender: clean(e["name"]), senderAddress: e["email"], subject: clean(e["title"]),
                               snippet: clean(e["summary"]), date: date, url: url)
        }
    }

    /// "tag:gmail.google.com,2004:1789" → "1789".
    static func threadID(_ tag: String) -> String? {
        guard let colon = tag.lastIndex(of: ":") else { return nil }
        let s = String(tag[tag.index(after: colon)...])
        return s.isEmpty ? nil : s
    }

    static func isoDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }
}

private final class AtomReader: NSObject, XMLParserDelegate {
    var isFeed = false
    var entries: [[String: String]] = []
    private var entry: [String: String]?
    private var text = ""
    private var inAuthor = false

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        text = ""
        switch name {
        case "feed": isFeed = true
        case "entry": entry = [:]
        case "author": inAuthor = true
        case "link": if entry != nil, entry?["link"] == nil, let h = attributes["href"] { entry?["link"] = h }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""
        guard entry != nil else { return }
        switch name {
        case "entry":
            if let e = entry { entries.append(e) }
            entry = nil
        case "author": inAuthor = false
        case "name", "email": if inAuthor { entry?[name] = value }
        case "title", "summary", "issued", "modified", "updated", "id": entry?[name] = value
        default: break
        }
    }
}

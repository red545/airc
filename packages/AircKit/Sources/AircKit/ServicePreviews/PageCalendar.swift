// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

/// calprev: a calendar card's events, read the way S04 reads mail (PageMail): from the account's own calendar page,
/// already signed in, in its own profile. No account of Airc's, no sign-in, no request to the provider's API, nothing
/// sent anywhere. Arc asked Google Calendar API v3 and Microsoft Graph with an OAuth sign-in; the owner chose the page.
///
/// The app runs `script(for:)` in a loaded Google Calendar or Outlook calendar page of that account
/// (Previews/PageMailProvider.swift) and hands its answer to `state(from:service:now:previous:)`. The script only reads
/// the page's own markup, no request at all:
/// - Google Calendar: the event chips (`[data-eventid]`), each with its screen-reader text ("10am to 10:30am, Standup,
///   Accepted, …, November 14, 2026"), and the day columns they sit in (`[data-datekey]`, Google's packed date);
/// - Outlook: the calendar surface's event buttons (`[data-calitemid]`, `role=button`), each with its aria-label
///   ("Standup, 10:00 AM to 10:30 AM, Friday, November 14, 2026, …").
/// The page shows only its own view (a day, a week, a month): the days it shows replace what was read of them before,
/// the others keep the last answer, so tomorrow stays known while the page shows today.
public enum PageCalendar {
    /// The most event chips a page hands back, and the longest text of one.
    public static let limit = 300
    public static let maxLabel = 400

    /// The script for a calendar page of `service`: an expression whose value (a promise) is a JSON string. nil for
    /// services that aren't calendars. `token` names the read, as PageMail's do (PageMail.cancelScript stops it).
    public static func script(for service: PreviewService, token: Int = 0) -> String? {
        let body: String
        switch service {
        case .googleCalendar: body = googleScript
        case .outlookCalendar: body = outlookScript
        default: return nil
        }
        return body.replacingOccurrences(of: "__AIRC_TOKEN__", with: String(max(0, token)))
    }

    static let googleScript = """
        (async function(){\(PageMail.helpers)\(linkHelpers)
        var out={v:1,service:'gcal',items:[],days:[],gridFound:false,title:String(document.title||'')};
        if(/(^|\\.)accounts\\.google\\.com$/.test(location.hostname))out.signedOut=true;
        var n=(location.pathname.match(/\\/calendar\\/(?:u|b)\\/(\\d+)/)||[])[1]||'0';
        function dk(v){v=parseInt(v,10);if(!(v>0))return null;var y=(v>>9)+1970,m=(v>>5)&15,d=v&31;
          if(m<1||m>12||d<1)return null;return y+'-'+(m<10?'0':'')+m+'-'+(d<10?'0':'')+d}
        document.querySelectorAll('[data-datekey]').forEach(function(e){var k=dk(e.getAttribute('data-datekey'));
          if(k&&out.days.indexOf(k)<0)out.days.push(k)});
        out.gridFound=out.days.length>0;
        var seen={};
        var chips=document.querySelectorAll('[data-eventid]');
        for(var i=0;i<chips.length&&out.items.length<\(limit);i++){
          var e=chips[i],id=e.getAttribute('data-eventid')||'';
          var d=e.querySelector('.XuJrye');
          var label=tx(d)||String(e.getAttribute('aria-label')||'').trim()||tx(e);
          var col=e.closest('[data-datekey]'),day=col?dk(col.getAttribute('data-datekey')):null;
          var key=id+'|'+day+'|'+label;if(seen[key])continue;seen[key]=1;
          out.items.push({id:id,label:label.slice(0,\(maxLabel)),day:day,links:lk(e),
            url:id?location.origin+'/calendar/u/'+n+'/r/eventedit/'+encodeURIComponent(id):null});
        }
        if(chips.length)out.gridFound=true;
        out.details=bubbles('data-eventid');
        return JSON.stringify(out);
        })()
        """

    static let outlookScript = """
        (async function(){\(PageMail.helpers)\(linkHelpers)
        var out={v:1,service:'outlookcal',items:[],days:[],gridFound:false,title:String(document.title||'')};
        if(/(^|\\.)login\\.(live|microsoftonline|microsoft)\\.com$/.test(location.hostname))out.signedOut=true;
        var n=(location.pathname.match(/\\/calendar\\/(\\d+)(\\/|$)/)||[])[1];
        var base=location.origin+'/calendar/'+(n!==undefined?n+'/':'');
        document.querySelectorAll('[data-date]').forEach(function(e){var k=String(e.getAttribute('data-date')||'').slice(0,10);
          if(/^\\d{4}-\\d{2}-\\d{2}$/.test(k)&&out.days.indexOf(k)<0)out.days.push(k)});
        var seen=new Set(),els=document.querySelectorAll('[data-calitemid],[role="main"] [role="button"][aria-label]');
        for(var i=0;i<els.length&&out.items.length<\(limit);i++){
          var e=els[i];if(seen.has(e))continue;seen.add(e);
          var label=String(e.getAttribute('aria-label')||'').trim()||tx(e);
          if(!/\\d/.test(label)&&!/all day/i.test(label))continue;
          var id=e.getAttribute('data-calitemid')||'';
          var col=e.closest('[data-date]'),day=col?String(col.getAttribute('data-date')).slice(0,10):null;
          out.items.push({id:id,label:label.slice(0,\(maxLabel)),day:day,links:lk(e),
            url:id?base+'item/'+encodeURIComponent(id):null});
        }
        out.details=bubbles('data-calitemid');
        out.gridFound=out.days.length>0||out.items.length>0||!!document.querySelector('[role="main"] [role="grid"],[data-app-section="calendar-view"]');
        return JSON.stringify(out);
        })()
        """

    /// calmeet2: links on an event's chip (`lk`: any http(s) address in an attribute of the chip or what's in it, such as a
    /// link's href or a data attribute), and an event's bubble or reading pane the person has open (`bubbles`: a dialog
    /// that names the event by `attr`; Google's "Join with Google Meet", Outlook's "Join"), its links labelled Join first.
    static let linkHelpers = """
        function lk(e){var r=[];if(!e)return r;var all=[e].concat(Array.prototype.slice.call(e.querySelectorAll('*'),0,80));
          for(var i=0;i<all.length&&r.length<8;i++){var at=all[i].attributes||[];for(var j=0;j<at.length&&r.length<8;j++){
            var v=String(at[j].value||'');if(/^https?:\\/\\//i.test(v))r.push(v.slice(0,\(maxLink)))}}return r}
        function jl(root){var join=[],other=[],as=root.querySelectorAll('a[href]');
          for(var i=0;i<as.length&&i<400;i++){var a=as[i],h=String(a.href||'');if(!/^https?:/i.test(h))continue;
            var t=(String(a.getAttribute('aria-label')||'')+' '+tx(a)).toLowerCase();
            (/join|beitreten|rejoindre|unirse|partecipa|deelnemen/.test(t)?join:other).push(h.slice(0,\(maxLink)))}
          return join.concat(other)}
        function bubbles(attr){var r=[],ds=document.querySelectorAll('[role="dialog"],[role="complementary"]');
          for(var i=0;i<ds.length&&r.length<4;i++){var d=ds[i],e=d.hasAttribute(attr)?d:d.querySelector('['+attr+']');
            var id=e?String(e.getAttribute(attr)||''):'';if(!id)continue;r.push({id:id,links:jl(d).concat(lk(d)).slice(0,40)})}
          return r}
        """
    /// The longest address of one link a page hands back.
    public static let maxLink = 1000

    /// What the page's answer means for the card. nil when the page gave nothing usable (not on a calendar view, or
    /// still loading), so the card keeps what it had. `previous`: the account's last events; the days this page
    /// doesn't show keep theirs.
    public static func state(from answer: String, service: PreviewService, now: Date, previous: [CalendarEvent]? = nil,
                             calendar: Calendar = .current) -> PreviewState? {
        guard let data = answer.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if o["cancelled"] as? Bool == true { return nil }
        if o["signedOut"] as? Bool == true { return .signedOut }
        guard o["gridFound"] as? Bool == true else { return nil }
        var shown = Set((o["days"] as? [String] ?? []).compactMap { day($0, calendar: calendar) })
        // An open bubble or reading pane of an event: its call link, by the event's own ID.
        var opened: [String: MeetingLink] = [:]
        for d in o["details"] as? [[String: Any]] ?? [] {
            guard let id = d["id"] as? String, !id.isEmpty, let l = MeetingLink.firstCall(in: d["links"] as? [String] ?? []) else { continue }
            opened[id] = l
        }
        var out: [CalendarEvent] = []
        for item in o["items"] as? [[String: Any]] ?? [] {
            guard let label = item["label"] as? String,
                  let p = parse(label, service: service, day: (item["day"] as? String).flatMap { day($0, calendar: calendar) },
                                calendar: calendar) else { continue }
            let raw = (item["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? stableID(p.title)
            let id = "\(raw)@\(Int(p.start.timeIntervalSince1970))"
            guard !out.contains(where: { $0.id == id }) else { continue }
            // The call: in the chip's text (a Zoom or Teams address in its location), on the chip itself, or in its open bubble.
            let link = MeetingLink.find(url: nil, location: nil, notes: label)
                ?? MeetingLink.firstCall(in: item["links"] as? [String] ?? []) ?? opened[raw]
            out.append(CalendarEvent(id: id, title: p.title, start: p.start, end: p.end, isAllDay: p.allDay, link: link,
                                     response: p.response, url: (item["url"] as? String).flatMap(URL.init(string:))))
            shown.insert(calendar.startOfDay(for: p.start))
        }
        // An event of a day the page doesn't show now is still what was last read of it, until it's over.
        for e in previous ?? [] where e.end > now && !shown.contains(calendar.startOfDay(for: e.start))
            && !out.contains(where: { $0.id == e.id }) {
            out.append(e)
        }
        return .ready(.calendar(out.sorted { ($0.start, $0.id) < ($1.start, $1.id) }))
    }

    /// An ID for an event the page gives none for: the same title gives the same ID in every read.
    static func stableID(_ s: String) -> String {
        var h: UInt32 = 5381
        for b in s.utf8 { h = (h &* 33) ^ UInt32(b) }
        return "t" + String(h, radix: 16)
    }

    /// "2026-11-14": that day's local midnight.
    static func day(_ s: String, calendar: Calendar) -> Date? {
        let p = s.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }

    public struct Parsed: Equatable, Sendable {
        public var title: String
        public var start: Date
        public var end: Date
        public var allDay: Bool
        public var response: CalendarEvent.Response
    }

    /// One event's text: its time ("10am to 10:30am", "10:00 AM to 10:30 AM", "14:00 – 15:00", "All day"), its title
    /// (Google: the part after the time; Outlook: the first part), its day (`day`, from the column, else "November 14,
    /// 2026" or "14 November 2026" in the text) and the person's answer ("Declined", "Tentative"). nil when it isn't an
    /// event's text (a button of the page) or has no day.
    public static func parse(_ label: String, service: PreviewService, day: Date?, calendar: Calendar = .current) -> Parsed? {
        let parts = label.components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let i = parts.firstIndex(where: { timeRange($0) != nil || isAllDay($0) }) else { return nil }
        guard let date = day ?? textDate(label, calendar: calendar) else { return nil }
        let titleIndex: Int
        switch service {
        case .outlookCalendar: titleIndex = i == 0 ? 1 : 0
        default: titleIndex = i + 1
        }
        guard titleIndex < parts.count else { return nil }
        var title = parts[titleIndex]
        if title.isEmpty || title.lowercased() == "no title" { title = "(No title)" }
        let lower = label.lowercased()
        let response: CalendarEvent.Response = lower.contains("declined") ? .declined
            : (lower.contains("tentative") || lower.contains("maybe")) ? .tentative
            : lower.contains("accepted") ? .accepted : .none
        let midnight = calendar.startOfDay(for: date)
        if isAllDay(parts[i]) {
            let end = calendar.date(byAdding: .day, value: 1, to: midnight) ?? midnight.addingTimeInterval(86_400)
            return Parsed(title: title, start: midnight, end: end, allDay: true, response: response)
        }
        guard let r = timeRange(parts[i]),
              let start = calendar.date(byAdding: .minute, value: r.0, to: midnight),
              var end = calendar.date(byAdding: .minute, value: r.1, to: midnight) else { return nil }
        // "11pm to 1am" ends the next day.
        if end <= start { end = calendar.date(byAdding: .day, value: 1, to: end) ?? end.addingTimeInterval(86_400) }
        return Parsed(title: title, start: start, end: end, allDay: false, response: response)
    }

    static func isAllDay(_ s: String) -> Bool { s.lowercased() == "all day" }

    nonisolated(unsafe) private static let range = try! NSRegularExpression(
        pattern: #"^(\d{1,2})(?:[:.](\d{2}))?\s*(?:([ap])\.?\s*m\.?)?\s*(?:to|–|—|-|until)\s*(\d{1,2})(?:[:.](\d{2}))?\s*(?:([ap])\.?\s*m\.?)?$"#,
        options: [.caseInsensitive])

    /// Minutes after midnight of a time range's start and end; a start without am/pm takes the end's ("10 to 11am").
    static func timeRange(_ s: String) -> (Int, Int)? {
        let ns = s as NSString
        guard let m = range.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func g(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)).lowercased() }
        guard let h1 = g(1).flatMap(Int.init), let h2 = g(4).flatMap(Int.init) else { return nil }
        let m1 = g(2).flatMap(Int.init) ?? 0, m2 = g(5).flatMap(Int.init) ?? 0
        let p2 = g(6), p1 = g(3) ?? p2
        func minutes(_ h: Int, _ m: Int, _ p: String?) -> Int? {
            guard m < 60 else { return nil }
            if let p {
                guard (1...12).contains(h) else { return nil }
                return ((h % 12) + (p == "p" ? 12 : 0)) * 60 + m
            }
            return h <= 24 ? h * 60 + m : nil
        }
        guard let a = minutes(h1, m1, p1), let b = minutes(h2, m2, p2) else { return nil }
        return (a, b)
    }

    private static let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september",
                                 "october", "november", "december"]
    nonisolated(unsafe) private static let monthFirst = try! NSRegularExpression(
        pattern: #"\b([A-Za-z]{3,9})\.? (\d{1,2}),? (\d{4})\b"#)
    nonisolated(unsafe) private static let dayFirst = try! NSRegularExpression(
        pattern: #"\b(\d{1,2}) ([A-Za-z]{3,9})\.?,? (\d{4})\b"#)

    /// "November 14, 2026", "Nov 14, 2026" or "14 November 2026" in an event's text (English month names).
    static func textDate(_ s: String, calendar: Calendar) -> Date? {
        let ns = s as NSString
        let all = NSRange(location: 0, length: ns.length)
        func month(_ name: String) -> Int? {
            let n = name.lowercased()
            guard n.count >= 3 else { return nil }
            return months.firstIndex { $0.hasPrefix(n) || n.hasPrefix($0) }.map { $0 + 1 }
        }
        for m in monthFirst.matches(in: s, range: all) {
            if let mo = month(ns.substring(with: m.range(at: 1))), let d = Int(ns.substring(with: m.range(at: 2))),
               let y = Int(ns.substring(with: m.range(at: 3))) {
                return calendar.date(from: DateComponents(year: y, month: mo, day: d))
            }
        }
        for m in dayFirst.matches(in: s, range: all) {
            if let mo = month(ns.substring(with: m.range(at: 2))), let d = Int(ns.substring(with: m.range(at: 1))),
               let y = Int(ns.substring(with: m.range(at: 3))) {
                return calendar.date(from: DateComponents(year: y, month: mo, day: d))
            }
        }
        return nil
    }

    /// The card's events (Arc's preview, M08's day list): what's left of today and tomorrow, not declined, all-day
    /// ones first in their day, then by start.
    public static func upcoming(_ events: [CalendarEvent], now: Date, calendar: Calendar = .current) -> [CalendarEvent] {
        let today = calendar.startOfDay(for: now)
        let horizon = calendar.date(byAdding: .day, value: 2, to: today) ?? today.addingTimeInterval(2 * 86_400)
        return events.filter { $0.end > now && $0.start < horizon && $0.response != .declined && $0.kind != .workingLocation }
            .sorted {
                let d0 = max(today, calendar.startOfDay(for: $0.start)), d1 = max(today, calendar.startOfDay(for: $1.start))
                if d0 != d1 { return d0 < d1 }
                if $0.isAllDay != $1.isAllDay { return $0.isAllDay }
                return ($0.start, $0.id) < ($1.start, $1.id)
            }
    }

    // MARK: calmeet2: the next meeting's call, from its own page

    /// How long a detail read waits for the event's page to show its call link, and, once that page has loaded, for
    /// one to appear.
    public static let detailWait: Double = 15
    public static let detailSettle: Double = 6

    /// The script that reads the call link of one event from its own page (`url`: the event's page on the calendar
    /// page's own origin, CalendarEvent.url), for a meeting whose chip has none. Read-only and out of sight: the event's
    /// page loads in a hidden, sandboxed frame of the calendar page itself (same profile, same origin, its own cookies),
    /// which can't navigate the page, open windows, submit forms or show dialogs; the frame goes as soon as a call link
    /// shows, or after `detailWait` seconds. nil for services that aren't calendars, or a page on another origin.
    public static func detailScript(for service: PreviewService, url: URL, token: Int = 0) -> String? {
        guard service == .googleCalendar || service == .outlookCalendar,
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let json = try? JSONSerialization.data(withJSONObject: [url.absoluteString]),
              let quoted = String(data: json, encoding: .utf8) else { return nil }
        let body = """
            (async function(){\(PageMail.helpers)\(linkHelpers)
            var D=st.detail=st.detail||{};
            var out={v:1,detail:true,links:[],loaded:false};
            var u;try{u=new URL(\(quoted)[0],location.href)}catch(e){return JSON.stringify(out)}
            if(u.origin!==location.origin){out.otherOrigin=true;return JSON.stringify(out)}
            var CALL=/^https?:\\/\\/([^\\/?#]*\\.)?(meet\\.google\\.|zoom\\.us|zoomgov\\.com|teams\\.microsoft\\.com|teams\\.live\\.com|webex\\.com|around\\.co|[a-z0-9-]+\\.safelinks\\.protection\\.outlook\\.com)/i;
            D[T]={pending:true};
            (async function(){
            var f=document.createElement('iframe');
            f.setAttribute('sandbox','allow-same-origin allow-scripts');
            f.setAttribute('aria-hidden','true');f.setAttribute('tabindex','-1');
            f.style.cssText='position:fixed;left:-30000px;top:0;width:1100px;height:800px;border:0;opacity:0;pointer-events:none';
            var loadedAt=0,found=null,last=[];
            function scan(){var d;try{d=f.contentDocument}catch(e){return}if(!d||!d.body)return;
              var l=jl(d.body),m=String(d.body.innerText||'').slice(0,20000).match(/https?:\\/\\/[^\\s<>"']+/g)||[];
              last=l.concat(m.slice(0,40));for(var i=0;i<last.length;i++)if(CALL.test(last[i])){found=last;return}}
            var done;var p=new Promise(function(r){done=r});
            var mo=null,lastScan=0;
            function poke(){if(found||st.dead[T])return done();var t=Date.now();if(t-lastScan<150)return;lastScan=t;scan();
              if(found)return done();if(loadedAt&&t-loadedAt>\(Int(detailSettle * 1000)))done()}
            f.addEventListener('load',function(){loadedAt=Date.now();try{mo=new MutationObserver(poke);
              mo.observe(f.contentDocument,{subtree:true,childList:true,attributes:true,attributeFilter:['href']})}catch(e){}poke()});
            var timer=setInterval(poke,500),stop=setTimeout(function(){done()},\(Int(detailWait * 1000)));
            try{f.src=u.href;(document.body||document.documentElement).appendChild(f);await p}catch(e){}
            finally{clearInterval(timer);clearTimeout(stop);try{mo&&mo.disconnect()}catch(e){}scan();f.remove()}
            if(st.dead[T]){D[T]={cancelled:true};return}
            out.loaded=loadedAt>0;out.links=(found||last).slice(0,80);D[T]=out;
            })();
            return JSON.stringify({v:1,detail:true,pending:true});
            })()
            """
        return body.replacingOccurrences(of: "__AIRC_TOKEN__", with: String(max(0, token)))
    }

    /// The detail read's answer once it's done: `{"pending":true}` while its frame is still loading. A read is started
    /// by `detailScript` (which answers at once, so no engine's evaluate times out on a slow page) and then asked with
    /// this about once a second in the same page and script world.
    public static func detailPollScript(token: Int) -> String {
        """
        (function(){var st=window.__aircPageMail||{},D=st.detail||{},r=D[\(max(0, token))];
        if(!r)return JSON.stringify({detail:true,gone:true});if(r.pending)return JSON.stringify({pending:true});
        delete D[\(max(0, token))];return JSON.stringify(r)})()
        """
    }

    /// Whether a detail read's answer says it's still on its way.
    public static func detailPending(_ answer: String?) -> Bool { answer?.contains("\"pending\":true") == true }

    /// What a detail read found.
    public enum DetailResult: Equatable, Sendable {
        /// The event's call.
        case link(MeetingLink)
        /// The event's page loaded and shows no call: an event without one.
        case noCall
        /// Nothing usable came back (the page didn't load, the read was stopped): ask again later.
        case failed
    }

    public static func detailResult(from answer: String?) -> DetailResult {
        guard let data = answer?.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], o["detail"] as? Bool == true else { return .failed }
        if let l = MeetingLink.firstCall(in: o["links"] as? [String] ?? []) { return .link(l) }
        return o["loaded"] as? Bool == true ? .noCall : .failed
    }
}

/// calmeet2: call links read from meetings' own pages (PageCalendar.detailScript), per event, kept until the event's
/// chip changes (its title, time or page). Only the next meeting is ever read: the one the tile counts down to, when its
/// chip has no call link.
public struct CalendarDetailLinks: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var fingerprint: String
        public var link: MeetingLink?
        public var at: Date
    }
    public private(set) var entries: [String: Entry] = [:]
    /// A page that showed no call, or a read that failed, is asked again after this long (a call added to the invitation).
    public static let retryAfter: TimeInterval = 10 * 60

    public init() {}

    static func fingerprint(_ e: CalendarEvent) -> String {
        "\(e.title)|\(Int(e.start.timeIntervalSince1970))|\(Int(e.end.timeIntervalSince1970))|\(e.url?.absoluteString ?? "")"
    }

    /// `events` with the links read for them, where the chip itself has none and the event hasn't changed since.
    public func apply(_ events: [CalendarEvent]) -> [CalendarEvent] {
        events.map { e in
            guard e.link == nil, let x = entries[e.id], x.fingerprint == Self.fingerprint(e), let l = x.link else { return e }
            var e = e
            e.link = l
            return e
        }
    }

    /// The meeting to read the page of now, if any: the countdown's meeting (MeetingSchedule.countdownEvent, within the
    /// hour), with no call link, with a page of its own, not read already (or read without a call over `retryAfter` ago).
    public func candidate(_ events: [CalendarEvent], now: Date) -> CalendarEvent? {
        guard let e = MeetingSchedule.countdownEvent(apply(events), now: now), e.link == nil, e.url != nil else { return nil }
        if let x = entries[e.id], x.fingerprint == Self.fingerprint(e), x.link != nil || now.timeIntervalSince(x.at) < Self.retryAfter {
            return nil
        }
        return e
    }

    public mutating func store(_ result: PageCalendar.DetailResult, for e: CalendarEvent, now: Date) {
        let link: MeetingLink? = { if case .link(let l) = result { return l }; return nil }()
        entries[e.id] = Entry(fingerprint: Self.fingerprint(e), link: link, at: now)
    }

    /// Forgets events that are gone from `events` (or over), so the cache stays as small as the calendar's day.
    public mutating func prune(keeping events: [CalendarEvent], now: Date) {
        let live = Set(events.filter { $0.end > now }.map(\.id))
        entries = entries.filter { live.contains($0.key) }
    }
}

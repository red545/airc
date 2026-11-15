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
        (async function(){\(PageMail.helpers)
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
          out.items.push({id:id,label:label.slice(0,\(maxLabel)),day:day,
            url:id?location.origin+'/calendar/u/'+n+'/r/eventedit/'+encodeURIComponent(id):null});
        }
        if(chips.length)out.gridFound=true;
        return JSON.stringify(out);
        })()
        """

    static let outlookScript = """
        (async function(){\(PageMail.helpers)
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
          out.items.push({id:id,label:label.slice(0,\(maxLabel)),day:day,
            url:id?base+'item/'+encodeURIComponent(id):null});
        }
        out.gridFound=out.days.length>0||out.items.length>0||!!document.querySelector('[role="main"] [role="grid"],[data-app-section="calendar-view"]');
        return JSON.stringify(out);
        })()
        """

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
        var out: [CalendarEvent] = []
        for item in o["items"] as? [[String: Any]] ?? [] {
            guard let label = item["label"] as? String,
                  let p = parse(label, service: service, day: (item["day"] as? String).flatMap { day($0, calendar: calendar) },
                                calendar: calendar) else { continue }
            let raw = (item["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? stableID(p.title)
            let id = "\(raw)@\(Int(p.start.timeIntervalSince1970))"
            guard !out.contains(where: { $0.id == id }) else { continue }
            let link = MeetingLink.find(url: nil, location: nil, notes: label)
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
}

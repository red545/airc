// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

/// The calendar card's hour grid (calgrid), as Arc 1.171's calendar preview laid it out (CalendarLayout: hour lines,
/// overlapping events side by side in columns, a line at now). Arc's card showed six hours starting 15 minutes before
/// now and nothing else; it had no separate list for tomorrow (the grid simply ran on past midnight). Airc's grid shows
/// the same six hours when the card opens (CardLayout fits them, as Arc did) and scrolls over the rest of today (and
/// past midnight while those six hours reach into tomorrow); tomorrow's later events follow under the grid in one line.
///
/// Every time is an absolute moment: a page read in another time zone hands back moments (PageCalendar), and the grid
/// places them on the Mac's own hours (`calendar`).
public enum PreviewTimeline {
    /// Arc: the grid begins 15 minutes before now (CalendarLayout's `now.addingTimeInterval(-900)`).
    public static let lead: TimeInterval = 15 * 60
    /// Arc: and shows six hours (`+ 21600`).
    public static let visibleHours = 6

    /// What Arc's card showed: from 15 minutes before now, six hours.
    public static func visible(now: Date) -> DateInterval {
        DateInterval(start: now.addingTimeInterval(-lead), duration: TimeInterval(visibleHours) * 3600)
    }

    /// What the grid covers (it scrolls): from the start of today (or of the hour 15 minutes back, just after
    /// midnight) to the end of today, or on to the whole hour after `visible(now:)` when that reaches past midnight.
    /// Hours are the calendar's: in a zone half an hour off UTC they start at :30 UTC.
    public static func window(now: Date, calendar: Calendar = .current) -> DateInterval {
        let v = visible(now: now)
        let day = calendar.dateInterval(of: .day, for: now) ?? DateInterval(start: now, duration: 86_400)
        let start = min(day.start, calendar.dateInterval(of: .hour, for: v.start)?.start ?? v.start)
        let lastHour = calendar.dateInterval(of: .hour, for: v.end)
        let visibleEnd = lastHour.map { $0.start == v.end ? v.end : $0.end } ?? v.end
        return DateInterval(start: start, end: max(day.end, visibleEnd))
    }

    /// The hour lines to draw and label, in the calendar's time zone ("2 PM").
    public static func hours(in w: DateInterval, calendar: Calendar = .current) -> [Date] {
        var out: [Date] = []
        var t = calendar.dateInterval(of: .hour, for: w.start)?.start ?? w.start
        if t < w.start, let next = calendar.date(byAdding: .hour, value: 1, to: t) { t = next }
        while t < w.end {
            out.append(t)
            guard let next = calendar.date(byAdding: .hour, value: 1, to: t), next > t else { break }
            t = next
        }
        return out
    }

    /// Where `date` sits in the grid, in points from its top.
    public static func offset(of date: Date, in w: DateInterval, hourHeight: Double) -> Double {
        date.timeIntervalSince(w.start) / 3600 * hourHeight
    }

    /// The events the card shows at all: not declined, not a working-location marker.
    static func shown(_ e: CalendarEvent) -> Bool { e.response != .declined && e.kind != .workingLocation }

    public struct Block: Equatable, Sendable {
        public var event: CalendarEvent
        /// Side by side with the events it overlaps: its column and how many there are.
        public var column: Int
        public var columns: Int
        /// Its top and bottom in the grid, clipped to the window (an event from yesterday starts at the top, one past
        /// the window's end stops at the bottom).
        public var start: Date
        public var end: Date
    }

    /// The timed events that show in `w`, each in a column beside the ones it overlaps (a cluster of overlapping events
    /// shares its columns, as Arc's OverlapGroup did). All-day events are left out: the card shows those in a strip
    /// above the hours. Declined events are left out.
    public static func layout(_ events: [CalendarEvent], in w: DateInterval) -> [Block] {
        let inWindow = events.filter { !$0.isAllDay && shown($0) && $0.end > w.start && $0.start < w.end }
            .sorted { ($0.start, $0.end, $0.id) < ($1.start, $1.end, $1.id) }
        var out: [Block] = []
        var cluster: [(CalendarEvent, Int)] = []
        var clusterEnd = Date.distantPast
        var columnEnds: [Date] = []
        func flush() {
            let n = max(1, columnEnds.count)
            out += cluster.map { Block(event: $0.0, column: $0.1, columns: n, start: max($0.0.start, w.start), end: min(max($0.0.end, $0.0.start), w.end)) }
            cluster = []
            columnEnds = []
        }
        for e in inWindow {
            if e.start >= clusterEnd { flush() }
            // The first column free by this start, else a new one.
            let col = columnEnds.firstIndex { $0 <= e.start } ?? columnEnds.count
            if col == columnEnds.count { columnEnds.append(e.end) } else { columnEnds[col] = e.end }
            cluster.append((e, col))
            clusterEnd = max(clusterEnd, e.end)
        }
        flush()
        return out
    }

    /// Today's all-day events for the strip above the hours: any that cover part of today, by start.
    public static func allDay(_ events: [CalendarEvent], now: Date, calendar: Calendar = .current) -> [CalendarEvent] {
        guard let day = calendar.dateInterval(of: .day, for: now) else { return [] }
        return events.filter { $0.isAllDay && shown($0) && $0.start < day.end && $0.end > day.start }
            .sorted { ($0.start, $0.title, $0.id) < ($1.start, $1.title, $1.id) }
    }

    /// Tomorrow's events the grid doesn't reach: the all-day ones that begin tomorrow, then the timed ones that start
    /// after the grid ends, by start. (An event the grid shows past midnight isn't listed again.)
    public static func tomorrow(_ events: [CalendarEvent], now: Date, calendar: Calendar = .current) -> [CalendarEvent] {
        guard let today = calendar.dateInterval(of: .day, for: now),
              let next = calendar.dateInterval(of: .day, for: today.end) else { return [] }
        let gridEnd = window(now: now, calendar: calendar).end
        return events.filter { e in
            shown(e) && e.start >= next.start && e.start < next.end && (e.isAllDay || e.start >= gridEnd)
        }
        .sorted {
            if $0.isAllDay != $1.isAllDay { return $0.isAllDay }
            return ($0.start, $0.id) < ($1.start, $1.id)
        }
    }

    /// Meetings with a call that are moments away or on now (MeetingSchedule.soonJoin): the card's big Join (Arc's
    /// QuickJoinButton), soonest first.
    public static func soon(_ events: [CalendarEvent], now: Date) -> [CalendarEvent] {
        events.filter { $0.link != nil && !$0.isAllDay && shown($0) && $0.start.timeIntervalSince(now) <= MeetingSchedule.soonJoin && now < $0.end }
            .sorted { ($0.start, $0.id) < ($1.start, $1.id) }
    }

    /// calcard: the calendar card top to bottom, and the hour height that fits Arc's six hours in the room the grid
    /// has. Arc's CalendarLayout had no fixed hour height: it placed `now - 900 s … + 21600 s` over its view's whole
    /// height (an hour line's y is `viewRect.minY + (t - start) / 21600 × viewRect.height`), so the six hours were
    /// always the whole grid, whatever else the card showed. Airc does the same, within readable bounds: an hour is at
    /// most `maxHourHeight` (a card with room to spare shows a little more than six hours) and never under
    /// `minHourHeight`. The card is `calendarCardHeight` tall (taller than the mail card), so that even with the Join,
    /// the all-day strip and Tomorrow an hour keeps about 36 pt; a short window may make the card smaller.
    public struct CardLayout: Equatable, Sendable {
        /// The card's title row ("Google Calendar").
        public static let header = 26.0
        /// Arc's big Join (AircButton regular).
        public static let join = 30.0
        /// Today's all-day events: one line of chips and "+N".
        public static let allDay = 18.0
        /// Tomorrow: one line of chips and "+N" under the grid (Arc had none).
        public static let tomorrow = 20.0
        public static let spacing = 4.0
        /// Under Tomorrow.
        public static let bottom = 6.0
        /// Room above the first hour's label at the top of the grid and below the last.
        public static let topInset = 7.0
        public static let bottomInset = 7.0
        public static let maxHourHeight = 48.0
        public static let minHourHeight = 24.0
        /// The calendar card's height when the window has room (the mail and pages cards are 268 pt).
        public static let calendarCardHeight = 340.0

        public var cardHeight: Double
        public var join: Bool
        public var allDay: Bool
        public var tomorrow: Bool

        public init(cardHeight: Double = calendarCardHeight, join: Bool, allDay: Bool, tomorrow: Bool) {
            self.cardHeight = cardHeight
            self.join = join
            self.allDay = allDay
            self.tomorrow = tomorrow
        }

        /// What `events` put on the card at `now`.
        public init(_ events: [CalendarEvent], now: Date, cardHeight: Double = calendarCardHeight, calendar: Calendar = .current) {
            self.init(cardHeight: cardHeight, join: !PreviewTimeline.soon(events, now: now).isEmpty,
                      allDay: !PreviewTimeline.allDay(events, now: now, calendar: calendar).isEmpty,
                      tomorrow: !PreviewTimeline.tomorrow(events, now: now, calendar: calendar).isEmpty)
        }

        /// The grid's height: what the header, the Join, the all-day strip and Tomorrow leave.
        public var gridHeight: Double {
            cardHeight - Self.header - (join ? Self.join + Self.spacing : 0) - (allDay ? Self.allDay + Self.spacing : 0)
                - (tomorrow ? Self.spacing + Self.tomorrow + Self.bottom : 0)
        }

        /// Six hours over the grid, as Arc, between the bounds.
        public var hourHeight: Double {
            min(Self.maxHourHeight, max(Self.minHourHeight, (gridHeight - Self.topInset - Self.bottomInset) / Double(PreviewTimeline.visibleHours)))
        }

        /// How many hours from 15 minutes before now show without scrolling (the grid opens with that moment
        /// `topInset` below its top).
        public var visibleHours: Double { (gridHeight - Self.topInset) / hourHeight }
    }
}

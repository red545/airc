// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

/// When a live folder refreshes (LiveFolders.swift): on a timer, when a window comes to the front with a list older
/// than a minute, and from Refresh in its menu. After a failure it waits longer each time; after GitHub's rate limit
/// it waits for GitHub's reset; signed out it waits for a sign-in.
public enum LiveFolderSchedule {
    /// The timer. Arc's own interval wasn't recovered; three minutes keeps an unauthenticated folder well inside
    /// GitHub's 60 requests an hour (an unchanged list answers 304, which GitHub doesn't count).
    public static let interval: TimeInterval = 180
    /// A window coming to the front refreshes a list older than this.
    public static let focusStaleness: TimeInterval = 60
    /// The longest wait after repeated failures.
    public static let maxBackoff: TimeInterval = 30 * 60

    /// Why a refresh is asked for.
    public enum Trigger: Sendable { case timer, focus, manual }

    /// Whether a folder refreshes now.
    public static func isDue(_ d: LiveFolderDefinition, trigger: Trigger, now: Date) -> Bool {
        if case .rateLimited = d.status, let next = d.nextAllowed, next > now { return false }   // never past GitHub's reset
        if trigger == .manual { return true }
        if d.status == .signedOut { return false }   // a sign-in refreshes it
        if let next = d.nextAllowed, next > now { return false }
        guard let last = d.lastAttempt ?? d.lastRefreshed else { return true }
        let age = now.timeIntervalSince(last)
        switch trigger {
        case .timer: return age >= interval - 1
        case .focus: return age >= focusStaleness
        case .manual: return true
        }
    }

    /// When the timer next has something to do for this folder: the first moment `isDue(d, trigger: .timer, …)` holds
    /// (never before `now`), or nil while only a sign-in can refresh it. The app arms one timer for the earliest folder
    /// instead of waking on a fixed tick (MEM-6).
    public static func nextTimerRefresh(_ d: LiveFolderDefinition, now: Date) -> Date? {
        if d.status == .signedOut { return nil }
        var at = (d.lastAttempt ?? d.lastRefreshed).map { $0.addingTimeInterval(interval - 1) } ?? now
        if let next = d.nextAllowed { at = max(at, next) }
        return max(at, now)
    }

    /// The earliest automatic retry after a failure.
    public static func nextAttempt(after status: LiveFolderStatus, failures: Int, retryAt: Date?, now: Date) -> Date? {
        switch status {
        case .ok, .signedOut: return nil
        case .rateLimited(let until):
            let reset = retryAt ?? until
            return max(reset.map { $0.addingTimeInterval(1) } ?? now, now.addingTimeInterval(backoff(failures)))
        case .offline, .notFound, .failed:
            return now.addingTimeInterval(backoff(failures))
        }
    }

    /// 1, 2, 4, 8… minutes, at most `maxBackoff`.
    public static func backoff(_ failures: Int) -> TimeInterval {
        min(maxBackoff, 60 * pow(2, Double(max(0, failures - 1))))
    }
}

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

/// One bounded attempt per profile; only an explicit new sign-in resets an exhausted attempt.
public struct ProfileSignInPolling {
    private struct Attempt { var start: Date; var next: Date; var count = 0; var requestedFinalProbe = false }
    private var attempts: [String: Attempt] = [:]
    public init() {}
    public mutating func restart(_ id: String) { attempts[id] = nil }
    public func isActive(_ id: String, now: Date) -> Bool {
        attempts[id].map { now.timeIntervalSince($0.start) < 300 } ?? false
    }
    /// Expedite one account read after the sign-in tab redirects, preserving the original deadline.
    @discardableResult public mutating func requestFinalProbe(_ id: String, now: Date) -> Bool {
        guard var attempt = attempts[id], isActive(id, now: now), !attempt.requestedFinalProbe else { return false }
        attempt.requestedFinalProbe = true
        attempt.next = now
        attempts[id] = attempt
        return true
    }
    public mutating func due(_ ids: Set<String>, now: Date) -> [String] {
        var due: [String] = []
        for id in ids {
            var a = attempts[id] ?? Attempt(start: now, next: now)
            if now.timeIntervalSince(a.start) < 300, now >= a.next {
                due.append(id)
                a.next = now.addingTimeInterval(a.count == 0 ? 5 : a.count == 1 ? 15 : 60)
                a.count += 1
            }
            attempts[id] = a
        }
        return due
    }
    public func next(_ ids: Set<String>, now: Date) -> Date? {
        ids.compactMap { attempts[$0] }.filter { now.timeIntervalSince($0.start) < 300 }
            .map { min($0.next, $0.start.addingTimeInterval(300)) }.min()
    }
}

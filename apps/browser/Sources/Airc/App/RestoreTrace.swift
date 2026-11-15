// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation
import QuartzCore
import os

/// Opt-in phase timings for the synthetic restore check. Normal browsing records nothing.
enum RestoreTrace {
    struct Span {
        let name: StaticString
        let started: CFTimeInterval
        let id: OSSignpostID
    }
    #if AIRC_TESTING
    static var enabled = false
    #else
    static let enabled = false
    #endif
    private static let log = OSLog(subsystem: "org.airc", category: "Restore")
    private static var origin: CFTimeInterval = 0
    private static var samples: [String] = []

    static func reset(at time: CFTimeInterval) { origin = time; samples = [] }
    static func begin(_ name: StaticString) -> Span? {
        guard enabled else { return nil }
        let span = Span(name: name, started: CACurrentMediaTime(), id: OSSignpostID(log: log))
        os_signpost(.begin, log: log, name: name, signpostID: span.id)
        return span
    }
    static func end(_ span: Span?) {
        guard let span else { return }
        let end = CACurrentMediaTime()
        os_signpost(.end, log: log, name: span.name, signpostID: span.id)
        if samples.count < 200 {
            samples.append(String(format: "%@ %.2f…%.2f ms (%.2f ms)", String(describing: span.name),
                                  (span.started - origin) * 1000, (end - origin) * 1000, (end - span.started) * 1000))
        }
    }
    static func report() -> String { samples.joined(separator: "; ") }
}

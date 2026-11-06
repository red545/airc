// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

/// Numbers leave Airc only as buckets: a range label such as "6-10" or "250-500", never the exact value. Each scale's
/// labels are fixed (`labels`), so the allowlist test can check every value an event can carry.
public enum TelemetryBucket {
    public struct Scale: Sendable {
        /// Upper bounds, ascending: a value v falls in the first bucket whose bound is > v; past the last, "<last>+".
        public let bounds: [Double]
        /// Labels for the first values one by one (counts: "0", "1", "2"), before the ranges start.
        public let exact: Int

        /// Every label this scale produces, in order.
        public var labels: [String] {
            var out: [String] = []
            var lower = Double(exact)
            if exact > 0 { out += (0..<exact).map(String.init) }
            for (i, b) in bounds.enumerated() {
                if i == 0, exact == 0 { out.append("<" + Self.format(b)) } else { out.append(range(lower, b)) }
                lower = b
            }
            out.append(Self.format(bounds.last ?? lower) + "+")
            return out
        }

        public func label(_ value: Double) -> String {
            let v = value.isFinite ? max(0, value) : 0
            if exact > 0, v < Double(exact) { return String(Int(v)) }
            var lower = Double(exact)
            for (i, b) in bounds.enumerated() {
                if v < b { return i == 0 && exact == 0 ? "<" + Self.format(b) : range(lower, b) }
                lower = b
            }
            return Self.format(bounds.last ?? lower) + "+"
        }

        /// Integer scales show inclusive ranges ("3-5" holds 3, 4 and 5); continuous ones half-open ("250-500").
        private func range(_ lower: Double, _ upper: Double) -> String {
            exact > 0 ? "\(Self.format(lower))-\(Self.format(upper - 1))" : "\(Self.format(lower))-\(Self.format(upper))"
        }

        private static func format(_ v: Double) -> String {
            v == v.rounded() ? String(Int(v)) : String(v)
        }
    }

    /// Spaces, tabs, profiles: 0, 1, 2, 3-5, 6-10, 11-20, 21-50, 51-100, 101-200, 201-500, 501+.
    public static let counts = Scale(bounds: [6, 11, 21, 51, 101, 201, 501], exact: 3)
    /// Launch to first window.
    public static let launch = Scale(bounds: [250, 500, 750, 1000, 1500, 2000, 3000, 5000, 10000], exact: 0)
    /// One frame's worth of work: the Command Bar's budget is a 120 Hz frame (8 ms).
    public static let frame = Scale(bounds: [4, 8, 12, 16, 25, 33, 50, 100, 250], exact: 0)
    public static let memory = Scale(bounds: [100, 250, 500, 750, 1000, 1500, 2000, 4000], exact: 0)
    public static let cpu = Scale(bounds: [0.5, 1, 2, 5, 10, 25], exact: 0)
    /// Days since the install ID was made: 0, 1, 2-7, 8-30, 31-90, 91-180, 181-365, 366+.
    public static let installAge = Scale(bounds: [8, 31, 91, 181, 366], exact: 2)

    public static func count(_ n: Int) -> String { counts.label(Double(n)) }
    public static func launchMilliseconds(_ ms: Double) -> String { launch.label(ms) }
    public static func frameMilliseconds(_ ms: Double) -> String { frame.label(ms) }
    public static func megabytes(_ mb: Double) -> String { memory.label(mb) }
    public static func percent(_ p: Double) -> String { cpu.label(p) }
    public static func days(_ d: Int) -> String { installAge.label(Double(d)) }
}

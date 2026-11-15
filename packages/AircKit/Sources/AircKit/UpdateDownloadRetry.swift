// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

/// One automatic retry for an update download that stalled or lost its connection (updretry).
///
/// On some routes a download from the update host stops mid-body: the far end has dropped the flow and nothing more
/// arrives until the request times out. Sparkle 2 never retries (a failed delta falls back to the full archive once,
/// then the update aborts), so the app (AircUpdateDelegate) gives each such failure one quiet background check:
/// - `idleTimeout` replaces the default 60 s idle timeout of update downloads, so a stall fails in about 20 s;
/// - `Gate` allows one retry per failure and never a retry of a retry;
/// - only a download error whose cause is a timeout or a lost connection qualifies, never a signature, validation,
///   disk or HTTP error, and only while automatic checks and downloads are on, so the retry stays silent.
public enum UpdateDownloadRetry {
    /// Seconds without bytes before an update download gives up (URLRequest.timeoutInterval).
    public static let idleTimeout: TimeInterval = 20
    /// Seconds between the failed cycle's end and the retry's background check.
    public static let delay: TimeInterval = 5

    /// Sparkle's SUSparkleErrorDomain and SUDownloadError (SUErrors.h), spelled out so AircKit needs no Sparkle.
    static let sparkleDomain = "SUSparkleErrorDomain"
    static let sparkleDownloadError = 2001

    /// A Sparkle download error (2001) caused, somewhere down its underlying errors, by a timeout or a lost connection.
    /// Sparkle wraps the transport error once or twice (SPUDownloadDriver and SPUDownloader both add a 2001 layer).
    public static func isRetriable(_ error: Error) -> Bool {
        let top = error as NSError
        guard top.domain == sparkleDomain, top.code == sparkleDownloadError else { return false }
        var current: NSError? = top
        for _ in 0..<6 {
            guard let e = current else { break }
            if e.domain == NSURLErrorDomain, [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost].contains(e.code) { return true }
            if e.domain == NSPOSIXErrorDomain, [Int(ETIMEDOUT), Int(ECONNRESET)].contains(e.code) { return true }
            // Another 2001 layer: look at its cause. Anything else (a file, signature or HTTP error) never retries.
            guard e.domain == sparkleDomain, e.code == sparkleDownloadError else { return false }
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    /// The lowest error in the chain, for the log line.
    public static func rootCause(_ error: Error) -> NSError {
        var e = error as NSError
        for _ in 0..<6 { guard let next = e.userInfo[NSUnderlyingErrorKey] as? NSError else { break }; e = next }
        return e
    }

    /// At most one retry per failure: idle → scheduled (waiting `delay`) → running (its own check) → idle.
    public struct Gate: Equatable, Sendable {
        public enum State: Equatable, Sendable { case idle, scheduled, running }
        public private(set) var state: State = .idle
        public init() {}

        /// An update cycle ended. True when the caller should schedule the retry.
        /// `allowed`: automatic checks and automatic downloads are both on.
        public mutating func cycleEnded(error: Error?, allowed: Bool) -> Bool {
            switch state {
            case .running:
                // The retry's own cycle: whatever happened, never again (no loops).
                state = .idle
                return false
            case .scheduled:
                // Another check ended while the retry waits; the retry still goes once.
                return false
            case .idle:
                guard allowed, let error, Self.retriable(error) else { return false }
                state = .scheduled
                return true
            }
        }

        /// The delay is over. True when the retry should start its check now.
        public mutating func retryFiring(allowed: Bool) -> Bool {
            guard state == .scheduled else { return false }
            state = allowed ? .running : .idle
            return allowed
        }

        /// The retry could not start (a session was running, an update is ready).
        public mutating func retryNotStarted() { if state != .idle { state = .idle } }

        static func retriable(_ error: Error) -> Bool { UpdateDownloadRetry.isRetriable(error) }
    }
}

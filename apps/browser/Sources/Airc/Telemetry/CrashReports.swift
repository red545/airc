// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import Foundation
import MetricKit

/// Crash reports (docs/user/telemetry.md, "Crash reports"): at launch, Airc's crashes since the last launch go to
/// PostHog error tracking as `$exception` events, through the same queue, switch and "See what Airc sends" as product
/// analytics. Two sources, both read only while telemetry really sends (never in a scripted run, which must not read
/// the owner's reports or take MetricKit's one-time deliveries):
///
/// - macOS's own crash reports: `.ips` files in ~/Library/Logs/DiagnosticReports whose process lives inside this
///   bundle (the browser or one of its helpers), written since the last look (`Telemetry/crash-reports.json`).
/// - MetricKit (`MXMetricManager`): crashes, hangs, CPU and disk-write exceptions, delivered at a later launch. On macOS
///   it delivers only when "Share with app developers" is on (System Settings → Privacy & Security → Analytics), so
///   the .ips files are what most Macs report; the same crash from both is sent once (CrashReportLog).
///
/// AircKit's CrashReport keeps only frames, binary names, UUIDs, offsets and exception codes from either.
final class AppCrashReports: NSObject, MXMetricManagerSubscriber {
    static let shared = AppCrashReports()

    /// File work happens here, never on the main thread.
    private let work = DispatchQueue(label: "org.airc.telemetry.crash", qos: .utility)
    private var subscribed = false   // main thread
    private var observer: NSObjectProtocol?

    private var directory: URL { AppPaths.dataDirectory.appendingPathComponent("Telemetry", isDirectory: true) }
    private var logURL: URL { directory.appendingPathComponent("crash-reports.json") }

    /// Right after AppTelemetry.start (AppDelegate).
    func start() {
        apply(scan: true)
        observer = NotificationCenter.default.addObserver(forName: AppTelemetry.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.apply(scan: false)
        }
    }

    /// Follows Settings → Privacy. Off (by the person, or locked) forgets the mark, so turning sharing on later starts
    /// from then: a crash from while it was off is never sent.
    private func apply(scan: Bool) {
        let resolution = AppTelemetry.shared.resolution
        let url = logURL
        if resolution.sends {
            if !subscribed {
                subscribed = true
                MXMetricManager.shared.add(self)
            }
            let reports = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/DiagnosticReports")
            let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath().path
            // After the launch has settled: reading a few small files is cheap, but it isn't launch work.
            work.asyncAfter(deadline: .now() + (scan ? 10 : 0)) {
                var log = CrashReportLog.load(url, now: Date())
                if scan {
                    for report in log.scan(reports, bundlePath: bundle, now: Date()) { Telemetry.shared.record(report) }
                }
                log.save(url)
            }
        } else {
            if subscribed {
                subscribed = false
                MXMetricManager.shared.remove(self)
            }
            switch resolution.state {
            case .off, .lockedOff: work.async { try? FileManager.default.removeItem(at: url) }
            case .unavailable, .recordOnly, .sending: break
            }
        }
    }

    // MARK: MetricKit

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let data = payloads.map { $0.jsonRepresentation() }
        receive(data)
    }

    /// MetricKit's payloads (their JSON): each diagnostic is one event, unless the .ips already reported that crash.
    /// Any thread (MetricKit calls on its own).
    func receive(_ payloads: [Data]) {
        DispatchQueue.main.async {
            let resolution = AppTelemetry.shared.resolution
            guard resolution.records else { return }
            let url = self.logURL
            self.work.async {
                var log = CrashReportLog.load(url, now: Date())
                for report in payloads.flatMap(CrashReport.parseMetricKit) where log.admit(report, now: Date()) {
                    Telemetry.shared.record(report)
                }
                if resolution.sends { log.save(url) }
            }
        }
    }

    #if AIRC_TESTING
    /// `--script crashreports`: reads `.ips` files from a synthetic folder instead of the owner's, with a fresh log, and
    /// records what it finds the usual way (a scripted run only records: nothing is sent). Calls `done` on the main queue.
    func collectForCheck(from folder: URL, done: @escaping (Int) -> Void) {
        let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        work.async {
            var log = CrashReportLog(since: .distantPast)
            let reports = log.scan(folder, bundlePath: bundle, now: Date())
            reports.forEach { Telemetry.shared.record($0) }
            DispatchQueue.main.async { done(reports.count) }
        }
    }

    /// Waits for the work queue (the check).
    func drain() { work.sync {} }
    #endif
}

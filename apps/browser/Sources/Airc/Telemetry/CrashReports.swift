// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import Foundation
import MetricKit

/// Crash reports (docs/user/telemetry.md, "Crash reports"): at launch, Airc's crashes since the last launch go to
/// PostHog error tracking as `$exception` events, through the same queue, switch and "See what Airc sends" as product
/// analytics. Three sources, read only while telemetry really sends (a scripted run, which must not read the owner's
/// reports or take MetricKit's one-time deliveries, only shows its own data folder's signal records):
///
/// - Airc's own signal records (CrashLog.swift, `CrashRecords/record.1` … `record.3`): a browser crash, written at
///   the crash by every build. macOS often writes no `.ips` for a process as big as Chromium's browser.
/// - macOS's own crash reports: `.ips` files in ~/Library/Logs/DiagnosticReports whose process lives inside this
///   bundle (the browser or one of its helpers), written since the last look (`Telemetry/crash-reports.json`).
/// - MetricKit (`MXMetricManager`): crashes, hangs, CPU and disk-write exceptions, delivered at a later launch. On macOS
///   it delivers only when "Share with app developers" is on (System Settings → Privacy & Security → Analytics), so
///   the .ips files are what most Macs report.
///
/// The same crash from several sources is sent once (CrashReportLog): the .ips when it's there, since macOS resolved
/// its function names; a fresh signal record waits a minute for it. AircKit's CrashReport keeps only frames, binary
/// names, UUIDs, offsets and exception codes from any of them.
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
            // The mark from the very first launch on, so a crash before the first look below is still reported.
            work.async { if !FileManager.default.fileExists(atPath: url.path) { CrashReportLog(since: Date()).save(url) } }
            // After the launch has settled: reading a few small files is cheap, but it isn't launch work.
            work.asyncAfter(deadline: .now() + (scan ? 10 : 0)) { self.look(scan: scan) }
        } else if resolution.records, scan {
            // A scripted run: this data folder's own signal records, shown in "See what Airc sends" and never queued.
            work.asyncAfter(deadline: .now() + 10) {
                var log = CrashReportLog(since: .distantPast)
                for report in log.scanRecords(CrashLog.recordsDirectory, now: Date(), settle: 0).reports {
                    Telemetry.shared.record(report)
                }
                self.lookedAtLaunch()
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
            if scan { work.async { self.lookedAtLaunch() } }
        }
    }

    /// The .ips files first (the richer report of a crash both describe), then the signal records; looks again when a
    /// fresh signal record waits for its .ips. `work` queue.
    private func look(scan: Bool, again: Bool = false) {
        let url = logURL
        var log = CrashReportLog.load(url, now: Date())
        var retry: Date?
        if scan {
            let reports = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/DiagnosticReports")
            let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath().path
            for report in log.scan(reports, bundlePath: bundle, bundleID: Bundle.main.bundleIdentifier, now: Date()) {
                Telemetry.shared.record(report)
            }
            let records = log.scanRecords(CrashLog.recordsDirectory, now: Date())
            records.reports.forEach { Telemetry.shared.record($0) }
            retry = records.retry
        }
        log.save(url)
        if let retry {
            work.asyncAfter(deadline: .now() + max(1, retry.timeIntervalSinceNow)) {
                // Only while sharing is still on (Settings may have turned it off since).
                DispatchQueue.main.async {
                    guard AppTelemetry.shared.resolution.sends else { return }
                    self.work.async { self.look(scan: true, again: true) }
                }
            }
        }
        if scan, !again { lookedAtLaunch() }
    }

    /// Our signal handlers are still the ones installed after launch (nothing replaced them since main.swift), else
    /// installs them again on top. `work` queue.
    private func lookedAtLaunch() {
        if !CrashLog.handlers.installed { DispatchQueue.main.async { CrashLog.install() } }
        #if AIRC_TESTING
        DispatchQueue.main.async { TestCrashSwitch.armed() }
        #endif
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

    /// `--script crashvis`: looks at this data folder's signal records now, the launch's way (sends or record-only), and
    /// says how many became events. Calls `done` on the main queue.
    func lookAtRecordsForCheck(done: @escaping (Int) -> Void) {
        let resolution = AppTelemetry.shared.resolution
        let url = logURL
        work.async {
            var log = resolution.sends ? CrashReportLog.load(url, now: Date()) : CrashReportLog(since: .distantPast)
            let found = log.scanRecords(CrashLog.recordsDirectory, now: Date(), settle: 0).reports
            found.forEach { Telemetry.shared.record($0) }
            if resolution.sends { log.save(url) }
            DispatchQueue.main.async { done(found.count) }
        }
    }
    #endif
}

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit

/// Finder can replace the installed bundle while this process keeps executing the old image.
/// Capture the launch identity once; read the disk plist directly (Bundle caches its infoDictionary).
final class BundleReplacementMonitor {
    static let shared = BundleReplacementMonitor()
    struct Identity: Equatable {
        let identifier: String
        let version: String
        let build: String
        init?(_ info: [String: Any]) {
            guard let identifier = info["CFBundleIdentifier"] as? String,
                  let version = info["CFBundleShortVersionString"] as? String, !version.isEmpty,
                  let build = info["CFBundleVersion"] as? String, !build.isEmpty else { return nil }
            self.identifier = identifier; self.version = version; self.build = build
        }
    }
    private let bundleURL: URL
    private let launched: Identity?
    private let center: UpdateCenter
    private let terminate: () -> Void
    private var timer: Timer?
    private var candidate: Identity?
    private var offered: BundleReplacementUpdate?
    private var requested: Identity?
    private var observer: NSObjectProtocol?

    init(bundleURL: URL = Bundle.main.bundleURL, launchInfo: [String: Any] = Bundle.main.infoDictionary ?? [:],
         center: UpdateCenter = .shared, terminate: @escaping () -> Void = { NSApp.terminate(nil) }) {
        self.bundleURL = bundleURL; launched = Identity(launchInfo); self.center = center; self.terminate = terminate
    }

    func start() {
        guard timer == nil, !LaunchOptions.current.isAutomated else { return }
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.check() }
        timer = t
        RunLoop.main.add(t, forMode: .common)
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                           object: nil, queue: .main) { [weak self] _ in self?.check() }
    }

    deinit {
        timer?.invalidate()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func diskIdentity() -> Identity? {
        let contents = bundleURL.appendingPathComponent("Contents")
        guard let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let executable = info["CFBundleExecutable"] as? String, !executable.isEmpty, !executable.contains("/"),
              FileManager.default.isExecutableFile(atPath: contents.appendingPathComponent("MacOS/" + executable).path)
        else { return nil }
        return Identity(info)
    }

    func check() {
        guard let launched, let disk = diskIdentity(), disk.identifier == launched.identifier, disk != launched else {
            candidate = nil
            if let offered, center.ready === offered { center.setReady(nil) }
            offered = nil
            return
        }
        // A drag replacement is not atomic across all bundle files. Require two observations before offering it.
        guard candidate == disk else { candidate = disk; return }
        if offered?.identity == disk, center.ready === offered { return }
        let update = BundleReplacementUpdate(identity: disk) { [weak self] in self?.restart(disk) }
        offered = update
        center.setReady(update)
        if center === UpdateCenter.shared {
            (NSApp.delegate as? AppDelegate)?.controller?.showToast(update.restartNotice!)
        }
    }

    private func restart(_ identity: Identity) {
        guard diskIdentity() == identity else { check(); return }
        requested = identity
        terminate() // normal save/beforeunload/download confirmation; cancellation never launches a second app
    }

    var hasPendingRestart: Bool { requested != nil }
    func quitCancelled() { requested = nil }

    /// Called only after termination has been accepted, never when a page cancels quitting.
    func applicationWillTerminate() {
        guard let requested, diskIdentity() == requested else { return }
        self.requested = nil // AppKit and the engine shutdown path may both report termination.
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Arguments are separate argv entries, including paths with spaces or shell metacharacters.
        helper.arguments = ["-c", "pid=$1; app=$2; shift 2; n=0; while kill -0 \"$pid\" 2>/dev/null; do n=$((n+1)); [ \"$n\" -lt 120 ] || exit 1; sleep 1; done; exec /usr/bin/open -n -a \"$app\" --args \"$@\"",
                            "airc-relaunch", String(ProcessInfo.processInfo.processIdentifier), bundleURL.path]
            + Array(CommandLine.arguments.dropFirst())
        do { try helper.run() } catch { center.log("could not start relaunch helper: \(error)") }
    }
}

final class BundleReplacementUpdate: ReadyUpdate {
    let identity: BundleReplacementMonitor.Identity
    private let restart: () -> Void
    var version: String { "\(identity.version) (\(identity.build))" }
    var restartNotice: String? { "Airc was updated. Restart to use \(identity.version)." }
    var pillTitles: [String] { ["Restart to use Airc \(identity.version)", "Airc was updated — Restart", "Restart Airc"] }
    init(identity: BundleReplacementMonitor.Identity, restart: @escaping () -> Void) {
        self.identity = identity; self.restart = restart
    }
    func installAndRelaunch() { restart() }
}

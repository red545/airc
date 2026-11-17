// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if canImport(Sparkle)
import AircKit
import AppKit
import Sparkle

/// Sparkle's update channels (infra/release): dev builds see dev updates only, nightly builds also see nightly updates,
/// everyone else sees stable only.
///
/// Dev builds (`AircDevChannel`, docs/release.md "Private dev channel") check at launch, hourly and when Airc becomes
/// active after the Mac wakes, and download an update by themselves. Once Sparkle has downloaded and verified it, the
/// sidebar shows "New Airc Version Available" above the footer (Browser/UpdateButton.swift), and a toast and an item
/// under "Check for Updates…" say "A new version of Airc is ready. Restart to update", with "See What's New" (the item's
/// release notes) under it. The button and the item restart into it (asking first while music or video plays, during
/// a call or a download; a page that would ask "Leave site?", has typed text or doesn't answer within 5 s is named and
/// selected, with Restart Anyway and Cancel); quitting installs it too, and so does, with Arc's
/// "Automatically update my Arc" turned on (off by default), being away 30 minutes with nothing to interrupt (E13,
/// UpdateCenter). What happened is appended to `Updates.log` in the data folder.
///
/// A download that stalls or loses its connection (updstall: a route that drops the flow mid-body) fails after 20 s
/// without bytes instead of 60, and gets one quiet background retry a few seconds later while automatic checks and
/// downloads are on (UpdateDownloadRetry). Sparkle itself never retries; if the retry fails too, nothing more happens
/// until the next scheduled check.
final class AircUpdateDelegate: NSObject, SPUUpdaterDelegate {
    static let readyMessage = "A new version of Airc is ready. Restart to update"

    private var isDevChannel: Bool { Bundle.main.object(forInfoDictionaryKey: "AircDevChannel") as? Bool == true }
    static var selectedChannel: String {
        get { UserDefaults.standard.string(forKey: "AircPublicUpdateChannel") ?? "stable" }
        set { UserDefaults.standard.set(newValue == "nightly" ? "nightly" : "stable", forKey: "AircPublicUpdateChannel") }
    }
    private var readyItem: NSMenuItem?
    private var whatsNewItem: NSMenuItem?
    private var observers: [NSObjectProtocol] = []
    private var wokeSinceActive = false
    private var retryGate = UpdateDownloadRetry.Gate()

    /// Sparkle's "install now and relaunch", given once the update is downloaded and verified. Sparkle 2.3+ lets it run
    /// again when the quit it starts is cancelled (a page's "Leave site?" → Stay).
    private final class SparkleUpdate: ReadyUpdate {
        let version: String
        let releaseNotesURL: URL?
        let highlights: [WhatsNewHighlight]
        let install: () -> Void
        init(version: String, releaseNotesURL: URL?, highlights: [WhatsNewHighlight], install: @escaping () -> Void) {
            self.version = version
            self.releaseNotesURL = releaseNotesURL
            self.highlights = highlights
            self.install = install
        }
        func installAndRelaunch() { install() }
    }

    override init() {
        super.init()
        UpdateCenter.shared.log = { [weak self] in self?.log($0) }
        // The Mac woke: check once Airc is (or becomes) active, after a moment for the network to come back.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                                           queue: .main) { [weak self] _ in
            self?.wokeSinceActive = true
            if NSApp.isActive { self?.checkAfterWake() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                                                queue: .main) { [weak self] _ in
            if self?.wokeSinceActive == true { self?.checkAfterWake() }
        })
    }

    private func checkAfterWake() {
        wokeSinceActive = false
        guard !LaunchOptions.current.isScripted, UpdateCenter.shared.ready == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, UpdateCenter.shared.ready == nil,
                  let updater = (NSApp.delegate as? AppDelegate)?.updaterController.updater, !updater.sessionInProgress else { return }
            self.log("check after wake")
            updater.checkForUpdatesInBackground()
        }
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        let channel = Bundle.main.object(forInfoDictionaryKey: "AircUpdateChannel") as? String
        if channel == "dev" { return ["dev"] }
        return Self.selectedChannel == "nightly" ? ["stable", "nightly"] : ["stable"]
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        log("found \(item.displayVersionString) (\(item.versionString))")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) { log("up to date") }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) { log("downloaded \(item.versionString)") }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        // updretry: a stalled transfer fails after this many seconds without bytes (URLSession's idle timeout, 60 s by
        // default), so the retry below comes quickly. Sparkle passes this request to SPUDownloader unchanged.
        request.timeoutInterval = UpdateDownloadRetry.idleTimeout
        log("downloading \(item.versionString) (idle timeout \(Int(request.timeoutInterval)) s)")
    }

    /// updretry: one background check after a cycle that ended in a timed-out or lost download, never after the retry's
    /// own cycle, and only while Sparkle checks and downloads by itself, so the retry shows nothing. Sparkle has
    /// already shown its error for a check the person started; a successful retry then offers the update as usual.
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        let automatic = updater.automaticallyChecksForUpdates && updater.automaticallyDownloadsUpdates
        guard retryGate.cycleEnded(error: error, allowed: automatic), let error else { return }
        let cause = UpdateDownloadRetry.rootCause(error)
        log("download stalled (\(cause.domain) \(cause.code)): retrying once in \(Int(UpdateDownloadRetry.delay)) s")
        DispatchQueue.main.asyncAfter(deadline: .now() + UpdateDownloadRetry.delay) { [weak self, weak updater] in
            guard let self, let updater else { return }
            let allowed = updater.automaticallyChecksForUpdates && updater.automaticallyDownloadsUpdates
            guard self.retryGate.retryFiring(allowed: allowed) else { return self.log("retry skipped: automatic updates off") }
            guard UpdateCenter.shared.ready == nil, !updater.sessionInProgress, updater.canCheckForUpdates else {
                self.retryGate.retryNotStarted()
                return self.log("retry skipped: updater busy or an update is ready")
            }
            self.log("retry: checking again")
            updater.checkForUpdatesInBackground()
        }
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        log("download of \(item.versionString) failed: \(error.localizedDescription)")
    }

    /// Sparkle extracts an archive only after its EdDSA signature checks out against `SUPublicEDKey`.
    func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) { log("verified and extracted \(item.versionString)") }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) { log("installing \(item.versionString)") }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) { log("relaunching") }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        // Sparkle also ends a check that found nothing this way (SUNoUpdateError, 1001); that's "up to date" above.
        let e = error as NSError
        guard !(e.domain == SUSparkleErrorDomain && e.code == 1001) else { return }
        log("aborted: \(error.localizedDescription)")
    }

    /// The update is downloaded, verified and waits for the app to quit. Dev builds say so and offer to restart now.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        log("ready \(item.versionString): installs on quit")
        // updatewarm: Sparkle has validated the staged bundle and finished its first install stage; executing it once
        // now spares the next launch what is left of macOS's first-run checks of the new code (UpdateWarmupRunner).
        UpdateWarmupRunner.shared.warm(version: item.versionString) { line in
            DispatchQueue.main.async { [weak self] in self?.log(line) }
        }
        let version = "\(item.displayVersionString) (\(item.versionString))"
        if UpdateCenter.shared.ready?.version != version {
            // A web page of notes only: the feed's inline or Markdown notes have no address to open.
            let notes = [item.fullReleaseNotesURL, item.releaseNotesURL].compactMap { $0 }.first { $0.scheme == "https" }
            // What it brings: the item's <airc:highlights> (scripts/release/whatsnew.py); older feeds have none.
            let highlights = WhatsNewAppcast.highlights(properties: item.propertiesDictionary)
            log("highlights: \(highlights.count)")
            UpdateCenter.shared.setReady(SparkleUpdate(version: version, releaseNotesURL: notes, highlights: highlights,
                                                       install: immediateInstallHandler))
        }
        showReady()
        return true
    }

    /// The app menu's item: the sidebar button's restart, with its question.
    @objc func restartToUpdate(_ sender: Any?) {
        UpdateCenter.shared.restart(from: (NSApp.delegate as? AppDelegate)?.controller)
    }

    @objc func showWhatsNew(_ sender: Any?) { UpdateCenter.shared.showWhatsNew(from: nil) }

    private func showReady() {
        let app = NSApp.delegate as? AppDelegate
        app?.controller?.showToast(Self.readyMessage)
        guard readyItem == nil, let menu = NSApp.mainMenu?.items.first?.submenu else { return }
        let item = NSMenuItem(title: Self.readyMessage, action: #selector(restartToUpdate(_:)), keyEquivalent: "")
        item.target = self
        let after = menu.items.firstIndex { $0.action == NSSelectorFromString("checkForUpdates:") } ?? 0
        menu.insertItem(item, at: after + 1)
        readyItem = item
        let notes = NSMenuItem(title: UpdateConfirmModel.whatsNewTitle, action: #selector(showWhatsNew(_:)), keyEquivalent: "")
        notes.target = self
        notes.indentationLevel = 1
        menu.insertItem(notes, at: after + 2)
        whatsNewItem = notes
        log("offered: \(Self.readyMessage)")
        #if AIRC_TESTING
        // An update proof (infra/updates, docs/release.md) chooses the item the way a person would.
        if ProcessInfo.processInfo.environment["AIRC_UPDATE_RESTART_WHEN_READY"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard let index = item.menu?.index(of: item), index >= 0 else { return }
                item.menu?.performActionForItem(at: index)
            }
        }
        #endif
    }

    /// One line per update event in `<data folder>/Updates.log` (dev builds).
    func log(_ event: String) {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = "\(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))"
        let line = "\(ISO8601DateFormatter().string(from: Date())) pid \(getpid()) \(version): \(event)\n"
        let url = AppPaths.dataDirectory.appendingPathComponent("Updates.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
#endif

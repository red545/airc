// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit
import IOKit
import SwiftUI

// The sidebar's update button, as in Arc (Arc ref §2.9 "Update banner"): once Sparkle has downloaded and verified an
// update, a pill above the footer reads "New Airc Version Available"; a click restarts into it. Music or video
// playing, a call, a running download or a page that would ask "Leave site?" (in any window) gets a calm question first;
// every page has 5 s to answer, and a page with unsaved changes or one that doesn't answer is named and selected, and
// the restart waits for Restart Anyway (restartwait).
// Left alone, the update installs when Airc quits; with Arc's "Automatically update my Arc" turned on (off by default,
// Settings › General › Automatic Updates) it restarts by itself after 30 minutes without input on the Mac, when
// nothing would be interrupted (IdleUpdatePolicy). The pill's menu and the question offer the update's release notes
// ("See What's New"); after the restart a toast says it's updated, with See What's New for that version's notes (saved
// with the version before the restart). Sparkle's delegate (App/AircUpdateDelegate.swift) drives it; checks inject a
// fake.

// MARK: - The state

/// A downloaded, verified update waiting to install: Sparkle's immediate-installation block in dev builds, a fake in
/// scripted checks (which never start the real updater).
protocol ReadyUpdate: AnyObject {
    /// "1.0 (202611061200)", for the tooltip and Updates.log.
    var version: String { get }
    /// The update's own release notes (its appcast item's), if it has them.
    var releaseNotesURL: URL? { get }
    var restartNotice: String? { get }
    var pillTitles: [String] { get }
    /// What the update brings, its first lines (the appcast item's `<airc:highlights>`): shown under the pill. Older
    /// feeds have none, and the pill is the plain pill then.
    var highlights: [WhatsNewHighlight] { get }
    /// Installs it and relaunches Airc. Sparkle quits the app the usual way (state is saved, pages may still ask
    /// "Leave site?"); if the quit is cancelled the update stays ready and this can run again.
    func installAndRelaunch()
}

extension ReadyUpdate {
    var releaseNotesURL: URL? { nil }
    var restartNotice: String? { nil }
    var pillTitles: [String] { UpdateButtonView.titles }
    var highlights: [WhatsNewHighlight] { [] }
}

/// The one ready update, if any. Event-driven: Sparkle's callbacks set it, the sidebars listen for `changed`.
final class UpdateCenter {
    static let shared = UpdateCenter()
    static let changed = Notification.Name("AircUpdateCenterChanged")

    private(set) var ready: ReadyUpdate?
    /// One line in Updates.log (the Sparkle delegate sets it; nothing without Sparkle).
    var log: (String) -> Void = { _ in }
    /// Checks replace how the risks of restarting now are found.
    var riskProbe: ((WindowController, @escaping (UpdateRestartRisks) -> Void) -> Void)?
    /// The question on screen (checks answer it).
    private(set) var confirm: UpdateConfirmView?
    private var shownVersions: Set<String> = []
    private var asking = false

    /// A new update is ready (or none is any more).
    func setReady(_ update: ReadyUpdate?) {
        ready = update
        if let update, shownVersions.insert(update.version).inserted {
            Telemetry.shared.record(.featureUsed(.updateReadyShown))
        }
        if update == nil { dismissConfirm() }
        // What "Updated!" offers after the restart into it, whichever way it installs (a restart here, or Sparkle at
        // quit): this version's own notes, kept with it.
        if let update { Self.saveNotes(UpdateNotes(version: update.version, notes: update.releaseNotesURL?.absoluteString)) }
        scheduleIdleCheck()
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    /// What's new in the ready update: its own notes, else Airc's release notes.
    var whatsNewURL: URL { ready?.releaseNotesURL ?? ParityCommandCatalog.releaseNotes }

    /// "See What's New" (the pill's menu, the question, the app menu): the notes in a new tab.
    func showWhatsNew(from controller: WindowController?) {
        guard let c = controller ?? (NSApp.delegate as? AppDelegate)?.controller else { return }
        log("see what's new: \(whatsNewURL.absoluteString)")
        c.openHelpPage(whatsNewURL)
    }

    /// The button, or the app menu's "Restart to update": restart now, asking first if something would be lost.
    /// Every page gets `UpdateRestartRisks.answerTime` (5 s, as restarting by itself) to answer; a page with unsaved
    /// changes or one that doesn't answer is never quit behind its back: the question names its tab and selects it
    /// (restartwait, E13). While the pages answer, the pill says "Checking Tabs…" (after a moment).
    func restart(from controller: WindowController?) {
        guard let update = ready, !asking, confirm == nil else { return }
        Telemetry.shared.record(.featureUsed(.updateRestartClicked))
        guard let c = controller else { return install(update, downloads: false) }
        asking = true
        let started = Date()
        let token = UUID()
        checkToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.checkingTitleDelay) { [weak self] in
            guard let self, self.checkToken == token else { return }
            self.setChecking(true)
        }
        let probe = riskProbe ?? { _, done in Self.risksInEveryWindow(done) }
        probe(c) { [weak self, weak c] risks in
            guard let self else { return }
            self.asking = false
            self.checkToken = nil
            self.setChecking(false)
            guard let c, self.ready === update else { return }
            let waited = Int(Date().timeIntervalSince(started) * 1000)
            if risks.isEmpty {
                self.log("restart: every page answered in \(waited) ms, nothing at risk")
                self.install(update, downloads: false)
            } else {
                self.log("restart asks first (after \(waited) ms): \(risks.logText)")
                self.ask(risks, in: c, update: update)
            }
        }
    }

    /// "Checking Tabs…" on the pill once the pages take longer than this to answer.
    static let checkingTitleDelay: TimeInterval = 0.4
    static let checkingTitle = "Checking Tabs…"
    private var checkToken: UUID?
    /// The click's pages are still answering (the pill says so).
    private(set) var checking = false
    private func setChecking(_ on: Bool) {
        guard checking != on else { return }
        checking = on
        for w in (NSApp.delegate as? AppDelegate)?.controllers ?? [] { w.sidebar.update.needsLayout = true }
    }

    private func ask(_ risks: UpdateRestartRisks, in clicked: WindowController, update: ReadyUpdate) {
        // The first tab that would be quit behind: selected in its own window, where the question shows.
        var c = clicked
        if let first = risks.blockingTabs.first,
           let w = (NSApp.delegate as? AppDelegate)?.controllers.first(where: { $0.pages[first.tabID] != nil }) {
            c = w
            w.selectForUpdate(first.tabID)
            if w !== clicked { w.window.makeKeyAndOrderFront(nil) }
        }
        let model = UpdateConfirmModel(risks: risks, theme: c.currentPalette.resolved)
        let v = UpdateConfirmView(model: model, controller: c)
        model.onAnswer = { [weak self] restart in
            guard let self else { return }
            self.dismissConfirm()
            guard restart, self.ready === update else { return self.log(risks.blockingTabs.isEmpty ? "restart: not now" : "restart: cancelled") }
            guard !risks.blockingTabs.isEmpty else { return self.install(update, downloads: risks.downloads > 0) }
            self.log("restart anyway: leaving \(risks.blockingTabs.count) tab(s)")
            Self.leave(risks.blockingTabs) { if self.ready === update { self.install(update, downloads: risks.downloads > 0) } }
        }
        model.onWhatsNew = { [weak self, weak c] in self?.showWhatsNew(from: c) }
        model.onSelectTab = { id in
            (NSApp.delegate as? AppDelegate)?.controllers.first { $0.pages[id] != nil }?.selectForUpdate(id)
        }
        c.root.addSubview(v, positioned: .below, relativeTo: c.toast)
        confirm = v
        v.layoutInWindow()
        v.present()
    }

    /// Restart Anyway: the person chose to leave these pages, so the quit doesn't ask them "Leave site?" again. Their
    /// handlers can't hold the page any more (`leaveScript`); a page that still doesn't answer gets it queued, and the
    /// quit goes on after a second at most.
    static func leave(_ tabs: [UpdateRestartRisks.BlockingTab], then: @escaping () -> Void) {
        let controllers = (NSApp.delegate as? AppDelegate)?.controllers ?? []
        let pages = tabs.compactMap { t in controllers.lazy.compactMap { $0.pages[t.tabID] }.first { !$0.isClosed }.map { (t, $0) } }
        var waiting = pages.filter { $0.0.reason != .unanswered }.count, finished = false
        let finish = {
            guard !finished else { return }
            finished = true
            then()
        }
        for (t, page) in pages {
            page.evaluate(Self.leaveScript) { _ in
                guard t.reason != .unanswered else { return }
                waiting -= 1
                if waiting == 0 { finish() }
            }
        }
        if waiting == 0 { return finish() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { finish() }
    }

    /// Whatever order the page's own listeners run in (on some engines a listener added earlier runs before a capture
    /// one added later): a beforeunload event can't be cancelled or given a message any more, and `onbeforeunload` is
    /// cleared. Run where the script runs and, through a script element, in the page's own world as well (an engine
    /// may evaluate in an isolated one).
    static let leaveScript = """
    (function(){var f=function(){try{window.onbeforeunload=null;var P=BeforeUnloadEvent.prototype;
      Object.defineProperty(P,'returnValue',{configurable:true,get:function(){return ''},set:function(){}});
      Object.defineProperty(P,'preventDefault',{configurable:true,writable:true,value:function(){}});
      window.addEventListener('beforeunload',function(e){e.stopImmediatePropagation()},true);}catch(x){}};
      f();try{var s=document.createElement('script');s.textContent='('+f+')()';(document.head||document.documentElement).appendChild(s);s.remove()}catch(x){}
      return true})()
    """

    func dismissConfirm() {
        guard let v = confirm else { return }
        confirm = nil
        guard let layer = v.layer else { return v.removeFromSuperview() }
        layer.fade(from: 1, to: 0, duration: AircCurve.toastOut.duration)
        DispatchQueue.main.asyncAfter(deadline: .now() + AircCurve.toastOut.duration) { v.removeFromSuperview() }
    }

    /// Saves what quitting saves, then hands over to Sparkle.
    private func install(_ update: ReadyUpdate, downloads: Bool) {
        log("restart to update \(update.version)")
        if let store = (NSApp.delegate as? AppDelegate)?.store { try? store.flush() }
        // Already answered here: quitting doesn't ask about the downloads a second time.
        if downloads, let engine = MediaLibrary.shared.downloads?.engine {
            let previous = engine.downloadsCloseConfirmation
            engine.downloadsCloseConfirmation = { _, answer in answer(true) }
            // A quit cancelled by "Leave site?" asks again next time.
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { engine.downloadsCloseConfirmation = previous }
        }
        // E12: the restart brings the windows back, whatever "When Airc starts" says (Browser/MultiWindow.swift).
        (NSApp.delegate as? AppDelegate)?.restoreWindowsAfterRestart()
        update.installAndRelaunch()
    }

    /// Every browser window's risks together (WIN-7: a call in another window counts too); downloads are the app's.
    static func risksInEveryWindow(answerTime: TimeInterval = UpdateRestartRisks.answerTime, _ done: @escaping (UpdateRestartRisks) -> Void) {
        let controllers = (NSApp.delegate as? AppDelegate)?.controllers ?? []
        var total = UpdateRestartRisks()
        total.downloads = MediaLibrary.shared.downloads?.runningCount ?? 0
        var waiting = controllers.count
        guard waiting > 0 else { return done(total) }
        for c in controllers {
            c.updateRestartRisks(answerTime: answerTime) { r in
                total.merge(r)
                waiting -= 1
                if waiting == 0 { done(total) }
            }
        }
    }

    // MARK: Restarting by itself (E13)

    /// How often a ready update looks whether it may restart by itself (only while one is ready and the setting is on).
    static let idleCheckInterval: TimeInterval = 60
    /// How long each page has to answer before restarting by itself: the same as Restart to Update's.
    static let idleAnswerTime: TimeInterval = UpdateRestartRisks.answerTime
    #if AIRC_TESTING
    /// The check's fake idle clock (HID idle seconds, Airc in front): with it set, `checkIdleRestart` runs in the
    /// scripted run; without it an automated run never restarts by itself. The timer never runs in one either way.
    var idleTestClock: (() -> (idle: TimeInterval, active: Bool))?
    #endif
    /// The update that has tried to restart by itself: once only (if a quit was cancelled, it waits for the person).
    private var idleTried: String?
    private var idleTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var lastIdleBlockers: [IdleUpdatePolicy.Blocker] = []

    /// A scripted or automated run, the engine's test harness, a test environment: never restarts by itself.
    static var isAutomatedRun: Bool {
        let o = LaunchOptions.current, env = ProcessInfo.processInfo.environment
        return o.isAutomated || o.isScripted || o.engineSwitches.contains { $0.hasPrefix("--airc-test") }
            || (env["AIRC_TESTING"].map { !$0.isEmpty && $0 != "0" } ?? false)
    }

    private var idleRestartOn: Bool { (NSApp.delegate as? AppDelegate)?.settings?.values.restartToUpdateWhenIdle ?? false }

    /// Starts or stops looking: only with an update ready, the setting on, and never in an automated run. Settings calls
    /// it when the switch changes.
    func scheduleIdleCheck() {
        let wanted = ready != nil && idleRestartOn && !Self.isAutomatedRun
        guard wanted != (idleTimer != nil) else { return }
        idleTimer?.invalidate()
        idleTimer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        guard wanted else { return }
        let t = Timer(timeInterval: Self.idleCheckInterval, repeats: true) { [weak self] _ in self?.checkIdleRestart() }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        idleTimer = t
        // Arc updates itself when the Mac wakes from sleep: a minute after waking, if nobody has touched it since.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                                         queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { self?.checkIdleRestart() }
        }
    }

    /// Restarts into the ready update if the person has been away long enough and nothing would be interrupted. The
    /// cheap reasons first; the pages are asked only when none of those holds. `done` gets what kept it waiting.
    func checkIdleRestart(_ done: (([IdleUpdatePolicy.Blocker]) -> Void)? = nil) {
        guard let update = ready, idleTried != update.version, !asking, confirm == nil else { done?([.notReady]); return }
        var p = IdleUpdatePolicy()
        p.enabled = idleRestartOn
        p.updateReady = true
        p.automated = Self.isAutomatedRun
        var (idle, active) = (Self.hidIdleSeconds(), NSApp.isActive)
        #if AIRC_TESTING
        if let clock = idleTestClock {
            (idle, active) = clock()
            p.automated = false
        }
        #endif
        p.idleSeconds = idle
        p.appActive = active
        p.privateWindowsWithPages = PrivateBrowsing.shared.windows.contains { !$0.pages.isEmpty }
        p.dialogOpen = Self.dialogOnScreen
        guard p.cheapBlockers.isEmpty else { return idleResult(p.blockers, done) }
        asking = true
        // Nobody waits for this one: the pages get longer to answer, and one that doesn't still holds it back.
        let answerWait = Self.idleAnswerTime
        let probe = riskProbe ?? { _, done in Self.risksInEveryWindow(answerTime: answerWait, done) }
        let gather: (@escaping (UpdateRestartRisks) -> Void) -> Void = { finish in
            guard let c = (NSApp.delegate as? AppDelegate)?.controller else { return Self.risksInEveryWindow(answerTime: answerWait, finish) }
            probe(c, finish)
        }
        gather { [weak self] risks in
            guard let self else { return }
            self.asking = false
            guard self.ready === update, self.confirm == nil else { return self.idleResult([.notReady], done) }
            p.playing = risks.playing
            p.pausedMedia = risks.pausedMedia
            p.pictureInPicture = risks.pictureInPicture
            p.call = risks.call
            p.screenSharing = risks.screenSharing
            p.downloads = risks.downloads
            p.loading = risks.loading
            p.leaveSite = risks.leaveSite
            p.editedForms = risks.editedForms
            p.developerMode = risks.developerMode
            p.unanswered = risks.unanswered
            guard p.restartsNow else { return self.idleResult(p.blockers, done) }
            self.idleTried = update.version
            self.log("restarts by itself: no input for \(Int(idle / 60)) min, nothing would be interrupted")
            self.install(update, downloads: false)
            done?([])
        }
    }

    private func idleResult(_ blockers: [IdleUpdatePolicy.Blocker], _ done: (([IdleUpdatePolicy.Blocker]) -> Void)?) {
        // Updates.log says why it waits when that changes, not every minute.
        if blockers != lastIdleBlockers { log("waits to restart: \(blockers.map(\.rawValue).joined(separator: ", "))") }
        lastIdleBlockers = blockers
        done?(blockers)
    }

    /// Seconds since the last keyboard, mouse or trackpad input on this Mac: the HID system's own idle time
    /// (IOHIDSystem's HIDIdleTime). Without it, 0: never idle.
    static func hidIdleSeconds() -> TimeInterval {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return 0 }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber else { return 0 }
        return value.doubleValue / 1_000_000_000
    }

    /// A sheet, a modal window or alert, or a dialog the engine draws in its own window over a page (a page's alert,
    /// "Leave site?", a sign-in dialog). Chromium hangs those off the window it registers as their parent, itself a
    /// child of the browser window that's always there: a dialog is an engine window two or more levels down.
    static var dialogOnScreen: Bool {
        NSApp.modalWindow != nil || NSApp.windows.contains { w in
            guard w.isVisible else { return false }
            if w.attachedSheet != nil || w.isSheet { return true }
            var depth = 0, p = w.parent
            while let q = p { depth += 1; p = q.parent }
            return depth >= 2 && NSStringFromClass(type(of: w)).contains("NativeWidgetMac")
        }
    }

    // MARK: After the restart

    /// The version this data folder ran last, in its own file (UserDefaults are the bundle ID's, shared with other copies).
    static var lastVersionFile: URL { AppPaths.dataDirectory.appendingPathComponent("LastVersion") }
    #if AIRC_TESTING
    /// The paritywhatsnew check runs a test build (always 0.1.0) as a released version.
    static var runningVersionOverride: String?
    #endif
    static var runningVersion: String {
        #if AIRC_TESTING
        if let v = runningVersionOverride { return v }
        #endif
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))"
    }
    static func updatedMessage(_ version: String) -> String { "Updated! Airc \(version)" }

    /// The ready update's version and notes link, saved before the restart ("UpdateNotes.json" in the data folder):
    /// after it, "Updated!" opens exactly that version's notes.
    struct UpdateNotes: Codable, Equatable {
        var version: String
        var notes: String?
    }
    static var notesFile: URL { AppPaths.dataDirectory.appendingPathComponent("UpdateNotes.json") }
    static func saveNotes(_ n: UpdateNotes) {
        guard let data = try? JSONEncoder().encode(n) else { return }
        try? data.write(to: notesFile, options: .atomic)
    }
    static var savedNotes: UpdateNotes? { (try? Data(contentsOf: notesFile)).flatMap { try? JSONDecoder().decode(UpdateNotes.self, from: $0) } }

    /// The notes for `version`: the link its update came with (https only), else Airc's release notes.
    static func notesURL(for version: String) -> URL {
        guard let saved = savedNotes, saved.version == version, let link = saved.notes.flatMap(URL.init(string:)),
              link.scheme == "https" || (LaunchOptions.current.isScripted && link.scheme == "http") else {
            return ParityCommandCatalog.releaseNotes
        }
        return link
    }

    /// At launch (MainMenu.build): another version than the last run's means the update went in; the first window says
    /// so, with See What's New for that version's notes. Scripted runs skip it (their snapshots stay as they are)
    /// unless a check asks.
    func noteLaunchedVersion(inScriptedRun: Bool = false) {
        guard inScriptedRun || !LaunchOptions.current.isScripted else { return }
        let now = Self.runningVersion
        let before = (try? String(contentsOf: Self.lastVersionFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        if before != now { try? Data(now.utf8).write(to: Self.lastVersionFile, options: .atomic) }
        // The "What's new" card (Browser/WhatsNewCard.swift): never on a fresh install (no LastVersion), up to three
        // launches after an update. When it shows, it says what "Updated!" would, so the toast stays away.
        let card = WhatsNewCenter.shared.noteLaunch(previous: before.flatMap { $0.isEmpty ? nil : $0 }, current: now)
        guard let before, !before.isEmpty, before != now else { return }
        let notes = Self.notesURL(for: now)
        log("updated from \(before); what's new: \(notes.absoluteString)\(card ? " (the What's New card)" : "")")
        if !card { announceUpdated(now, notes: notes, tries: 20) }
    }

    /// Waits for the first window to be on screen with its page card laid out (right after launch it can still be
    /// zero-sized, which put the toast in the window's top-left corner in 0.1.4), then shows "Updated!" on it.
    private func announceUpdated(_ version: String, notes: URL, tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let c = (NSApp.delegate as? AppDelegate)?.controller, c.window.isVisible, c.hasLaidOutCard else {
                if tries > 0 { self?.announceUpdated(version, notes: notes, tries: tries - 1) }
                return
            }
            c.showUpdatedToast(Self.updatedMessage(version), notes: notes)
        }
    }
}

// MARK: - "Updated!"

/// The toast after an update's restart, as Arc's "Updated!" notice: the version, and See What's New, which opens that
/// version's notes in a new tab. Nothing opens by itself. Centred at the top of the page card, and it stays there while
/// the window resizes or the sidebar slides (WindowController.layoutRoot calls `follow`). It's up for
/// `UpdatedToastView.duration`, longer while the pointer rests on it, and goes on See What's New or Esc.
final class UpdatedToastView: NSView {
    /// Arc's "Updated!" banner has a button to reach, so it stays far longer than a plain toast (2.4 s). Arc's own
    /// time isn't recorded anywhere we can read (its strings carry only the copy), so 8 s.
    static let duration: Double = 8
    /// After the pointer leaves it, it stays this much longer.
    static let afterHover: Double = 1.5

    let label = NSTextField(labelWithString: "")
    let button = NSButton(title: UpdateConfirmModel.whatsNewTitle, target: nil, action: nil)
    /// The notes See What's New opens.
    private(set) var notes: URL?
    var onWhatsNew: ((URL) -> Void)?
    private var hideWork: DispatchWorkItem?
    /// Bumped on every show and hide, so a hide's late `isHidden = true` never hides a newer show.
    private var generation = 0
    /// The pointer rests on it (tracking area; the checks set it through mouseEntered/mouseExited).
    private(set) var isHovered = false
    /// What it says while it shows, else nil (the checks read it).
    var shownText: String? { isHidden || hiding ? nil : label.stringValue }
    private var hiding = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = AircRadius.toast
        layer?.cornerCurve = .continuous
        layer?.apply(.toast)
        label.font = AircFont.body.weight(.medium).appFont
        button.isBordered = false
        button.font = AircFont.body.weight(.semibold).appFont
        button.target = self
        button.action = #selector(whatsNew)
        button.setAccessibilityLabel("See what's new in this version")
        addSubview(label)
        addSubview(button)
        // Keeps its place against the top-centre between layout passes; layoutRoot then places it exactly.
        autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        hideWork?.cancel()
    }
    override func mouseExited(with event: NSEvent) {
        isHovered = false
        if !isHidden, !hiding { scheduleHide(after: Self.afterHover) }
    }

    private func scheduleHide(after seconds: Double) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Still under the pointer (it was there before the toast came, so no mouseEntered): wait for it to leave.
            if self.isHovered || self.pointerIsInside { return self.scheduleHide(after: Self.afterHover) }
            self.hide()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private var pointerIsInside: Bool {
        guard let window, window.isVisible, !isHidden else { return false }
        return bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    @objc func whatsNew() {
        guard let notes else { return }
        hide()
        onWhatsNew?(notes)
    }

    /// Its frame for a page card at `card` (its superview's flipped coordinates): centred, `Toast.topInset` below the
    /// card's top, on whole points.
    func placement(in card: NSRect) -> NSRect {
        let size = frame.size
        return NSRect(x: (card.midX - size.width / 2).rounded(), y: (card.minY + AircMetrics.Toast.topInset).rounded(),
                      width: size.width, height: size.height)
    }

    /// The page card moved or resized (window resize, sidebar slide, Library): keep the toast centred on it.
    func follow(_ card: NSRect) {
        guard !isHidden, !card.isEmpty else { return }
        let f = placement(in: card)
        if frame != f { frame = f }
    }

    func show(_ text: String, notes: URL, palette: Palette, in card: NSRect, duration: Double = UpdatedToastView.duration) {
        generation += 1
        hiding = false
        self.notes = notes
        label.stringValue = text
        label.textColor = palette.panelText
        button.contentTintColor = palette.resolved.accentText.nsColor
        layer?.backgroundColor = palette.panelBackground.cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = palette.panelBorder.cgColor
        label.sizeToFit()
        button.sizeToFit()
        let h = AircMetrics.Toast.height, gap = AircSpacing.m
        let w = (AircSpacing.l + label.frame.width + gap + button.frame.width + AircSpacing.l).rounded(.up)
        frame.size = NSSize(width: w, height: h)
        frame = placement(in: card)
        label.frame.origin = NSPoint(x: AircSpacing.l, y: ((h - label.frame.height) / 2).rounded())
        button.frame.origin = NSPoint(x: label.frame.maxX + gap, y: ((h - button.frame.height) / 2).rounded())
        isHidden = false
        if let layer {
            // In: from 0.7 scale on Arc's pop spring, fading in. The scale runs about the toast's centre as a transform
            // (whatever anchor AppKit gave the layer). The anchor and position stay AppKit's: moving them shifted the
            // drawn toast away from its frame.
            let pivot = CGPoint(x: w * (0.5 - layer.anchorPoint.x), y: h * (0.5 - layer.anchorPoint.y))
            var from = CATransform3DMakeTranslation(pivot.x, pivot.y, 0)
            from = CATransform3DScale(from, 0.7, 0.7, 1)
            from = CATransform3DTranslate(from, -pivot.x, -pivot.y, 0)
            layer.removeAnimation(forKey: "in")
            layer.add(AircSpring.pop.caAnimation(keyPath: "transform", from: NSValue(caTransform3D: from),
                                                 to: NSValue(caTransform3D: CATransform3DIdentity)), forKey: "in")
            layer.fade(from: 0, to: 1, duration: AircCurve.previewIn.duration)
        }
        scheduleHide(after: duration)
    }

    func hide() {
        hideWork?.cancel()
        guard !isHidden, !hiding else { return }
        hiding = true
        generation += 1
        let g = generation
        layer?.fade(from: 1, to: 0, duration: AircCurve.toastOut.duration)
        DispatchQueue.main.asyncAfter(deadline: .now() + AircCurve.toastOut.duration) { [weak self] in
            guard let self, self.generation == g else { return }
            self.hiding = false
            self.isHidden = true
        }
    }
}

extension WindowController {
    /// The "Updated!" toast over this window's page, if it has been made.
    var updatedToast: UpdatedToastView? { root.subviews.first { $0 is UpdatedToastView } as? UpdatedToastView }

    /// The page card has its real frame (laid out at least once, wide enough for a toast).
    var hasLaidOutCard: Bool {
        root.layoutSubtreeIfNeeded()
        return card.frame.width >= 200 && card.frame.height >= 100
    }

    func showUpdatedToast(_ text: String, notes: URL) {
        let v = updatedToast ?? {
            let v = UpdatedToastView()
            root.addSubview(v, positioned: .below, relativeTo: toast)
            return v
        }()
        v.onWhatsNew = { [weak self] url in self?.openHelpPage(url) }
        // Never from a card that hasn't been laid out yet (its frame is zero then).
        if !hasLaidOutCard { layoutRoot() }
        v.show(text, notes: notes, palette: currentPalette, in: card.frame)
    }

    /// Esc: "Updated!" goes (the key still goes on to the page and the window).
    func dismissUpdatedToast() {
        guard let t = updatedToast, t.shownText != nil else { return }
        t.hide()
    }
}

// MARK: - What restarting now would interrupt

struct UpdateRestartRisks: Equatable {
    /// A page uses the camera or microphone (a call).
    var call = false
    /// A page shares the screen, a window or a tab.
    var screenSharing = false
    /// A page plays music or video (muted too: it would stop). Decorative videos (muted, looping, no controls) don't count.
    var playing = false
    /// Music or video paused part-way: a restart would start it over.
    var pausedMedia = false
    /// A video in picture in picture, or a page's own picture-in-picture window.
    var pictureInPicture = false
    var downloads = 0
    /// Pages still loading: a form or file being sent (pages sending in the background usually ask "Leave site?").
    var loading = 0
    /// Pages that would ask "Leave site?".
    var leaveSite = 0
    /// Pages with form fields the person changed (typed text a restart would lose).
    var editedForms = 0
    /// Pages in Developer Mode (a local server's page, its console and state).
    var developerMode = 0
    /// Pages that didn't answer in time: what they hold is unknown (restarting by itself waits for them).
    var unanswered = 0
    /// The tabs a restart would quit behind (restartwait): pages that would ask "Leave site?", have typed text, or didn't
    /// answer in time. Restart to Update names them, selects the first and installs only on Restart Anyway.
    var blockingTabs: [BlockingTab] = []
    /// How long each page has to answer, whether the person clicked Restart to Update or it restarts by itself: a busy
    /// page that answers within it doesn't hold the restart back; one that doesn't is never taken as "nothing to lose".
    static let answerTime: TimeInterval = 5

    struct BlockingTab: Equatable {
        enum Reason: String, Equatable { case leaveSite, editedForm, unanswered }
        var tabID: String
        var title: String
        var reason: Reason
    }

    /// Another window's pages (downloads are the app's, counted once).
    mutating func merge(_ r: UpdateRestartRisks) {
        call = call || r.call
        screenSharing = screenSharing || r.screenSharing
        playing = playing || r.playing
        pausedMedia = pausedMedia || r.pausedMedia
        pictureInPicture = pictureInPicture || r.pictureInPicture
        loading += r.loading
        leaveSite += r.leaveSite
        editedForms += r.editedForms
        developerMode += r.developerMode
        unanswered += r.unanswered
        blockingTabs += r.blockingTabs
    }

    /// Nothing the question names: Restart to Update installs at once.
    var isEmpty: Bool { lines.isEmpty }

    /// Nothing at all a restart would interrupt (restarting by itself needs this; the question only names what's lost).
    var nothingInterrupted: Bool {
        isEmpty && !pausedMedia && !pictureInPicture && loading == 0 && developerMode == 0 && unanswered == 0
    }

    /// The question's lines, most serious first.
    var lines: [String] {
        var out: [String] = []
        if call { out.append("Your call ends.") }
        if screenSharing && !call { out.append("Screen sharing stops.") }
        if playing && !call { out.append("Music or video is playing. Restarting stops it.") }
        if downloads == 1 { out.append("A download is still running. Restarting cancels it.") }
        if downloads > 1 { out.append("\(downloads) downloads are still running. Restarting cancels them.") }
        if leaveSite == 1 { out.append("A page may have changes that aren’t saved.") }
        if leaveSite > 1 { out.append("\(leaveSite) pages may have changes that aren’t saved.") }
        if editedForms > 0 && leaveSite == 0 { out.append(editedForms == 1 ? "A page has text you typed that isn’t sent." : "\(editedForms) pages have text you typed that isn’t sent.") }
        if unanswered == 1 { out.append("A page isn’t responding. What it holds may be lost.") }
        if unanswered > 1 { out.append("\(unanswered) pages aren’t responding. What they hold may be lost.") }
        return out
    }

    var logText: String {
        "call \(call), screen \(screenSharing), playing \(playing), paused \(pausedMedia), pip \(pictureInPicture), downloads \(downloads), "
            + "loading \(loading), leave site \(leaveSite), edited \(editedForms), developer mode \(developerMode), unanswered \(unanswered)"
            + (blockingTabs.isEmpty ? "" : ", tabs [\(blockingTabs.map { "\($0.reason.rawValue) \($0.tabID)" }.joined(separator: ", "))]")
    }

    /// A page in a call or capturing (muted or silent too).
    static func isCall(activity: SiteActivity, media: EngineMediaSession) -> Bool {
        usesCameraOrMicrophone(activity: activity, media: media) || sharesScreen(activity: activity, media: media)
    }

    static func usesCameraOrMicrophone(activity: SiteActivity, media: EngineMediaSession) -> Bool {
        activity.camera || activity.microphone || media.capture.camera || media.capture.microphone
    }

    static func sharesScreen(activity: SiteActivity, media: EngineMediaSession) -> Bool {
        activity.screen || media.capture.screen || media.capture.tab
    }

    /// What a page says about itself, as bits: 1 would ask "Leave site?", 2 has changed form fields, 4 plays media,
    /// 8 has media paused part-way, 16 is in picture in picture. Same-origin frames' media the engine's media session
    /// sees anyway.
    static let pageScript = "(function(){var r=0;try{if(" + WindowController.wouldAskBeforeUnload.trimmingCharacters(in: .whitespacesAndNewlines) + ")r|=1;}catch(x){r|=1}"
        + "try{var f=document.querySelectorAll('input,textarea,select');for(var i=0;i<f.length;i++){var e=f[i],t=(e.type||'').toLowerCase();"
        + "if(e.disabled)continue;var c=false;if(t==='file')c=!!(e.files&&e.files.length);"
        + "else if(t==='hidden'||t==='submit'||t==='button'||t==='reset'||t==='image')c=false;"
        + "else if(t==='checkbox'||t==='radio')c=e.checked!==e.defaultChecked;"
        + "else if(e.tagName==='SELECT'){for(var j=0;j<e.options.length;j++)if(e.options[j].selected!==e.options[j].defaultSelected)c=true}"
        + "else c=e.value!==e.defaultValue;if(c){r|=2;break}}}catch(x){}"
        + "try{var m=document.querySelectorAll('video,audio');for(var k=0;k<m.length;k++){var v=m[k];"
        + "if(v.muted&&v.loop&&!v.controls)continue;"
        + "if(!v.paused&&!v.ended&&v.readyState>2)r|=4;else if(v.paused&&!v.ended&&v.currentTime>0)r|=8;"
        + "if(v.webkitPresentationMode==='picture-in-picture')r|=16}"
        + "if(document.pictureInPictureElement||(window.documentPictureInPicture&&documentPictureInPicture.window))r|=16}catch(x){}"
        + "return r})()"
}

extension WindowController {
    /// Restart to Update shows a tab it would quit behind: its Space, then the tab (its split too), the page not focused.
    func selectForUpdate(_ tabID: String) {
        guard let tab = store.tab(tabID) else { return }
        if let sid = tab.spaceID, sid != currentSpaceID, store.space(sid) != nil { switchToSpace(sid, animated: false) }
        show(tabID, focus: false)
    }

    /// Calls, screen sharing, music or video (playing, paused part-way, in picture in picture), running downloads,
    /// loading pages, pages that would ask "Leave site?" or have changed form fields, and Developer Mode pages (each
    /// page answers itself within `answerTime`; one that doesn't counts as `unanswered`).
    func updateRestartRisks(answerTime: TimeInterval = UpdateRestartRisks.answerTime, _ done: @escaping (UpdateRestartRisks) -> Void) {
        var risks = UpdateRestartRisks()
        risks.downloads = MediaLibrary.shared.downloads?.runningCount ?? 0
        let site = app?.engine as? EngineSiteControls, media = app?.engine as? EngineMedia
        let live = pages.filter { !$0.value.isClosed }.sorted { $0.key < $1.key }.map { (id: $0.key, page: $0.value) }
        for (_, page) in live {
            let activity = site?.siteActivity(of: page) ?? SiteActivity(), session = media?.mediaSession(of: page) ?? EngineMediaSession()
            if UpdateRestartRisks.usesCameraOrMicrophone(activity: activity, media: session) { risks.call = true }
            if UpdateRestartRisks.sharesScreen(activity: activity, media: session) { risks.screenSharing = true }
            if page.isAudible || session.playback == .playing { risks.playing = true }
            if session.playback == .paused, (session.position ?? 0) > 0 { risks.pausedMedia = true }
            if page.isLoading { risks.loading += 1 }
            if DeveloperMode.shared.applies(to: page) { risks.developerMode += 1 }
        }
        var waiting = live.count, finished = false
        var answered: [String: UpdateRestartRisks.BlockingTab.Reason?] = [:]
        let finish = { [weak self] in
            guard !finished else { return }
            finished = true
            // In the sidebar's order where it has one; the pages still quiet now are unknown, never "nothing to lose".
            let order = self.map { c in Dictionary(c.store.todayTabs(ofSpace: c.currentSpaceID).enumerated().map { ($1.id, $0) },
                                                   uniquingKeysWith: { a, _ in a }) } ?? [:]
            for (id, _) in live.sorted(by: { (order[$0.id] ?? Int.max, $0.id) < (order[$1.id] ?? Int.max, $1.id) }) {
                let reason: UpdateRestartRisks.BlockingTab.Reason?
                if let a = answered[id] { reason = a } else { reason = .unanswered }
                guard let reason else { continue }
                let tab = self?.store.tab(id)
                let title = [self?.pages[id]?.title, tab?.title, tab?.url].compactMap { $0 }.first { !$0.isEmpty } ?? "Untitled"
                risks.blockingTabs.append(.init(tabID: id, title: title, reason: reason))
            }
            risks.unanswered = waiting
            done(risks)
        }
        guard waiting > 0 else { return finish() }
        for (id, page) in live {
            page.evaluate(UpdateRestartRisks.pageScript) { answer in
                guard !finished else { return }
                let bits = (answer as? NSNumber)?.intValue ?? 0
                if bits & 1 != 0 { risks.leaveSite += 1 }
                if bits & 2 != 0 { risks.editedForms += 1 }
                if bits & 4 != 0 { risks.playing = true }
                if bits & 8 != 0 { risks.pausedMedia = true }
                if bits & 16 != 0 { risks.pictureInPicture = true }
                answered.updateValue(bits & 1 != 0 ? .leaveSite : bits & 2 != 0 ? .editedForm : nil, forKey: id)
                waiting -= 1
                if waiting == 0 { finish() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + answerTime) { finish() }
    }
}

// MARK: - The button

/// Above the footer (SidebarView), in the docked and the revealed sidebar alike: a 34 pt pill on a Favorites tile's
/// fill with a hint of the theme's accent, the app icon, "New Airc Version Available" ("Restart to Update" under the
/// pointer) and a restart glyph. When the update's feed says what it brings, its first lines sit under the pill on the
/// same plate (one line each, with its symbol), and the whole card restarts. With no update it takes no space; it rises
/// on the row spring.
///
/// The same spot and plate show "What's new" after an update (Browser/WhatsNewCard.swift): "Airc 0.1.13 is here", up
/// to five lines, "And more", See All (the changelog in a new tab) and × to dismiss. A ready update takes the spot
/// while there is one; the card comes back after it.
final class UpdateButtonView: NSView {
    static let pillHeight: CGFloat = 34
    static let topInset: CGFloat = 6
    static let bottomInset: CGFloat = 2
    /// A highlight line: callout text on a 20 pt row, its symbol centred under the app icon. A title too long for one
    /// line (the 26-character titles fit one at the default 228 pt sidebar; at the 164 pt minimum some don't) wraps to
    /// a second, which adds `wrapHeight`; past two lines it ends in "…".
    static let lineHeight: CGFloat = 20
    static let wrapHeight: CGFloat = 15
    static let maxTitleLines = 2
    /// The text column: after the icon column (inset 8 + 9 + 18 + 8) to 10 pt before the plate's right edge.
    static func textWidth(forViewWidth w: CGFloat) -> CGFloat { max(0, w - 2 * AircMetrics.Sidebar.inset - 9 - 18 - 8 - 10) }
    static let lineFont = AircFont.callout.appFont
    /// Lines (1 or 2) a title takes in a text column `width` wide.
    static func titleLines(_ title: String, width: CGFloat) -> Int {
        guard width > 0 else { return 1 }
        let one = ceil(lineFont.ascender - lineFont.descender + lineFont.leading)
        let r = (title as NSString).boundingRect(with: NSSize(width: width, height: 1000), options: [.usesLineFragmentOrigin],
                                                 attributes: [.font: lineFont])
        return min(maxTitleLines, max(1, Int((ceil(r.height) / one).rounded())))
    }
    /// Where the first line starts under the pill's top (the pill's lower 4 pt are the card's spacing).
    static let linesTop: CGFloat = 30
    static let linesBottom: CGFloat = 6
    /// Longest first: the first that fits the sidebar's width.
    static let titles = ["New Airc Version Available", "New Version Available", "Update Airc"]
    static let hoverTitle = "Restart to Update"
    static let seeAllTitle = "See All"
    static let moreTitle = "And more"

    /// What the spot shows.
    enum Mode: Equatable {
        case none
        case update
        case whatsNew(WhatsNewContent)
    }

    weak var controller: WindowController?
    /// The height the sidebar gives it now (animated).
    private(set) var height: CGFloat = 0
    private var target: CGFloat = 0
    private(set) var mode: Mode = .none
    var palette: Palette? { didSet { if palette?.resolved != oldValue?.resolved { style() } } }
    private let plate = CALayer()
    private let tint = CALayer()
    private let icon = CALayer()
    private let glyph = CALayer()
    let title = NSTextField(labelWithString: "")
    /// The highlight lines under the pill (update) or the title (What's new), and their symbols.
    private(set) var lineLabels: [NSTextField] = []
    private var lineIcons: [CALayer] = []
    private var lines: [WhatsNewHighlight] = []
    /// Each line's row count at the current width (1 or 2).
    private(set) var rowLines: [Int] = []
    let moreLabel = NSTextField(labelWithString: UpdateButtonView.moreTitle)
    let seeAll = NSButton(title: UpdateButtonView.seeAllTitle, target: nil, action: nil)
    let close = NSButton(title: "", target: nil, action: nil)
    private(set) var hovered = false { didSet { if hovered != oldValue { style(); needsLayout = true } } }
    private var pressed = false { didSet { if pressed != oldValue { style() } } }
    private var observers: [NSObjectProtocol] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clipsToBounds = true
        for l in [plate, tint, icon, glyph] {
            l.actions = LayerImage.noActions
            layer?.addSublayer(l)
        }
        for l in [plate, tint] {
            l.cornerRadius = AircRadius.tile
            l.cornerCurve = .continuous
        }
        icon.contents = AppIconImage.image
        icon.contentsGravity = .resizeAspect
        icon.minificationFilter = .trilinear
        glyph.contentsGravity = .center
        title.font = AircFont.callout.weight(.semibold).appFont
        title.lineBreakMode = .byClipping
        title.maximumNumberOfLines = 1
        addSubview(title)
        moreLabel.font = AircFont.callout.appFont
        moreLabel.lineBreakMode = .byTruncatingTail
        moreLabel.setAccessibilityElement(false)
        addSubview(moreLabel)
        seeAll.isBordered = false
        seeAll.font = AircFont.callout.weight(.semibold).appFont
        seeAll.alignment = .left
        seeAll.target = self
        seeAll.action = #selector(seeAllClicked)
        seeAll.setAccessibilityLabel("See what’s new, explained")
        addSubview(seeAll)
        close.isBordered = false
        close.imagePosition = .imageOnly
        close.target = self
        close.action = #selector(closeClicked)
        close.setAccessibilityLabel("Dismiss What’s New")
        close.toolTip = "Dismiss"
        addSubview(close)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        for name in [UpdateCenter.changed, WhatsNewCenter.changed] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.contentChanged()
            })
        }
        contentChanged(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The update pill (or card) shows: what the restart question, the downloads card and the checks anchor to.
    var isShowing: Bool { target > 0 }
    var showsUpdate: Bool { mode == .update && isShowing }
    var whatsNew: WhatsNewContent? { if case .whatsNew(let c) = mode { return c } else { return nil } }

    /// The plate: the pill, and the lines under it when there are any.
    var pillRect: NSRect {
        let inset = AircMetrics.Sidebar.inset
        let h = Self.cardHeight(mode: mode, rows: rowLines)
        return NSRect(x: inset, y: bounds.height - Self.bottomInset - h, width: max(0, bounds.width - 2 * inset), height: h)
    }

    /// The plate's height for a mode and its lines' row counts.
    static func cardHeight(mode: Mode, rows: [Int]) -> CGFloat {
        let body = rows.reduce(0) { $0 + lineHeight + CGFloat($1 - 1) * wrapHeight }
        switch mode {
        case .none: return pillHeight
        case .update: return rows.isEmpty ? pillHeight : linesTop + body + linesBottom
        case .whatsNew(let c): return linesTop + body + CGFloat((c.more ? 1 : 0) + 1) * lineHeight + linesBottom + 2
        }
    }

    /// The width the sidebar gives it (before its first layout, the sidebar's, else the default).
    private var layoutWidth: CGFloat {
        if bounds.width > 0 { return bounds.width }
        if let w = superview?.bounds.width, w > 0 { return w }
        return AircMetrics.Sidebar.defaultWidth
    }

    private func measureRows(width: CGFloat) -> [Int] {
        // 4 pt under the column: the text field's own line padding.
        lines.map { Self.titleLines($0.title, width: Self.textWidth(forViewWidth: width) - 4) }
    }

    private var targetHeight: CGFloat {
        mode == .none ? 0 : Self.topInset + Self.cardHeight(mode: mode, rows: rowLines) + Self.bottomInset
    }

    /// The sidebar was resized: titles may wrap differently, so the card takes its new height at once.
    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        guard widthChanged, newSize.width > 0, mode != .none else { return }
        let rows = measureRows(width: newSize.width)
        guard rows != rowLines else { return }
        rowLines = rows
        target = targetHeight
        height = target
        needsLayout = true
        superview?.needsLayout = true
    }

    private func contentChanged(animated: Bool = true) {
        let ready = UpdateCenter.shared.ready
        let card = WhatsNewCenter.shared.content
        let newMode: Mode = ready != nil ? .update : card.map { .whatsNew($0) } ?? .none
        let incoming = WhatsNewCenter.shared.isEnabled ? Array((ready?.highlights ?? []).prefix(WhatsNewAppcast.maxLines)) : []
        if newMode != mode {
            mode = newMode
            switch newMode {
            case .none: lines = []
            case .update: lines = incoming
            case .whatsNew(let c): lines = c.lines
            }
            rebuildLines()
        } else if case .update = newMode, incoming != lines {
            lines = incoming
            rebuildLines()
        }
        switch mode {
        case .none, .update:
            setAccessibilityRole(.button)
            let lineText = lines.isEmpty ? "" : ". What’s new: " + lines.map(\.spoken).joined(separator: "; ")
            toolTip = ready.map { ($0.restartNotice ?? "Restart Airc to update to \($0.version)") + (lines.isEmpty ? "" : "\n" + lines.map { "• " + $0.spoken }.joined(separator: "\n")) }
            setAccessibilityLabel(ready.map { ($0.restartNotice ?? "New Airc version available. Restart to update") + lineText })
        case .whatsNew(let c):
            hovered = false
            setAccessibilityRole(.group)
            setAccessibilityLabel(WhatsNewCenter.title(c) + ". " + c.lines.map(\.spoken).joined(separator: "; ") + (c.more ? "; and more" : ""))
            toolTip = nil
        }
        seeAll.isHidden = whatsNew == nil
        close.isHidden = whatsNew == nil
        moreLabel.isHidden = whatsNew?.more != true
        glyph.isHidden = whatsNew != nil
        if ready == nil { hovered = false }
        rowLines = measureRows(width: layoutWidth)
        let h = targetHeight
        style()
        needsLayout = true
        guard h != target else { return }
        target = h
        guard animated, !AircMotion.prefersReducedMotion, let c = controller, window != nil, !isHiddenOrHasHiddenAncestor else {
            if animated, AircMotion.prefersReducedMotion, window != nil {
                // Reduce Motion: nothing rises or slides; the sidebar cross-fades the change in 150 ms.
                (superview?.layer ?? layer)?.add(AircMotion.crossfadeTransition(), forKey: kCATransition)
            }
            return setHeight(h)
        }
        c.animator.spring("update-button", from: Double(height), to: Double(h), velocity: 0, spring: Spring(AircSpring.row),
                          update: { [weak self] v in self?.setHeight(CGFloat(v)) }, completion: { [weak self] in self?.setHeight(h) })
    }

    private func rebuildLines() {
        while lineLabels.count < lines.count {
            let l = NSTextField(labelWithString: "")
            l.font = AircFont.callout.appFont
            l.lineBreakMode = .byWordWrapping
            l.cell?.wraps = true
            l.cell?.truncatesLastVisibleLine = true
            l.maximumNumberOfLines = Self.maxTitleLines
            l.setAccessibilityElement(false)
            addSubview(l)
            lineLabels.append(l)
            let i = CALayer()
            i.actions = LayerImage.noActions
            i.contentsGravity = .center
            layer?.addSublayer(i)
            lineIcons.append(i)
        }
        for (i, l) in lineLabels.enumerated() {
            let shown = i < lines.count
            l.isHidden = !shown
            lineIcons[i].isHidden = !shown
            l.stringValue = shown ? lines[i].title : ""
            l.toolTip = shown && lines[i].spoken != lines[i].title ? lines[i].spoken : nil
        }
    }

    private func setHeight(_ h: CGFloat) {
        height = max(0, h)
        superview?.needsLayout = true
        superview?.layoutSubtreeIfNeeded()
        MediaLibrary.shared.layoutPrompts()
        UpdateCenter.shared.confirm?.layoutInWindow()
    }

    private func style() {
        guard let palette else { return }
        let r = palette.resolved
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        plate.backgroundColor = (hovered ? palette.tileHover : palette.tileFill).cgColor
        tint.backgroundColor = r.accent.nsColor.withAlphaComponent(r.isDark ? 0.16 : 0.10).cgColor
        CATransaction.commit()
        title.textColor = palette.textPrimary
        LayerImage.set(LayerImage.symbol("arrow.clockwise", size: 11, weight: .semibold, color: r.accent.nsColor), on: glyph, in: self)
        for (i, l) in lineLabels.enumerated() {
            l.textColor = palette.textSecondary
            guard i < lines.count else { continue }
            let image = LayerImage.symbol(lines[i].icon, size: 11, weight: .medium, color: r.accent.nsColor)
                ?? LayerImage.symbol("sparkles", size: 11, weight: .medium, color: r.accent.nsColor)
            LayerImage.set(image, on: lineIcons[i], in: self)
        }
        moreLabel.textColor = palette.textSecondary
        seeAll.contentTintColor = r.accentText.nsColor
        seeAll.attributedTitle = NSAttributedString(string: Self.seeAllTitle, attributes: [
            .font: AircFont.callout.weight(.semibold).appFont, .foregroundColor: r.accentText.nsColor])
        close.image = LayerImage.symbol("xmark", size: 9, weight: .bold, color: palette.textSecondary)
        // Pressed: the plate shrinks to 0.99 over 70 ms, like a tab's (Arc ref §2.8).
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.07)
        let scale = pressed ? CATransform3DMakeScale(0.99, 0.99, 1) : CATransform3DIdentity
        for l in [plate, tint] { l.transform = scale }
        CATransaction.commit()
    }

    /// The header row: the pill's 34 pt at the plate's top.
    private var headerRect: NSRect {
        let p = pillRect
        return NSRect(x: p.minX, y: p.minY, width: p.width, height: Self.pillHeight)
    }

    /// Line `i`'s row (0-based; the "And more" and See All rows follow the lines).
    func lineRect(_ i: Int) -> NSRect {
        let p = pillRect
        func h(_ k: Int) -> CGFloat { Self.lineHeight + CGFloat((k < rowLines.count ? rowLines[k] : 1) - 1) * Self.wrapHeight }
        let y = (0..<i).reduce(p.minY + Self.linesTop) { $0 + h($1) }
        return NSRect(x: p.minX, y: y, width: p.width, height: h(i))
    }

    /// × in the header's right, where the restart glyph sits on the pill.
    var closeRect: NSRect {
        let hr = headerRect
        return NSRect(x: hr.maxX - 6 - 22, y: hr.midY - 11, width: 22, height: 22)
    }

    var seeAllRect: NSRect { lineRect(lines.count + (whatsNew?.more == true ? 1 : 0)) }

    override func layout() {
        super.layout()
        let p = pillRect, hr = headerRect
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        plate.frame = p
        tint.frame = p
        icon.frame = NSRect(x: hr.minX + 9, y: hr.midY - 9, width: 18, height: 18)
        glyph.frame = NSRect(x: hr.maxX - 10 - 14, y: hr.midY - 7, width: 14, height: 14)
        let textX = icon.frame.maxX + 8
        for (i, l) in lineLabels.enumerated() where i < lines.count {
            // The symbol sits on the first line; a second line runs under the first, in the text column.
            let row = lineRect(i), first = row.minY + Self.lineHeight / 2
            lineIcons[i].frame = NSRect(x: icon.frame.midX - 8, y: first - 8, width: 16, height: 16)
            let one = ceil(Self.lineFont.ascender - Self.lineFont.descender + Self.lineFont.leading)
            let n = CGFloat(i < rowLines.count ? rowLines[i] : 1)
            let th = one + (n - 1) * Self.wrapHeight + 1
            l.frame = NSRect(x: textX, y: floor(first - one / 2), width: max(0, p.maxX - 10 - textX), height: th)
        }
        CATransaction.commit()
        if whatsNew != nil {
            let more = lineRect(lines.count)
            let mh = ceil(moreLabel.intrinsicContentSize.height)
            moreLabel.frame = NSRect(x: textX, y: floor(more.midY - mh / 2), width: max(0, p.maxX - 10 - textX), height: mh)
            let sa = seeAllRect
            seeAll.sizeToFit()
            seeAll.frame = NSRect(x: textX - 1, y: floor(sa.midY - seeAll.frame.height / 2), width: seeAll.frame.width, height: seeAll.frame.height)
            close.frame = closeRect
        }
        let x = textX, end = (whatsNew != nil ? closeRect.minX : glyph.frame.minX) - 6
        let available = max(0, end - x)
        let text: String
        if let c = whatsNew {
            // "Airc 0.1.12 is here", or just "Airc 0.1.12" in a narrow sidebar: never cut off.
            let titles = WhatsNewCenter.titles(c)
            text = titles.first { fits($0, in: available) } ?? titles.last!
            title.lineBreakMode = .byTruncatingTail
        } else {
            let titles = UpdateCenter.shared.ready?.pillTitles ?? Self.titles
            text = UpdateCenter.shared.checking ? UpdateCenter.checkingTitle
                : hovered ? Self.hoverTitle : titles.first { fits($0, in: available) } ?? titles.last!
            title.lineBreakMode = .byClipping
        }
        if title.stringValue != text { title.stringValue = text }
        let th = ceil(title.intrinsicContentSize.height)
        title.frame = NSRect(x: x, y: floor(hr.midY - th / 2), width: available, height: th)
    }

    private func fits(_ s: String, in width: CGFloat) -> Bool {
        guard let font = title.font else { return true }
        return ceil((s as NSString).size(withAttributes: [.font: font]).width) + 4 <= width
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { updateHover(event) }
    override func mouseMoved(with event: NSEvent) { updateHover(event) }
    override func mouseExited(with event: NSEvent) { hovered = false }

    private func updateHover(_ event: NSEvent) {
        hovered = showsUpdate && pillRect.contains(convert(event.locationInWindow, from: nil))
    }

    /// Outside the plate (its top inset) clicks go through to the sidebar. On What's new the buttons take theirs, and
    /// the rest of the card is just the card (no window drag, no click through to the list under it).
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isShowing, let s = superview else { return nil }
        let local = convert(point, from: s)
        guard pillRect.contains(local) else { return nil }
        if whatsNew != nil {
            for b in [close, seeAll] where !b.isHidden && b.frame.insetBy(dx: -4, dy: -3).contains(local) { return b }
        }
        return self
    }

    #if AIRC_TESTING
    /// Presses and releases this view got (the checks' diagnostics).
    private(set) var presses = (down: 0, up: 0)
    #endif

    override func mouseDown(with event: NSEvent) {
        if whatsNew != nil { return }   // whatsnew2: the card's body opens the What's new tab on mouse-up
        guard showsUpdate else { return }
        pressed = true
        #if AIRC_TESTING
        presses.down += 1
        #endif
    }

    override func mouseUp(with event: NSEvent) {
        if whatsNew != nil {
            if pillRect.contains(convert(event.locationInWindow, from: nil)) { WhatsNewCenter.shared.seeAll(from: controller) }
            return
        }
        guard showsUpdate else { return }
        pressed = false
        #if AIRC_TESTING
        presses.up += 1
        #endif
        guard pillRect.contains(convert(event.locationInWindow, from: nil)) else { return }
        UpdateCenter.shared.restart(from: controller)
    }

    override func accessibilityPerformPress() -> Bool {
        guard showsUpdate else { return false }
        UpdateCenter.shared.restart(from: controller)
        return true
    }

    override func accessibilityChildren() -> [Any]? {
        whatsNew == nil ? super.accessibilityChildren() : [seeAll, close]
    }

    @objc private func seeAllClicked() { WhatsNewCenter.shared.seeAll(from: controller) }
    @objc private func closeClicked() { WhatsNewCenter.shared.dismiss() }

    /// Right-click: Restart to Update and See What's New (the update only).
    override func menu(for event: NSEvent) -> NSMenu? {
        guard showsUpdate, pillRect.contains(convert(event.locationInWindow, from: nil)) else { return nil }
        return pillMenu()
    }

    func pillMenu() -> NSMenu {
        let menu = NSMenu()
        menu.add(Self.hoverTitle) { [weak self] in UpdateCenter.shared.restart(from: self?.controller) }
        menu.add(UpdateConfirmModel.whatsNewTitle) { [weak self] in UpdateCenter.shared.showWhatsNew(from: self?.controller) }
        return menu
    }

    /// For the checks: forces the hover look.
    func setHoveredForSnapshot(_ h: Bool) { hovered = h }
}

// MARK: - The question

final class UpdateConfirmModel: ObservableObject {
    static let whatsNewTitle = "See What’s New"
    let risks: UpdateRestartRisks
    let theme: ResolvedTheme
    /// true: restart now.
    var onAnswer: ((Bool) -> Void)?
    var onWhatsNew: (() -> Void)?
    /// A blocking tab's row: selects it.
    var onSelectTab: ((String) -> Void)?
    /// Tabs that would be quit behind: "Restart Anyway" and "Cancel" instead of "Restart" and "Not Now".
    var blocks: Bool { !risks.blockingTabs.isEmpty }
    static let restartAnywayTitle = "Restart Anyway"
    static let cancelTitle = "Cancel"

    init(risks: UpdateRestartRisks, theme: ResolvedTheme) {
        self.risks = risks
        self.theme = theme
    }
}

/// The downloads' "still running" card (DownloadViews.swift), sized to the sidebar: what would be lost, Restart, and
/// Not Now as the default.
struct UpdateConfirmCard: View {
    @ObservedObject var model: UpdateConfirmModel
    let width: CGFloat
    private var ui: ResolvedTheme { model.theme }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ui.accent.color)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ui.tileFill.color))
                Text("Restart to update Airc?").aircFont(AircFont.title3).foregroundStyle(ui.surfaceText.color)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.risks.lines, id: \.self) { line in
                    Text(line).aircFont(AircFont.callout).foregroundStyle(ui.surfaceTextSecondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.blocks { blockingRows.padding(.vertical, 2) }
                Text("Your Spaces and tabs come back as they are.").aircFont(AircFont.callout)
                    .foregroundStyle(ui.surfaceTextSecondary.color).fixedSize(horizontal: false, vertical: true)
                Button(UpdateConfirmModel.whatsNewTitle) { model.onWhatsNew?() }.buttonStyle(.plain)
                    .aircFont(AircFont.callout.weight(.medium)).foregroundStyle(ui.accentText.color)
                    .padding(.top, 2).testAnchor("update.whatsNew")
            }
            .padding(.top, 10)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { Spacer(minLength: 0); restart; notNow }
                VStack(alignment: .trailing, spacing: 6) { restart; notNow }.frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.top, 14)
        }
        .padding(14)
        .frame(width: width, alignment: .leading)
        .onExitCommand { model.onAnswer?(false) }
        .testAnchorRoot()
        .aircTheme(ui)
    }

    /// The tabs a restart would quit behind, each one a row that selects it (the first is already selected); a hung one has an hourglass.
    private var blockingRows: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(model.risks.blockingTabs.prefix(4).enumerated()), id: \.offset) { i, t in
                Button { model.onSelectTab?(t.tabID) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: t.reason == .unanswered ? "hourglass" : "doc.text").font(.system(size: 11, weight: .medium))
                            .foregroundStyle(ui.surfaceTextSecondary.color).frame(width: 14)
                        Text(t.title).aircFont(AircFont.callout.weight(.medium)).foregroundStyle(ui.surfaceText.color)
                            .lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 6).frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(ui.tileFill.color))
                    .contentShape(Rectangle())
                }
                // A hung tab: the hourglass (the line above says it isn't responding); the title keeps the row's width.
                .buttonStyle(.plain).help(t.reason == .unanswered ? "Not responding. Show this tab" : "Show this tab")
                .accessibilityLabel(t.reason == .unanswered ? "\(t.title), not responding" : t.title)
                .testAnchor("update.blockingTab\(i)")
            }
            if model.risks.blockingTabs.count > 4 {
                Text("and \(model.risks.blockingTabs.count - 4) more").aircFont(AircFont.caption).foregroundStyle(ui.surfaceTextSecondary.color)
            }
        }
    }

    private var restart: some View {
        Button(model.blocks ? UpdateConfirmModel.restartAnywayTitle : "Restart") { model.onAnswer?(true) }
            .buttonStyle(.airc(.secondary, size: .small)).testAnchor("update.restartAnyway")
    }

    private var notNow: some View {
        Button(model.blocks ? UpdateConfirmModel.cancelTitle : "Not Now") { model.onAnswer?(false) }
            .buttonStyle(.airc(.primary, size: .small)).keyboardShortcut(.defaultAction)
            .testAnchor("update.notNow")
    }
}

/// The card's view: the surface panel with the popover shadow, just above the button (or the page's bottom-left when
/// the sidebar is away).
final class UpdateConfirmView: NSView {
    let model: UpdateConfirmModel
    private weak var controller: WindowController?
    private var host: AircFirstClickHostingView<UpdateConfirmCard>

    init(model: UpdateConfirmModel, controller: WindowController) {
        self.model = model
        self.controller = controller
        host = AircFirstClickHostingView(rootView: UpdateConfirmCard(model: model, width: 260))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = AircRadius.popover
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = model.theme.surface.nsColor.cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = model.theme.surfaceBorder.nsColor.cgColor
        layer?.applyAircShadow(.popover)
        host.safeAreaRegions = []
        addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    var hostingView: NSView { host }

    /// Above the button while the sidebar shows it (docked or revealed), and above the media tray too when the tray
    /// shows (it sits over the pill: the question never covers its players or downloads); else at the page's bottom-left
    /// (bottom-right with the sidebar on the right, WIN-5).
    func layoutInWindow() {
        guard let c = controller else { return }
        let button = c.sidebar.update, tray = c.sidebar.tray
        let onScreen = button.isShowing && (c.sidebarFraction >= 1 || c.revealController?.isRevealed == true)
        var anchor = onScreen ? c.root.convert(button.pillRect, from: button)
            : NSRect(x: c.sidebarOnRight ? c.card.frame.maxX - AircMetrics.Sidebar.inset - 260 : c.card.frame.minX + AircMetrics.Sidebar.inset,
                     y: c.card.frame.maxY - 10, width: 260, height: 0)
        if onScreen, tray.height > 0 {
            // The tray's height includes its 6 pt top inset: the question keeps 12 pt from its rows, as the downloads card.
            let top = c.root.convert(tray.bounds, from: tray).minY
            anchor = NSRect(x: anchor.minX, y: top, width: anchor.width, height: max(0, anchor.maxY - top))
        }
        if host.rootView.width != anchor.width { host.rootView = UpdateConfirmCard(model: model, width: anchor.width) }
        let size = host.fittingSize
        let x = min(max(8, anchor.minX), max(8, c.root.bounds.width - size.width - 8))
        frame = NSRect(x: x.rounded(), y: max(8, anchor.minY - 6 - size.height).rounded(), width: size.width, height: size.height)
        host.frame = bounds
    }

    /// Rises 6 pt and fades in on the dialog curve.
    func present() {
        guard let layer else { return }
        let curve = AircCurve.dialog
        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        rise.fromValue = 6
        rise.toValue = 0
        rise.duration = curve.duration
        rise.timingFunction = curve.timingFunction
        layer.add(rise, forKey: "rise")
        layer.fade(from: 0, to: 1, duration: 0.15)
    }
}

// MARK: - Settings › General

/// whatsnew2: the words of Settings › General › Automatic Updates › After an update.
enum WhatsNewSettingsText {
    static func title(_ s: WhatsNewStyle) -> String {
        switch s {
        case .tab: "Open a tab"
        case .card: "Show a card"
        case .off: "Don’t show"
        }
    }

    static func subtitle(_ s: WhatsNewStyle) -> String {
        switch s {
        case .tab: "A What’s new tab opens once, explaining each new thing and where to find it. Restart to Update shows the first lines too."
        case .card: "A small card above the sidebar’s footer lists what’s new for three launches; click it for the What’s new tab. Restart to Update shows the first lines too."
        case .off: "Airc only says it was updated, with a link to the release notes."
        }
    }
}

/// E13, Arc's "Automatically update my Arc" (its Settings › General › Updates, off until the person turns it on):
/// whether a downloaded update may restart Airc by itself while the person is away (IdleUpdatePolicy).
struct UpdateWhenIdleSection: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        SettingsSection(title: "Automatic Updates") {
            AircToggleRow("Automatically update my Airc",
                          subtitle: "Off, an update waits until you click Restart to Update or quit. On, Airc restarts into it after 30 minutes without use, never while music or video plays or is paused part-way, during a call or screen sharing, a download, a page with changes or typed text, or with a private window or a dialog open. Your windows, Spaces and tabs come back as they were.",
                          isOn: Binding(get: { model.settings.values.restartToUpdateWhenIdle },
                                        set: { model.settings.values.restartToUpdateWhenIdle = $0; UpdateCenter.shared.scheduleIdleCheck() }))
            // whatsnew2: one choice for both the tab and the card (Browser/WhatsNewPage.swift, WhatsNewCard.swift).
            SettingsRow(title: "After an update", subtitle: WhatsNewSettingsText.subtitle(model.settings.values.whatsNewStyle)) {
                AircSegmented(selection: Binding(get: { model.settings.values.whatsNewStyle },
                                                 set: { model.settings.values.whatsNewStyle = $0; WhatsNewCenter.shared.settingChanged($0) }),
                              segments: WhatsNewStyle.allCases.map { .init(value: $0, title: WhatsNewSettingsText.title($0)) })
                    .frame(width: 270)
            }
            .testAnchor("settings.whatsNew")
        }
    }
}

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit
import IOKit
import SwiftUI

// The sidebar's update button, as in Arc (Arc ref §2.9 "Update banner"): once Sparkle has downloaded and verified an
// update, a pill above the footer reads "New Airc Version Available"; a click restarts into it. Music or video
// playing, a call, a running download or a page that would ask "Leave site?" (in any window) gets a calm question first.
// Left alone, the update installs when Airc quits; with Arc's "Automatically update my Arc" turned on (off by default,
// Settings › General › Automatic Updates) it restarts by itself after 30 minutes without input on the Mac, when
// nothing would be interrupted (IdleUpdatePolicy). The
// pill's menu and the question offer the update's release notes ("See What's New"); after the restart a toast says
// it's updated. Sparkle's delegate (App/AircUpdateDelegate.swift) drives it; checks inject a fake.

// MARK: - The state

/// A downloaded, verified update waiting to install: Sparkle's immediate-installation block in dev builds, a fake in
/// scripted checks (which never start the real updater).
protocol ReadyUpdate: AnyObject {
    /// "1.0 (202611061200)", for the tooltip and Updates.log.
    var version: String { get }
    /// The update's own release notes (its appcast item's), if it has them.
    var releaseNotesURL: URL? { get }
    /// Installs it and relaunches Airc. Sparkle quits the app the usual way (state is saved, pages may still ask
    /// "Leave site?"); if the quit is cancelled the update stays ready and this can run again.
    func installAndRelaunch()
}

extension ReadyUpdate {
    var releaseNotesURL: URL? { nil }
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
    func restart(from controller: WindowController?) {
        guard let update = ready, !asking, confirm == nil else { return }
        Telemetry.shared.record(.featureUsed(.updateRestartClicked))
        guard let c = controller else { return install(update, downloads: false) }
        asking = true
        let probe = riskProbe ?? { _, done in Self.risksInEveryWindow(done) }
        probe(c) { [weak self, weak c] risks in
            guard let self else { return }
            self.asking = false
            guard let c, self.ready === update else { return }
            if risks.isEmpty {
                self.install(update, downloads: false)
            } else {
                self.log("restart asks first: \(risks.logText)")
                self.ask(risks, in: c, update: update)
            }
        }
    }

    private func ask(_ risks: UpdateRestartRisks, in c: WindowController, update: ReadyUpdate) {
        let model = UpdateConfirmModel(risks: risks, theme: c.currentPalette.resolved)
        let v = UpdateConfirmView(model: model, controller: c)
        model.onAnswer = { [weak self] restart in
            guard let self else { return }
            self.dismissConfirm()
            if restart, self.ready === update { self.install(update, downloads: risks.downloads > 0) }
            else { self.log("restart: not now") }
        }
        model.onWhatsNew = { [weak self, weak c] in self?.showWhatsNew(from: c) }
        c.root.addSubview(v, positioned: .below, relativeTo: c.toast)
        confirm = v
        v.layoutInWindow()
        v.present()
    }

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
        update.installAndRelaunch()
    }

    /// Every browser window's risks together (WIN-7: a call in another window counts too); downloads are the app's.
    static func risksInEveryWindow(_ done: @escaping (UpdateRestartRisks) -> Void) {
        let controllers = (NSApp.delegate as? AppDelegate)?.controllers ?? []
        var total = UpdateRestartRisks()
        total.downloads = MediaLibrary.shared.downloads?.runningCount ?? 0
        var waiting = controllers.count
        guard waiting > 0 else { return done(total) }
        for c in controllers {
            c.updateRestartRisks { r in
                total.merge(r)
                waiting -= 1
                if waiting == 0 { done(total) }
            }
        }
    }

    // MARK: Restarting by itself (E13)

    /// How often a ready update looks whether it may restart by itself (only while one is ready and the setting is on).
    static let idleCheckInterval: TimeInterval = 60
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
        let probe = riskProbe ?? { _, done in Self.risksInEveryWindow(done) }
        let gather: (@escaping (UpdateRestartRisks) -> Void) -> Void = { finish in
            guard let c = (NSApp.delegate as? AppDelegate)?.controller else { return Self.risksInEveryWindow(finish) }
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
    static var runningVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))"
    }
    static func updatedMessage(_ version: String) -> String { "Updated! Airc \(version). Help › Release Notes has what’s new." }

    /// At launch (MainMenu.build): another version than the last run's means the update went in; the first window says
    /// so. Scripted runs skip it (their snapshots stay as they are) unless a check asks.
    func noteLaunchedVersion(inScriptedRun: Bool = false) {
        guard inScriptedRun || !LaunchOptions.current.isScripted else { return }
        let now = Self.runningVersion
        let before = (try? String(contentsOf: Self.lastVersionFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        if before != now { try? Data(now.utf8).write(to: Self.lastVersionFile, options: .atomic) }
        guard let before, !before.isEmpty, before != now else { return }
        log("updated from \(before)")
        announceUpdated(now, tries: 20)
    }

    private func announceUpdated(_ version: String, tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let c = (NSApp.delegate as? AppDelegate)?.controller, c.window.isVisible else {
                if tries > 0 { self?.announceUpdated(version, tries: tries - 1) }
                return
            }
            c.showToast(Self.updatedMessage(version))
        }
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
    }

    /// Nothing the question names: Restart to Update installs at once.
    var isEmpty: Bool { lines.isEmpty }

    /// Nothing at all a restart would interrupt (restarting by itself needs this; the question only names what's lost).
    var nothingInterrupted: Bool {
        isEmpty && !pausedMedia && !pictureInPicture && loading == 0 && developerMode == 0
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
        return out
    }

    var logText: String {
        "call \(call), screen \(screenSharing), playing \(playing), paused \(pausedMedia), pip \(pictureInPicture), downloads \(downloads), "
            + "loading \(loading), leave site \(leaveSite), edited \(editedForms), developer mode \(developerMode)"
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
    /// Calls, screen sharing, music or video (playing, paused part-way, in picture in picture), running downloads,
    /// loading pages, pages that would ask "Leave site?" or have changed form fields, and Developer Mode pages (each
    /// page answers itself, 0.5 s at most).
    func updateRestartRisks(_ done: @escaping (UpdateRestartRisks) -> Void) {
        var risks = UpdateRestartRisks()
        risks.downloads = MediaLibrary.shared.downloads?.runningCount ?? 0
        let site = app?.engine as? EngineSiteControls, media = app?.engine as? EngineMedia
        let live = pages.values.filter { !$0.isClosed }
        for page in live {
            let activity = site?.siteActivity(of: page) ?? SiteActivity(), session = media?.mediaSession(of: page) ?? EngineMediaSession()
            if UpdateRestartRisks.usesCameraOrMicrophone(activity: activity, media: session) { risks.call = true }
            if UpdateRestartRisks.sharesScreen(activity: activity, media: session) { risks.screenSharing = true }
            if page.isAudible || session.playback == .playing { risks.playing = true }
            if session.playback == .paused, (session.position ?? 0) > 0 { risks.pausedMedia = true }
            if page.isLoading { risks.loading += 1 }
            if DeveloperMode.shared.applies(to: page) { risks.developerMode += 1 }
        }
        var waiting = live.count, finished = false
        let finish = {
            guard !finished else { return }
            finished = true
            done(risks)
        }
        guard waiting > 0 else { return finish() }
        for page in live {
            page.evaluate(UpdateRestartRisks.pageScript) { answer in
                let bits = (answer as? NSNumber)?.intValue ?? 0
                if bits & 1 != 0 { risks.leaveSite += 1 }
                if bits & 2 != 0 { risks.editedForms += 1 }
                if bits & 4 != 0 { risks.playing = true }
                if bits & 8 != 0 { risks.pausedMedia = true }
                if bits & 16 != 0 { risks.pictureInPicture = true }
                waiting -= 1
                if waiting == 0 { finish() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { finish() }
    }
}

// MARK: - The button

/// Above the footer (SidebarView), in the docked and the revealed sidebar alike: a 34 pt pill on a Favorites tile's
/// fill with a hint of the theme's accent, the app icon, "New Airc Version Available" ("Restart to Update" under the
/// pointer) and a restart glyph. With no update it takes no space; it rises on the row spring.
final class UpdateButtonView: NSView {
    static let pillHeight: CGFloat = 34
    static let topInset: CGFloat = 6
    static let bottomInset: CGFloat = 2
    /// Longest first: the first that fits the sidebar's width.
    static let titles = ["New Airc Version Available", "New Version Available", "Update Airc"]
    static let hoverTitle = "Restart to Update"

    weak var controller: WindowController?
    /// The height the sidebar gives it now (animated).
    private(set) var height: CGFloat = 0
    private var target: CGFloat = 0
    var palette: Palette? { didSet { if palette?.resolved != oldValue?.resolved { style() } } }
    private let plate = CALayer()
    private let tint = CALayer()
    private let icon = CALayer()
    private let glyph = CALayer()
    let title = NSTextField(labelWithString: "")
    private(set) var hovered = false { didSet { if hovered != oldValue { style(); needsLayout = true } } }
    private var pressed = false { didSet { if pressed != oldValue { style() } } }
    private var observer: NSObjectProtocol?

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
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        observer = NotificationCenter.default.addObserver(forName: UpdateCenter.changed, object: nil, queue: .main) { [weak self] _ in
            self?.readyChanged()
        }
        readyChanged(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var isShowing: Bool { target > 0 }
    /// The pill, in this view.
    var pillRect: NSRect {
        let inset = AircMetrics.Sidebar.inset
        return NSRect(x: inset, y: bounds.height - Self.bottomInset - Self.pillHeight, width: max(0, bounds.width - 2 * inset),
                      height: Self.pillHeight)
    }

    private func readyChanged(animated: Bool = true) {
        let ready = UpdateCenter.shared.ready
        toolTip = ready.map { "Restart Airc to update to \($0.version)" }
        setAccessibilityLabel(ready.map { _ in "New Airc version available. Restart to update" })
        if ready == nil { hovered = false }
        let h: CGFloat = ready == nil ? 0 : Self.topInset + Self.pillHeight + Self.bottomInset
        guard h != target else { return }
        target = h
        needsLayout = true
        guard animated, let c = controller, window != nil, !isHiddenOrHasHiddenAncestor else { return setHeight(h) }
        c.animator.spring("update-button", from: Double(height), to: Double(h), velocity: 0, spring: Spring(AircSpring.row),
                          update: { [weak self] v in self?.setHeight(CGFloat(v)) }, completion: { [weak self] in self?.setHeight(h) })
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
        // Pressed: the plate shrinks to 0.99 over 70 ms, like a tab's (Arc ref §2.8).
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.07)
        let scale = pressed ? CATransform3DMakeScale(0.99, 0.99, 1) : CATransform3DIdentity
        for l in [plate, tint] { l.transform = scale }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        let p = pillRect
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        plate.frame = p
        tint.frame = p
        icon.frame = NSRect(x: p.minX + 9, y: p.midY - 9, width: 18, height: 18)
        glyph.frame = NSRect(x: p.maxX - 10 - 14, y: p.midY - 7, width: 14, height: 14)
        CATransaction.commit()
        let x = icon.frame.maxX + 8, end = glyph.frame.minX - 6
        let available = max(0, end - x)
        let text = hovered ? Self.hoverTitle : Self.titles.first { fits($0, in: available) } ?? Self.titles.last!
        if title.stringValue != text { title.stringValue = text }
        let th = ceil(title.intrinsicContentSize.height)
        title.frame = NSRect(x: x, y: floor(p.midY - th / 2), width: available, height: th)
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
        hovered = isShowing && pillRect.contains(convert(event.locationInWindow, from: nil))
    }

    /// Outside the pill (its top inset) clicks go through to the sidebar.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isShowing, let s = superview, pillRect.contains(convert(point, from: s)) else { return nil }
        return self
    }

    #if AIRC_TESTING
    /// Presses and releases this view got (the checks' diagnostics).
    private(set) var presses = (down: 0, up: 0)
    #endif

    override func mouseDown(with event: NSEvent) {
        pressed = true
        #if AIRC_TESTING
        presses.down += 1
        #endif
    }

    override func mouseUp(with event: NSEvent) {
        pressed = false
        #if AIRC_TESTING
        presses.up += 1
        #endif
        guard pillRect.contains(convert(event.locationInWindow, from: nil)) else { return }
        UpdateCenter.shared.restart(from: controller)
    }

    override func accessibilityPerformPress() -> Bool {
        UpdateCenter.shared.restart(from: controller)
        return true
    }

    /// Right-click: Restart to Update and See What's New.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard isShowing, pillRect.contains(convert(event.locationInWindow, from: nil)) else { return nil }
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
                Text("Your Spaces and tabs come back as they are.").aircFont(AircFont.callout)
                    .foregroundStyle(ui.surfaceTextSecondary.color).fixedSize(horizontal: false, vertical: true)
                Button(UpdateConfirmModel.whatsNewTitle) { model.onWhatsNew?() }.buttonStyle(.plain)
                    .aircFont(AircFont.callout.weight(.medium)).foregroundStyle(ui.accent.color)
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

    private var restart: some View {
        Button("Restart") { model.onAnswer?(true) }.buttonStyle(.airc(.secondary, size: .small)).testAnchor("update.restartAnyway")
    }

    private var notNow: some View {
        Button("Not Now") { model.onAnswer?(false) }.buttonStyle(.airc(.primary, size: .small)).keyboardShortcut(.defaultAction)
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
        }
    }
}

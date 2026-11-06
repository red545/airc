// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircDesign
import AircKit
import AppKit
import Combine

/// Launch Services stand-in: the checks never change the owner's real default browser.
final class FakeDefaultBrowser: DefaultBrowserSystem {
    var isDefault = false
    var currentName: String? { "Safari" }
    var canAsk: Bool { true }
    /// What the user picks in the (pretend) macOS dialog.
    var accepts = true
    private(set) var asked = 0

    func makeDefault(_ done: @escaping (Bool) -> Void) {
        asked += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if self.accepts { self.isDefault = true }
            done(self.isDefault)
        }
    }
}

/// Part of `--script events` (`AIRC_EVENTS_ONLY=defaultbrowser` alone): spec §2.13 step 5 and the reminder card.
///   - the reminder's rules against an injected clock (3 days, then 7 more, twice at most, the quiet minute, busy,
///     full screen, automated runs, the onboarding answer, Don't ask again);
///   - the real system refuses in an automated run;
///   - the onboarding step shows while Airc isn't the default (light and dark), "Not now" and "Make Default" record
///     their answer, and the step is skipped when Airc is the default;
///   - the sidebar card shows, and goes on Not now, Make Default and Don't ask again;
///   - the Settings rows' state follows a change made elsewhere once Airc is active again.
/// The card's SwiftUI buttons are pressed through their actions: posted clicks don't reach SwiftUI buttons in a
/// window that isn't key (docs: Mac UI test pitfalls).
extension SnapshotRunner {
    func defaultBrowserCheck() {
        let fake = FakeDefaultBrowser()
        run { [self] in
            defaultBrowserRules()
            let real = SystemDefaultBrowser()
            var answered: Bool?
            real.makeDefault { answered = $0 }
            check(!real.canAsk && answered == false, "default browser: the real system is never asked in an automated run")
            DefaultBrowser.shared.system = fake
        }
        defaultBrowserOnboarding(fake)
        defaultBrowserCard(fake)
        defaultBrowserLiveState(fake)
        run { DefaultBrowser.shared.system = SystemDefaultBrowser() }
    }

    // MARK: Rules (no window, injected clock)

    private func defaultBrowserRules() {
        typealias R = DefaultBrowserReminderRules
        var activity = SiteActivity()
        var media = EngineMediaSession()
        func busy(_ audible: Bool = false) -> Bool { R.isBusy(audible: audible, activity: activity, media: media) }
        check(!busy(), "default browser busy: idle is quiet")
        check(busy(true), "default browser busy: audible page")
        activity.camera = true
        check(busy(), "default browser busy: silent camera capture")
        activity = SiteActivity(); activity.microphone = true
        check(busy(), "default browser busy: silent microphone capture")
        activity = SiteActivity(); activity.screen = true
        check(busy(), "default browser busy: silent screen capture")
        activity = SiteActivity(); media.active = true
        check(busy(), "default browser busy: silent active media session")
        media = EngineMediaSession(); media.capture.tab = true
        check(busy(), "default browser busy: tab capture")
        media = EngineMediaSession()
        check(!busy(), "default browser busy: finished session is quiet")
        let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let day: TimeInterval = 86_400
        func at(_ days: Double, launched ago: TimeInterval = 120, onboarded: Date? = t0, isDefault: Bool = false, canAsk: Bool = true,
                busy: Bool = false, fullScreen: Bool = false) -> R.Conditions {
            let now = t0.addingTimeInterval(days * day)
            return R.Conditions(now: now, launchedAt: now.addingTimeInterval(-ago), onboardedAt: onboarded, isDefault: isDefault,
                                canAsk: canAsk, busy: busy, fullScreen: fullScreen)
        }
        func state(_ answer: DefaultBrowserState.Answer? = .notNow, reminders: Int = 0, remindedDay: Double? = nil, neverAsk: Bool = false,
                   firstSeenDay: Double? = nil) -> DefaultBrowserState {
            var s = DefaultBrowserState()
            s.answer = answer
            s.reminders = reminders
            s.remindedAt = remindedDay.map { t0.addingTimeInterval($0 * day) }
            s.neverAsk = neverAsk
            s.firstSeenAt = firstSeenDay.map { t0.addingTimeInterval($0 * day) }
            return s
        }
        let cases: [(String, Bool, Bool)] = [
            ("not before 3 days after onboarding (2.9 days)", R.shouldShow(state(), at(2.9)), false),
            ("3 days after onboarding", R.shouldShow(state(), at(3.01)), true),
            ("never in the first minute after launch", R.shouldShow(state(), at(4, launched: 30)), false),
            ("after the first minute", R.shouldShow(state(), at(4, launched: 61)), true),
            ("never while a call or video plays", R.shouldShow(state(), at(4, busy: true)), false),
            ("never in full screen", R.shouldShow(state(), at(4, fullScreen: true)), false),
            ("never in automated runs", R.shouldShow(state(), at(4, canAsk: false)), false),
            ("never once Airc is the default", R.shouldShow(state(), at(4, isDefault: true)), false),
            ("after onboarding's Not now", R.shouldShow(state(.notNow), at(4)), true),
            ("after the macOS dialog was declined", R.shouldShow(state(.declined), at(4)), true),
            ("when the step never ran", R.shouldShow(state(nil), at(4)), true),
            ("never after onboarding's Make Default", R.shouldShow(state(.madeDefault), at(4)), false),
            ("never when it was already the default", R.shouldShow(state(.alreadyDefault), at(4)), false),
            ("the second not before 7 days after the first (6.9)", R.shouldShow(state(reminders: 1, remindedDay: 4), at(10.9)), false),
            ("the second 7 days after the first", R.shouldShow(state(reminders: 1, remindedDay: 4), at(11.01)), true),
            ("never a third time", R.shouldShow(state(reminders: 2, remindedDay: 11), at(100)), false),
            ("never after Don't ask again", R.shouldShow(state(neverAsk: true), at(100)), false),
            ("without onboarding: 3 days after it first looked", R.shouldShow(state(nil, firstSeenDay: 1), at(4.01, onboarded: nil)), true),
            ("without onboarding: not before", R.shouldShow(state(nil, firstSeenDay: 1), at(3.9, onboarded: nil)), false),
        ]
        for (what, got, want) in cases { check(got == want, "default browser reminder rules: \(what) → \(want ? "shows" : "no")") }
    }

    // MARK: Onboarding step

    private func defaultBrowserOnboarding(_ fake: FakeDefaultBrowser) {
        var o: OnboardingController?
        var settings: AppSettings? { self.app?.settings }
        // Not the default: the step is in the flow, after the theme.
        step { [self] done in
            guard let app else { return done() }
            fake.isDefault = false
            settings?.values.defaultBrowser = DefaultBrowserState()
            let ob = OnboardingController(app: app, mode: .rerun, fixture: nil)
            o = ob
            ob.present(focus: false)
            onboarding = ob
            check(ob.model.offersDefaultBrowser && ob.model.dots == 6, "default browser: onboarding has the step and six dots while Airc isn't the default")
            ob.model.onNext?()
            waitUntil({ if case .notFound = ob.model.arc { true } else { false } }, timeout: 3) {
                ob.model.onStartFresh?()
                ob.model.onNext?()
                self.check(ob.model.step == .defaultBrowser, "default browser: the step follows the theme (\(ob.model.step))")
                done()
            }
        }
        wait(0.7)
        captureOnboarding("db-01-onboarding-light")
        run {
            guard let m = o?.model else { return }
            var t = m.theme(of: m.focused)
            t.appearance = .dark
            m.themes[m.focused.sourceID] = t
            m.onThemeChange?()
        }
        wait(0.7)
        captureOnboarding("db-02-onboarding-dark")
        run { [self] in
            guard let m = o?.model else { return }
            m.themes = [:]
            m.onThemeChange?()
            m.onDefaultNotNow?()
            check(m.step == .done && settings?.values.defaultBrowser.answer == .notNow && fake.asked == 0,
                  "default browser: Not now goes on to the card and records it, without asking macOS (\(m.step), \(String(describing: settings?.values.defaultBrowser.answer)))")
            m.onBack?()
            check(m.step == .defaultBrowser, "default browser: Back from the card returns to the step")
            m.onMakeDefault?()
            check(m.askingDefault, "default browser: Make Default waits for the macOS dialog")
        }
        step { [self] done in
            waitUntil({ o?.model.step == .done }, timeout: 3) {
                self.check(o?.model.step == .done && settings?.values.defaultBrowser.answer == .madeDefault && fake.asked == 1 && fake.isDefault,
                           "default browser: Make Default asks once, records it and goes on (\(String(describing: settings?.values.defaultBrowser.answer)))")
                o?.model.onBack?()
                self.check(o?.model.step == .theme, "default browser: once Airc is the default, Back from the card skips the step")
                done()
            }
        }
        // Already the default: no step, five dots, and "already default" noted.
        step { [self] done in
            o?.window.orderOut(nil)
            guard let app else { return done() }
            fake.isDefault = true
            settings?.values.defaultBrowser = DefaultBrowserState()
            let ob = OnboardingController(app: app, mode: .rerun, fixture: nil)
            o = ob
            ob.present(focus: false)
            onboarding = ob
            ob.model.onNext?()
            waitUntil({ if case .notFound = ob.model.arc { true } else { false } }, timeout: 3) {
                ob.model.onStartFresh?()
                ob.model.onNext?()
                self.check(!ob.model.offersDefaultBrowser && ob.model.dots == 5 && ob.model.step == .done
                               && settings?.values.defaultBrowser.answer == .alreadyDefault,
                           "default browser: skipped when Airc is the default (\(ob.model.step), \(ob.model.dots) dots)")
                ob.window.orderOut(nil)
                self.onboarding = nil
                o = nil
                done()
            }
        }
    }

    // MARK: The reminder card

    private func defaultBrowserCard(_ fake: FakeDefaultBrowser) {
        var clock = Date()
        var t0 = Date()
        var saved: (state: DefaultBrowserState, onboarded: Date?, launched: Date)?
        var r: DefaultBrowserReminder? { DefaultBrowserReminder.current }
        var settings: AppSettings? { self.app?.settings }
        var probe = (busy: false, fullScreen: false, visible: true)
        let day: TimeInterval = 86_400
        func card() -> DefaultBrowserCardView? {
            func find(_ v: NSView) -> DefaultBrowserCardView? {
                if let c = v as? DefaultBrowserCardView, c.superview != nil, c.page?.spaceID == self.c.currentSpaceID { return c }
                for s in v.subviews { if let c = find(s) { return c } }
                return nil
            }
            return c.window.contentView.flatMap(find)
        }
        func look(_ days: Double, _ what: String, shows: Bool) {
            step { [self] done in
                clock = t0.addingTimeInterval(days * day)
                r?.evaluate()
                waitUntil({ (card() != nil) == shows }, timeout: 2) {
                    self.check((card() != nil) == shows && r?.isShowing == shows,
                               "default browser card: \(what) → \(shows ? "shows" : "none") (reminders \(settings?.values.defaultBrowser.reminders ?? -1))")
                    done()
                }
            }
        }
        func press(_ what: String, _ action: @escaping (DefaultBrowserReminder) -> Void) {
            step { [self] done in
                r.map(action)
                waitUntil({ card() == nil }, timeout: 2) {
                    self.check(card() == nil && r?.isShowing == false, "default browser card: \(what) takes it away")
                    done()
                }
            }
        }
        run { [self] in
            guard let r, let settings else { return check(false, "default browser card: the reminder is attached to the window") }
            saved = (settings.values.defaultBrowser, settings.values.onboardingCompletedAt, r.launchedAt)
            fake.isDefault = false
            t0 = Date().addingTimeInterval(-30 * day)
            var s = DefaultBrowserState()
            s.answer = .notNow
            settings.values.defaultBrowser = s
            settings.values.onboardingCompletedAt = t0
            r.now = { clock }
            r.launchedAt = t0
            r.probe = { probe }
        }
        look(1, "a day after onboarding's Not now", shows: false)
        look(3.1, "3 days after", shows: true)
        step { [self] done in
            let h = card()?.frame.height ?? 0
            check(h > 100 && settings?.values.defaultBrowser.reminders == 1, "default browser card: under + New Tab, \(Int(h)) pt, counted once")
            done()
        }
        wait(0.3)
        capture("db-03-reminder")
        press("Not now") { $0.notNow() }
        look(5, "2 days after the first", shows: false)
        run { probe.busy = true }
        look(11, "8 days after, while a call plays", shows: false)
        run { probe.busy = false; probe.fullScreen = true }
        look(11, "8 days after, in full screen", shows: false)
        run { probe.fullScreen = false }
        look(11, "8 days after", shows: true)
        press("Make Default") { $0.makeDefault() }
        step { [self] done in
            waitUntil({ fake.isDefault && !self.c.toast.isHidden }, timeout: 2) {
                self.check(fake.isDefault && fake.asked == 2, "default browser card: Make Default asks macOS once (asked \(fake.asked))")
                done()
            }
        }
        run { fake.isDefault = false }
        look(60, "after showing twice", shows: false)
        // Don't ask again.
        run {
            var s = DefaultBrowserState()
            s.answer = .notNow
            settings?.values.defaultBrowser = s
        }
        look(4, "a fresh count", shows: true)
        press("Don't ask again") { $0.neverAgain() }
        look(40, "after Don't ask again", shows: false)
        // Once Airc is the default (changed in System Settings), a showing card goes by itself.
        run {
            var s = DefaultBrowserState()
            s.answer = .notNow
            settings?.values.defaultBrowser = s
        }
        look(4, "again", shows: true)
        step { [self] done in
            fake.isDefault = true
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
            waitUntil({ card() == nil }, timeout: 2) {
                self.check(card() == nil, "default browser card: goes once Airc is the default")
                done()
            }
        }
        run {
            guard let r, let saved else { return }
            r.now = Date.init
            r.probe = nil
            r.launchedAt = saved.launched
            settings?.values.defaultBrowser = saved.state
            settings?.values.onboardingCompletedAt = saved.onboarded
            r.hide()
        }
    }

    // MARK: Settings rows

    /// The General and Links rows observe `DefaultBrowser.shared`; a change made elsewhere shows once Airc is active.
    private func defaultBrowserLiveState(_ fake: FakeDefaultBrowser) {
        var seen: [Bool] = []
        var sink: AnyCancellable?
        step { [self] done in
            fake.isDefault = false
            DefaultBrowser.shared.refresh()
            sink = DefaultBrowser.shared.$isDefault.dropFirst().sink { seen.append($0) }
            fake.isDefault = true
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
            waitUntil({ seen == [true] }, timeout: 1) {
                self.check(seen == [true] && SettingsActions.isDefaultBrowser,
                           "default browser: the Settings rows' state follows a change once Airc is active (\(seen))")
                sink = nil
                _ = sink
                done()
            }
        }
    }
}
#endif

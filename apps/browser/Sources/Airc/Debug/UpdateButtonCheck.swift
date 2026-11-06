// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircDesign
import AircKit
import AppKit

/// Sparkle's ready update, faked: scripted runs never start the real updater, and nothing here installs or relaunches.
final class FakeReadyUpdate: ReadyUpdate {
    let version: String
    private(set) var installs = 0
    init(version: String) { self.version = version }
    func installAndRelaunch() { installs += 1 }
}

/// `--script updatebutton` (both engines): the sidebar's update button (Browser/UpdateButton.swift) on a fake update.
///   - no update, no button (a scripted run never starts Sparkle);
///   - the restart rules: a call or capture, running downloads, pages that would ask "Leave site?";
///   - "ready" shows the pill just above the footer, hit-testable, in a light, a dark and a themed Space;
///   - a real click with nothing at risk calls the install block at once;
///   - with a download running the click asks first; Not Now keeps the update, Restart installs;
///   - with the sidebar hidden, the revealed sidebar shows the button and a click there installs;
///   - `update.ready_shown` once and `update.restart_clicked` per click, with nothing but their names.
/// The question's SwiftUI buttons are pressed through their actions: posted clicks don't reach SwiftUI buttons in a
/// window that isn't key (docs: Mac UI test pitfalls). The pill itself is AppKit and gets real clicks.
/// Writes update-light.png, update-hover.png, update-dark.png, update-themed.png, update-confirm.png and
/// update-sidebar-hidden.png.
extension SnapshotRunner {
    func updateButtonScenario() {
        let center = UpdateCenter.shared
        let fake = FakeReadyUpdate(version: "1.0 (209901010000)")
        var records: [TelemetryRecord] = []
        let telemetryToken = Telemetry.shared.observeRecent { records = $0 }
        let button = { self.c.sidebar.update }
        var spaceID = ""
        var originalTheme: SpaceTheme?
        let nothing: (WindowController, @escaping (UpdateRestartRisks) -> Void) -> Void = { _, done in done(UpdateRestartRisks()) }
        let aDownload: (WindowController, @escaping (UpdateRestartRisks) -> Void) -> Void = { _, done in
            var r = UpdateRestartRisks()
            r.downloads = 1
            done(r)
        }
        /// The pill's centre in window coordinates, and what a click there reaches.
        func pillPoint() -> NSPoint {
            let b = button()
            return b.convert(NSPoint(x: b.pillRect.midX, y: b.pillRect.midY), to: nil)
        }
        func hitsPill() -> Bool {
            guard let frame = c.window.contentView?.superview else { return false }
            return frame.hitTest(frame.convert(pillPoint(), from: nil)) === button()
        }
        /// A real click; once more if the press never arrived (posted clicks miss now and then while the owner works).
        func clickPill(_ then: @escaping () -> Void) {
            let before = button().presses.down
            click(at: pillPoint(), in: c.window) {
                self.waitUntil({ button().presses.down > before }, timeout: 0.5) {
                    guard button().presses.down == before else { return then() }
                    self.note("update: the click on the pill missed (no press), clicking again")
                    self.click(at: pillPoint(), in: self.c.window, then)
                }
            }
        }

        run { [self] in
            spaceID = c.currentSpaceID
            originalTheme = c.store.space(spaceID)?.theme
            check(center.ready == nil && !button().isShowing && button().frame.height == 0,
                  "update: no update, no button (scripted runs never start the updater)")
            updateRestartRules()
            try? c.store.updateSpace(spaceID) { $0.theme.appearance = .light }
            c.reloadAll(animated: false)
            center.setReady(fake)
        }
        wait(0.6)
        run { [self] in
            let b = button(), sidebar = c.sidebar
            sidebar.layoutSubtreeIfNeeded()
            let pill = sidebar.convert(b.pillRect, from: b)
            let footerTop = sidebar.footer.frame.minY
            check(b.isShowing && pill.height == UpdateButtonView.pillHeight
                  && abs(pill.maxY + UpdateButtonView.bottomInset - footerTop) < 0.5 && pill.minY >= sidebar.pager.frame.maxY,
                  "update: ready shows the button just above the footer (pill \(NSStringFromRect(pill)), footer at \(footerTop))")
            check(UpdateButtonView.titles.contains(b.title.stringValue) && b.title.frame.maxX <= b.pillRect.maxX,
                  "update: it reads “\(b.title.stringValue)” inside the pill (\(Int(sidebar.bounds.width)) pt sidebar)")
            check(hitsPill(), "update: a click on the pill reaches it")
        }
        capture("update-light")
        run { button().setHoveredForSnapshot(true) }
        wait(0.1)
        run { [self] in check(button().title.stringValue == UpdateButtonView.hoverTitle, "update: under the pointer it reads “Restart to Update”") }
        capture("update-hover")
        run { button().setHoveredForSnapshot(false) }
        run { [self] in
            try? c.store.updateSpace(spaceID) { $0.theme.appearance = .dark }
            c.reloadAll(animated: false)
        }
        wait(0.4)
        capture("update-dark")
        run { [self] in
            try? c.store.updateSpace(spaceID) { $0.theme = DesignTheme.preset("ember")!.model }
            c.reloadAll(animated: false)
        }
        wait(0.4)
        capture("update-themed")

        // A click with nothing at risk: the install block, at once.
        run { center.riskProbe = nothing }
        step { [self] done in
            clickPill {
                self.waitUntil({ fake.installs == 1 }) {
                    self.check(fake.installs == 1 && center.confirm == nil,
                               "update: a click with nothing at risk calls the install block (\(fake.installs), presses \(button().presses))")
                    done()
                }
            }
        }

        // A download running: the question first.
        run { center.riskProbe = aDownload }
        step { [self] done in
            clickPill {
                self.waitUntil({ center.confirm != nil }) {
                    self.check(center.confirm != nil && fake.installs == 1,
                               "update: with a download running the click asks first, no restart yet (presses \(button().presses), hits \(hitsPill()))")
                    self.check(center.confirm?.model.risks.lines.first == "A download is still running. Restarting cancels it.",
                               "update: the question says the download would be cancelled")
                    done()
                }
            }
        }
        wait(0.4)
        run { [self] in
            if let v = center.confirm {
                let pill = c.root.convert(button().pillRect, from: button())
                check(v.frame.maxY <= pill.minY && v.frame.minX >= c.sidebar.frame.minX && v.frame.maxX <= c.sidebar.frame.maxX,
                      "update: the question sits just above the button, inside the sidebar (\(NSStringFromRect(v.frame)))")
            }
        }
        capture("update-confirm")
        run { center.confirm?.model.onAnswer?(false) }
        wait(0.3)
        run { [self] in
            check(center.confirm == nil && fake.installs == 1 && center.ready === fake && button().isShowing,
                  "update: Not Now keeps the update ready and the button up")
        }
        step { [self] done in clickPill { self.waitUntil({ center.confirm != nil }, then: done) } }
        run { center.confirm?.model.onAnswer?(true) }
        wait(0.2)
        run { [self] in check(fake.installs == 2 && center.confirm == nil, "update: Restart calls the install block (\(fake.installs))") }

        // The real probe here: no download, no call, no page that would ask.
        step { [self] done in
            c.updateRestartRisks { r in
                self.check(r.isEmpty, "update: the real probe finds nothing at risk in this run (\(r.logText))")
                done()
            }
        }

        // The sidebar hidden: the revealed sidebar has the button.
        run { [self] in
            center.riskProbe = nothing
            if let t = originalTheme { try? c.store.updateSpace(spaceID) { $0.theme = t } }
            c.reloadAll(animated: false)
            c.toggleSidebar()
        }
        wait(0.5)
        run { [self] in
            check(c.sidebarHidden, "update: the sidebar is hidden")
            c.revealController?.reveal()
        }
        wait(0.6)
        run { [self] in
            check(c.revealController?.isRevealed == true && button().isShowing && button().window === c.window,
                  "update: with the sidebar hidden, the revealed sidebar shows the button")
            check(hitsPill(), "update: a click on the revealed sidebar's pill reaches it")
        }
        captureRevealed("update-sidebar-hidden")
        step { [self] done in
            clickPill {
                self.waitUntil({ fake.installs == 3 }) {
                    self.check(fake.installs == 3, "update: a click in the revealed sidebar calls the install block (\(fake.installs))")
                    done()
                }
            }
        }
        run { [self] in c.revealController?.hide() }
        wait(0.5)
        run { [self] in if c.sidebarHidden { c.toggleSidebar() } }
        wait(0.5)

        run { [self] in
            center.setReady(nil)
            center.riskProbe = nil
        }
        wait(0.5)
        run { [self] in
            check(!button().isShowing && button().frame.height == 0 && !hitsPill(), "update: no update any more, no button")
            if AppTelemetry.shared.resolution.state == .recordOnly {
                let features = records.filter { $0.event == "feature.used" }.compactMap { $0.properties["feature"]?.description }
                let shown = features.filter { $0 == "update.ready_shown" }.count, clicked = features.filter { $0 == "update.restart_clicked" }.count
                check(shown == 1 && clicked == 4, "update: update.ready_shown once, update.restart_clicked per click (\(shown), \(clicked))")
                let props = records.filter { $0.properties["feature"]?.description.hasPrefix("update.") == true }.map { Set($0.properties.keys) }
                check(props.allSatisfy { !$0.contains("variant") && !$0.contains("version") }, "update: the events carry only their names")
            } else {
                skip("update: telemetry records nothing in this build (\(AppTelemetry.shared.resolution.state))")
            }
            Telemetry.shared.removeObserver(telemetryToken)
        }
    }

    /// What would be lost by restarting now, without a window.
    private func updateRestartRules() {
        var r = UpdateRestartRisks()
        check(r.isEmpty && r.lines.isEmpty, "update rules: nothing at risk asks nothing")
        r.downloads = 2
        check(!r.isEmpty && r.lines == ["2 downloads are still running. Restarting cancels them."], "update rules: two downloads")
        r = UpdateRestartRisks(call: true, downloads: 0, leaveSite: 1)
        check(r.lines == ["Your call ends.", "A page may have changes that aren’t saved."], "update rules: a call, then a page that would ask")
        var activity = SiteActivity()
        var media = EngineMediaSession()
        check(!UpdateRestartRisks.isCall(activity: activity, media: media), "update rules: an idle page is no call")
        media.active = true
        check(!UpdateRestartRisks.isCall(activity: activity, media: media), "update rules: a playing video is no call")
        activity.microphone = true
        check(UpdateRestartRisks.isCall(activity: activity, media: media), "update rules: a page using the microphone is a call")
        activity = SiteActivity()
        media.capture.screen = true
        check(UpdateRestartRisks.isCall(activity: activity, media: media), "update rules: a screen capture is a call")
    }

    /// `captureNow`, with the revealed sidebar drawn again over the page (which `captureNow` draws over it).
    private func captureRevealed(_ name: String) {
        step { [self] done in
            captureNow(name) { [self] in
                defer { done() }
                guard let floating = c.sidebar.superview, floating !== c.root, let image = render(floating) else { return }
                let url = dir.appendingPathComponent(name + ".png")
                guard let window = NSImage(contentsOf: url) else { return }
                let size = c.root.bounds.size
                guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
                rep.size = size
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                window.draw(in: NSRect(origin: .zero, size: size))
                let f = c.root.convert(floating.bounds, from: floating)
                image.draw(in: NSRect(x: f.minX, y: size.height - f.maxY, width: f.width, height: f.height))
                NSGraphicsContext.restoreGraphicsState()
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
        }
    }
}
#endif

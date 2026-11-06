// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircDesign
import AircKit

/// `--script extension` (Chromium; needs the network, so not in the default snapshot run): installs uBlock Origin Lite
/// from the Chrome Web Store into this run's throwaway data folder, through the app's own install review, then checks
/// it is absent in a second profile, pins it to the URL field, opens ⌘E's list and the action's popup anchored on its
/// button. Screenshots: ext-01-install-review, ext-02-url-field, ext-03-list, ext-04-popup. Only this extension is
/// ever accepted.
extension SnapshotRunner {
    static let testExtensionID = "ddkjiahejlhfcafbddmgiahcphecmpfh"

    func extensionScenario() {
        #if canImport(AircCore)
        let id = Self.testExtensionID
        guard let chromium = c.app?.engine as? ChromiumEngine else {
            run { [self] in note("extension: needs the Chromium engine") }
            return
        }
        run { [self] in
            guard let t = try? c.store.openTab(url: "https://chromewebstore.google.com/detail/" + id, inSpace: c.currentSpaceID,
                                               title: "Chrome Web Store") else { return }
            c.reloadAll(animated: false)
            c.show(t.id, focus: true)
        }
        waitForPage()
        wait(3)
        // The consent page first ("Reject all"), then "Add to Chrome": real mouse input through DevTools.
        step { [self] done in
            func press(attempt: Int) {
                guard attempt < 4, let page = c.shownTabID.flatMap({ c.engineTab(for: $0) }) else { return done() }
                let finder = "(()=>{const b=[...document.querySelectorAll('button')].find(b=>b.innerText.includes('Reject all')||b.innerText.includes('Add to Chrome'));if(!b)return {text:''};b.scrollIntoView({block:'center'});const r=b.getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2,text:b.innerText};})()"
                chromium.devToolsCall("Runtime.evaluate", params: ["expression": finder, "returnByValue": true], in: page) { reply, error in
                    let value = ((reply?["result"] as? [String: Any])?["value"] as? [String: Any]) ?? [:]
                    let text = value["text"] as? String ?? ""
                    self.note("extension: store button \"\(text)\"" + (error.map { " (\($0))" } ?? ""))
                    guard let x = value["x"] as? Double, let y = value["y"] as? Double else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { press(attempt: attempt + 1) }
                        return
                    }
                    let down: [String: Any] = ["type": "mousePressed", "button": "left", "clickCount": 1, "x": x, "y": y]
                    var up = down
                    up["type"] = "mouseReleased"
                    chromium.devToolsCall("Input.dispatchMouseEvent", params: down, in: page) { _, _ in
                        chromium.devToolsCall("Input.dispatchMouseEvent", params: up, in: page) { _, _ in
                            if text.contains("Reject all") {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { press(attempt: attempt + 1) }
                            } else {
                                done()
                            }
                        }
                    }
                }
            }
            press(attempt: 0)
        }
        // The app's install review: captured, then answered (yes only for the test extension).
        step { [self] done in
            waitUntil({ self.c.pendingExtensionReview != nil }, timeout: 20) {
                guard let review = self.c.pendingExtensionReview else {
                    self.check(false, "extension: the install review card opens")
                    return done()
                }
                let m = review.model
                self.check(true, "extension: the install review card opens: \(m.title) (\(m.profileName), \(m.permissions.count) permissions, icon \(m.icon != nil))")
                // Once it has dropped in; then a real click on Add Extension (or Cancel for anything but the test one).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    self.captureWindow(self.c.window, name: "ext-01-install-review", rounded: 10) {
                        let isTest = m.name.contains("uBlock Origin Lite")
                        self.clickAnchor(isTest ? "extension.add" : "extension.cancel", in: review.hostingView, done)
                    }
                }
            }
        }
        step { [self] done in
            waitUntil({ self.installedIDs(chromium).contains(id) }, timeout: 40) {
                self.check(self.installedIDs(chromium).contains(id), "extension: uBlock Origin Lite is installed in \(self.c.store.profile(ofSpace: self.c.currentSpaceID).name)")
                done()
            }
        }
        // Per profile: a second profile doesn't have it.
        var other: String?
        run { [self] in other = try? c.profiles.createProfile(name: "Other", emoji: "", color: nil).id }
        wait(3)
        run { [self] in
            let ids = other.flatMap { c.profiles.engineProfile(for: $0) }.map { chromium.installedExtensions(for: $0).compactMap { $0["id"] as? String } }
            check(ids.map { !$0.contains(id) } ?? false, "extension: absent in a second profile (\(ids.map { "\($0.count) installed" } ?? "not loaded"))")
        }
        // Pinned, it draws in the URL field on hover with its badge, on an ordinary page (it can't run on the Web Store).
        run { [self] in
            c.setExtension(id, pinned: true)
            c.navigate(to: URL(string: "https://arstechnica.com/")!, newTab: true)
        }
        waitForPage()
        wait(2)
        run { [self] in
            c.sidebar.setHovered(true)
            c.refreshExtensionButtons()
            let field = c.pageView(for: c.currentSpaceID)?.urlField
            field?.layoutSubtreeIfNeeded()
            let state = c.extensionActions().first { $0.id == id }
            check(field?.extensionAnchor(for: id).width == AircMetrics.Sidebar.urlFieldButton,
                  "extension: pinned, its button shows in the URL field (badge \"\(state?.badge ?? "-")\", active \(state?.isActive ?? false))")
        }
        wait(0.5)
        capture("ext-02-url-field")
        // ⌘E: the list with pin toggles.
        key("e", 14, .command)
        wait(0.6)
        step { [self] done in
            guard let w = c.extensionsPopover?.contentViewController?.view.window else {
                check(false, "extension: ⌘E opens the list")
                return done()
            }
            check(true, "extension: ⌘E opens the list")
            captureWindow(w, name: "ext-03-list", rounded: 0) {
                self.c.extensionsPopover?.close()
                done()
            }
        }
        // The popup, anchored on the pinned button.
        step { [self] done in
            guard let field = c.pageView(for: c.currentSpaceID)?.urlField,
                  let page = c.shownTabID.flatMap({ c.engineTab(for: $0) }) else { return done() }
            let anchor = field.extensionAnchor(for: id)
            chromium.presentExtensionActionPicture(id, for: page, anchorRect: anchor, in: field) { image in
                self.check(image != nil, "extension: the popup opens anchored on its URL-field button")
                if let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                    try? rep.representation(using: .png, properties: [:])?.write(to: self.dir.appendingPathComponent("ext-04-popup.png"))
                }
                if let w = NSApp.windows.first(where: { $0.isVisible && $0 is NSPanel && $0 !== self.c.window }) {
                    self.note("extension: popup panel at \(NSStringFromRect(w.frame)), window \(NSStringFromRect(self.c.window.frame))")
                }
                self.c.closeExtensionPopup()
                done()
            }
        }
        run { [self] in c.sidebar.setHovered(false) }
        #else
        run { [self] in note("extension: needs the Chromium engine") }
        #endif
    }

    #if canImport(AircCore)
    private func installedIDs(_ chromium: ChromiumEngine) -> [String] {
        guard let p = c.profiles.engineProfile(for: c.store.profile(ofSpace: c.currentSpaceID).id) else { return [] }
        return chromium.installedExtensions(for: p).compactMap { $0["id"] as? String }
    }
    #endif
}
#endif

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircDesign
import AircKit

/// `--script smoke`: the release-candidate journeys the other scenarios don't already walk, with real keys and clicks
/// (onboarding, Create a Space with a new profile, find and full screen are in `onboarding`, `events` and `fullscreen`;
/// the extension popup in `extension`):
///   - the Command Bar: ⌘T, a typed address, Return, and the page loads in a new tab;
///   - Google's sign-in page in a new profile, through the email step with a synthetic address (never a password): the
///     step that aborted the app on its passkey request (owner P0, 2026-11-05). Needs the network;
///   - picture-in-picture on a tab switch: a local, audible video (recorded in the page, no file or network) goes into
///     PiP when its tab is left and comes back with it (SB-55).
extension SnapshotRunner {
    func smokeScenario() {
        var server: LocalPageServer?
        var base = ""
        step { [self] done in
            server = LocalPageServer(pages: ["/start": "<title>smoke start</title><p>Start</p>",
                                             "/target": "<title>smoke target</title><p>Reached from the Command Bar</p>"])
            guard let server else { check(false, "smoke: the loopback server starts"); return done() }
            server.start { port in
                guard let port else { self.check(false, "smoke: the loopback server starts"); return done() }
                base = "http://127.0.0.1:\(port)"
                if let t = try? self.c.store.openTab(url: base + "/start", inSpace: self.c.currentSpaceID, title: "Start") {
                    self.c.reloadAll(animated: false)
                    self.c.show(t.id, focus: false)
                }
                done()
            }
        }
        waitForPage()
        // A person clicks into the window before typing (a window that never had a mouse-down drops posted keys).
        step { [self] done in clickIntoPage(done) }

        // The Command Bar.
        var before: Set<String> = []
        run { [self] in before = Set(c.store.state.tabs.keys) }
        key("t", 17, .command)
        step { [self] done in waitUntil({ self.c.commandBar != nil }, timeout: 3) { done() } }
        run { [self] in typeText(base + "/target") }
        wait(0.3)
        key("\r", 36)
        step { [self] done in
            waitUntil({ self.c.shownTabID.flatMap { self.c.engineTab(for: $0) }?.title == "smoke target" }, timeout: 8) {
                let shown = self.c.shownTabID
                self.check(shown.map { !before.contains($0) } == true && self.c.engineTab(for: shown ?? "")?.title == "smoke target"
                           && self.c.commandBar == nil,
                           "smoke: ⌘T, a typed address and Return open it in a new tab (title \(self.c.engineTab(for: shown ?? "")?.title ?? "-"))")
                server?.stop()
                done()
            }
        }

        googleSignIn()
        pictureInPictureOnTabSwitch()
    }

    private func googleSignIn() {
        var tabID = ""
        let page = { self.c.engineTab(for: tabID) }
        // The new profile's engine profile loads asynchronously on Chromium (the UI's New Profile adopts a spare that
        // is loaded already); its tab opens once it has.
        step { [self] done in
            do {
                let profile = try c.profiles.createProfile(name: "Sign-in smoke", emoji: "🔑", color: RGBA(hex: "7EB6D5"))
                let space = try c.store.createSpace(name: "Sign-in smoke", icon: .emoji("🔑"), theme: DesignTheme.preset("sky")!.model,
                                                    profileID: profile.id, after: c.currentSpaceID)
                c.switchToSpace(space.id, animated: false)
                c.profiles.whenLoaded(profile.id, { _ in
                    guard let t = try? self.c.store.openTab(url: "https://accounts.google.com/", inSpace: space.id, title: "Sign in") else { return done() }
                    tabID = t.id
                    self.c.reloadAll(animated: false)
                    self.c.show(t.id, focus: false)
                    done()
                }, failed: {
                    self.check(false, "smoke: the new profile loads")
                    done()
                })
            } catch {
                check(false, "smoke: a new profile and Space for sign-in (\(error))")
                done()
            }
        }
        // Google's page builds its form with script after the load ends.
        step { [self] done in
            waitUntil({ page()?.isLoading == false }, timeout: 20) { DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: done) }
        }
        var field: NSPoint?
        step { [self] done in
            let locate = "(function(){var e=document.querySelector('#identifierId,input[name=identifier],input[type=email]');if(!e)return null;var r=e.getBoundingClientRect();"
                + "return [r.left+r.width/2,r.top+r.height/2]})()"
            guard let p = page() else { check(false, "smoke: the sign-in tab has a page"); return done() }
            // The form appears from script after the load; poll for it (10 s).
            let deadline = Date().addingTimeInterval(10)
            func poll() {
                p.evaluate(locate) { value in
                    if let xy = (value as? [Any])?.compactMap({ ($0 as? NSNumber)?.doubleValue }), xy.count == 2, let v = page()?.view {
                        field = v.convert(NSPoint(x: xy[0], y: v.isFlipped ? xy[1] : Double(v.bounds.height) - xy[1]), to: nil)
                    }
                    if field == nil, Date() < deadline { return DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: poll) }
                    p.evaluate("document.visibilityState+' | '+(document.body?document.body.innerText:'').replace(/\\s+/g,' ').slice(0,160)") { seen in
                        self.check(field != nil, "smoke: Google's sign-in page shows its email field in the new profile (\(page()?.url?.host ?? "-"), "
                                   + "“\(page()?.title ?? "-")”" + (field == nil ? ", page: \(seen ?? "-")" : "") + ")")
                        done()
                    }
                }
            }
            poll()
        }
        // A click on the field, then the page takes the keyboard and the field the focus: in a window that isn't key
        // (scripted runs never activate the app) a page takes its first click as activation only, as in Chrome.
        step { [self] done in
            guard let field, let p = page() else { return done() }
            click(at: field, in: c.window) {
                p.focus()
                p.evaluate("(document.querySelector('#identifierId,input[name=identifier],input[type=email]')||{focus(){}}).focus();1") { _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: done)
                }
            }
        }
        // A synthetic address that belongs to no one; the run stops at the next step and never types a password.
        let email = "airc.smoke.synthetic.20261105@example.com"
        run { [self] in if field != nil { typeText(email) } }
        step { [self] done in
            guard field != nil, let p = page() else { return done() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                p.evaluate("(document.querySelector('#identifierId,input[name=identifier],input[type=email]')||{}).value") { value in
                    self.check((value as? String) == email, "smoke: the typed email reached Google's field (“\(value ?? "-")”)")
                    done()
                }
            }
        }
        run { [self] in if field != nil { postKey("\r", keyCode: 36) } }
        // Enter on the email step is where the passkey request came (Google asks for a passkey there); the app must
        // still be running, with the page on Google's next step or its "couldn't find" message.
        wait(8)
        run { [self] in
            check(page() != nil, "smoke: after Enter on the email step the app is still running (\(page()?.url?.host ?? "-") “\(page()?.title ?? "-")”)")
        }
        // Onboarding learns who signed in by reading Google's ListAccounts page (SignInWindow), where Google's CSP
        // refuses the eval Chromium's evaluate used: signed out, it still reads the (empty) account list.
        run { page()?.load(SignInWindowController.listAccountsURL) }
        step { [self] done in
            waitUntil({ page()?.url?.path == "/ListAccounts" && page()?.isLoading == false }, timeout: 15) {
                page()?.evaluate("document.body ? document.body.innerText : ''") { value in
                    // Signed out, Google answers 400 with an error page; reading any text is the point.
                    let text = (value as? String ?? "").replacingOccurrences(of: "\n", with: " ")
                    let what = "smoke: the onboarding's ListAccounts read gets Google's page text (“\(text.prefix(40))”, "
                        + "\(GoogleAccounts.emails(fromListAccounts: text).count) accounts)"
                    if self.app?.engine.name.hasPrefix("WebKit") == true, text.isEmpty { self.skip(what + ": WebKit, the dev engine") }
                    else { self.check(!text.isEmpty, what) }
                    done()
                }
            }
        }
    }

    private static let videoPage = """
        <!doctype html><title>video</title><style>body{margin:0;background:#193349}video{width:480px}</style>
        <video id=video playsinline loop></video><canvas id=canvas width=640 height=360 style=display:none></canvas>
        <script>
        window.state='idle';
        async function start(){
          state='recording';
          const ctx=canvas.getContext('2d');let n=0;
          const timer=setInterval(()=>{ctx.fillStyle='#194b65';ctx.fillRect(0,0,640,360);ctx.fillStyle='white';ctx.font='40px sans-serif';ctx.fillText('Airc video '+n++,50,170)},50);
          const ac=new AudioContext();await ac.resume();
          const osc=ac.createOscillator(),gain=ac.createGain(),dest=ac.createMediaStreamDestination();
          gain.gain.value=0.02;osc.connect(gain).connect(dest);osc.start();
          const source=canvas.captureStream(20);source.addTrack(dest.stream.getAudioTracks()[0]);
          const type=['video/webm;codecs=vp8,opus','video/mp4'].find(t=>MediaRecorder.isTypeSupported(t));
          const rec=new MediaRecorder(source,{mimeType:type}),chunks=[];
          rec.ondataavailable=e=>chunks.push(e.data);rec.start();
          await new Promise(r=>setTimeout(r,1800));await new Promise(r=>{rec.onstop=r;rec.stop()});
          source.getTracks().forEach(t=>t.stop());osc.stop();await ac.close();clearInterval(timer);
          video.src=URL.createObjectURL(new Blob(chunks,{type}));await video.play();state='playing';
        }
        document.addEventListener('click',()=>{if(state==='idle')start().catch(e=>state='error '+e.name)});
        function pip(){return !!document.pictureInPictureElement||video.webkitPresentationMode==='picture-in-picture'}
        </script>
        """

    private func pictureInPictureOnTabSwitch() {
        #if canImport(AircCore)
        guard let engine = app?.engine as? ChromiumEngine else {
            return run { [self] in skip("smoke: picture-in-picture on a tab switch: Chromium only (WebKitEngine has no automatic PiP)") }
        }
        #else
        return run { [self] in skip("smoke: picture-in-picture on a tab switch: Chromium only (WebKitEngine has no automatic PiP)") }
        #endif
        #if canImport(AircCore)
        var videoTab = "", otherTab = ""
        let page = { self.c.engineTab(for: videoTab) }
        func read(_ script: String, _ then: @escaping (Any?) -> Void) {
            guard let p = page() else { return then(nil) }
            p.evaluate(script, completion: then)
        }
        func poll(_ script: String, until ok: @escaping (Any?) -> Bool, timeout: Double, _ then: @escaping (Any?) -> Void) {
            let deadline = Date().addingTimeInterval(timeout)
            func again() {
                read(script) { v in
                    if ok(v) || Date() > deadline { then(v) } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: again) }
                }
            }
            again()
        }
        run { [self] in
            // A file page: Chromium's automatic PiP only takes HTTPS or file pages.
            let file = dir.appendingPathComponent("smoke-video.html")
            try? Self.videoPage.write(to: file, atomically: true, encoding: .utf8)
            guard let t = try? c.store.openTab(url: file.absoluteString, inSpace: c.currentSpaceID, title: "video"),
                  let o = try? c.store.openTab(url: "about:blank", inSpace: c.currentSpaceID, activate: false, title: "Other")
            else { return }
            videoTab = t.id
            otherTab = o.id
            c.reloadAll(animated: false)
            c.show(t.id, focus: false)
        }
        waitForPage()
        // The page needs a user activation to play sound: a DevTools user gesture starts it (a click in a window that
        // isn't key only activates the window).
        step { [self] done in
            guard let p = page() else { return done() }
            engine.devToolsCall("Runtime.evaluate", params: ["expression": "start(),1", "userGesture": true], in: p) { _, _ in
                poll("state", until: { ($0 as? String) != "recording" && ($0 as? String) != "idle" }, timeout: 8) { v in
                    self.check((v as? String) == "playing", "smoke: the local video plays (\(v ?? "-"))")
                    done()
                }
            }
        }
        // Chromium's eligibility needs the tab to have been audible recently and its media session settled (the engine's
        // own PiP check waits the same 2 s): leaving the tab the moment play() resolves is too early.
        wait(2)
        run { [self] in
            let profile = c.store.tab(videoTab).flatMap { c.profiles.engineProfile(for: $0.profileID) }
            note("smoke: automatic PiP for this profile \(profile.map { engine.autoPictureInPictureEnabled($0) } ?? false), window key \(c.window.isKeyWindow)")
            c.show(otherTab, focus: false)
        }
        step { [self] done in
            poll("pip()", until: { ($0 as? Bool) == true }, timeout: 5) { v in
                let what = "smoke: leaving the video's tab puts it in picture-in-picture (\(v ?? "-"))"
                // Automatic PiP is for a tab switch in the active window (the engine's host-window-active input), as in
                // Chrome; scripted runs never activate the app unless AIRC_REAL_CLICKS=1.
                if (v as? Bool) != true, !self.c.window.isKeyWindow { self.skip(what + ": the window isn't key") }
                else { self.check((v as? Bool) == true, what) }
                done()
            }
        }
        run { [self] in c.show(videoTab, focus: false) }
        step { [self] done in
            poll("pip()", until: { ($0 as? Bool) == false }, timeout: 5) { v in
                self.check((v as? Bool) == false, "smoke: coming back to the tab ends picture-in-picture (\(v ?? "-"))")
                done()
            }
        }
        #endif
    }
}
#endif

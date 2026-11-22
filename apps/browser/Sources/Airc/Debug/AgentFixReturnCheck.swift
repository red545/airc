// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// agentfix, part of `--script agentpane2` (`AIRC_AGENTPANE2_ONLY=agentfix`), review21's Return-in-a-page finding: right
/// after a landing on the approval card, the person clicks into a page field and types, then presses Return (real
/// clicks and keys, FG run). The keys stay in the page: no approval. Then the person chooses the card (✦) and Return
/// allows once, as agentux3 designed.
extension AgentPane2Check {
    // MARK: Return in a page field never approves

    func caseReturnInPage(_ done: @escaping () -> Void) {
        guard k.real else {
            note("NOTE agentpane2 \(engine): agentfix Return-in-page needs real clicks and keys (FG run); skipped in this posted run")
            return done()
        }
        traceAttention()
        AgentAttention.resetForTesting()
        k.front { [self] _ in
            AgentUI.close(c)
            c.navigate(to: URL(string: "\(k.base)/form.html")!, newTab: true)
            wait({ self.c.shownTabID.flatMap(self.c.engineTab)?.isLoading == false }, 10) { [self] in
                guard let tabID = c.shownTabID, let page = c.engineTab(for: tabID) else { check(false, "agentfix return: the form page"); return done() }
                k.start("returnpage", [.tool("navigate", ["url": "\(k.base)/shop.html"]), .tool("left_click", ["coordinate": [100, 180]]), .text("Paid.")],
                        task: "Pay at the fixture shop")
                wait({ self.run.approval != nil }, 20) { [self] in
                    guard run.approval != nil else { check(false, "agentfix return: the agent asks before paying"); return stopRun(done) }
                    after(0.6) { [self] in
                        away(.hidden, home: c.currentSpaceID, other: c.currentSpaceID) { [self] _ in
                            enter("notification") { [self] how in
                                landedOnApproval("agentfix return [notification] [\(how)]", home: nil) { [self] in
                                    let landed = Date()
                                    typeIntoPage(page, tabID: tabID, landed: landed) { [self] in
                                        deliberate(done)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// A real click into the page's field right after the landing, a key and Return once the old 0.8 s re-grab has
    /// passed, and Return again after the old last one (1.5 s).
    private func typeIntoPage(_ page: EngineTab, tabID: String, landed: Date, _ then: @escaping () -> Void) {
        page.evaluate("(function(){var f=document.getElementById('f');f.value='';var r=f.getBoundingClientRect();return [r.left+r.width/2,r.top+r.height/2]})()") { [self] v in
            let xy = (v as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
            guard xy.count == 2, c.shownTabID == tabID else { check(false, "agentfix return: the page field is on screen (\(String(describing: v)))"); return stopRun(then) }
            let view = page.view
            let p = view.convert(NSPoint(x: xy[0], y: view.isFlipped ? xy[1] : Double(view.bounds.height) - xy[1]), to: nil)
            // `--click` without `--mods` (the driver rejects an empty one).
            let s = c.window.convertPoint(toScreen: p), top = NSScreen.screens.first?.frame.maxY ?? 0
            UIDriverClient.run(["--click", String(Double(s.x.rounded())), String(Double((top - s.y).rounded()))]) { [self] ok, out in
                DispatchQueue.main.async { [self] in
                    guard ok else { note("FAIL-ENV agentpane2 \(engine): agentfix return: the driver refused the page click (\(out))"); return stopRun(then) }
                    let clickAt = Date().timeIntervalSince(landed)
                    func at(_ t: Double, _ body: @escaping () -> Void) { after(max(0, t - Date().timeIntervalSince(landed)), body) }
                    at(0.9) { [self] in
                        let firstKeysAt = Date().timeIntervalSince(landed)
                        UIDriverClient.press(["q", "return"], pid: getpid()) { [self] ok1, _ in
                            DispatchQueue.main.async { [self] in
                                let afterFirst = run.approval != nil
                                at(1.8) { [self] in
                                    let secondAt = Date().timeIntervalSince(landed)
                                    UIDriverClient.press(["return"], pid: getpid()) { [self] ok2, _ in
                                        DispatchQueue.main.async { [self] in
                                            after(0.6) { [self] in
                                                page.evaluate("[document.getElementById('f').value, (document.activeElement||{}).id||'']") { [self] v in
                                                    let r = (v as? [Any])?.compactMap { $0 as? String } ?? []
                                                    let timing = String(format: "click +%.2f s, q+Return +%.2f s, Return +%.2f s after the landing", clickAt, firstKeysAt, secondAt)
                                                    check(ok1 && ok2, "agentfix return: the driver pressed the keys (real keys, PID-targeted)")
                                                    check(afterFirst, "agentfix return: q then Return typed into the page field within 1.5 s of the landing don't approve (\(timing))")
                                                    check(run.approval != nil && run.state.isActive, "agentfix return: … nor Return after the landing's last focus pass: the approval still waits")
                                                    check(r.first == "q" && r.last == "f", "agentfix return: … the keys went to the page field (value “\(r.first ?? "?")”, focus “\(r.last ?? "?")”)")
                                                    then()
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// The person chooses the card (✦ lands on it again) and Return allows once.
    private func deliberate(_ done: @escaping () -> Void) {
        guard run.approval != nil else { return stopRun(done) }
        enter("agentButton") { [self] how in
            landedOnApproval("agentfix return [✦, chosen by the person] [\(how)]", home: nil) { [self] in
                answerKey("return") { [self] keyHow in
                    wait({ self.run.approval == nil }, 5) { [self] in
                        check(run.approval == nil, "agentfix return: Return on the card the person chose allows once [\(keyHow)]")
                        k.untilIdle(10) { done() }
                    }
                }
            }
        }
    }
}
#endif

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import WebKit

/// agentmainfix, part of `--script agentmain` (`AIRC_AGENTMAIN_ONLY=parked`): a page parked while the person looks at
/// another tab keeps drawing at its full rate (its own animation frames counted 1 s apart, ≥ 50/s), in the main view,
/// parked, 2 s later and back; the pane's card moves meanwhile; WebKit answers a fresh snapshot of the parked page at
/// once. agentmainview's "~2 frames/s" was the flicker fixture's counter running off the 632 px main view.
extension AgentMainCheck {
    func caseParked(_ done: @escaping () -> Void) {
        k.extraPages["/am-flicker.html"] = AgentPaneFlickerProbe.page
        k.start("parked", [.tool("navigate", ["url": "\(base)/am-flicker.html"]), .toolThenHold("wait", ["duration": 60], hold: 1.5),
                           .text("Never reached.")], task: "Look at the flicker page")
        wait({ self.k.events.contains("tool wait") && self.entry != nil }, 20) { [self] in
            guard let e = entry, let page = e.page, let w = runWindow, let home = homeTabID else {
                check(false, "parked: a running task on the fixture page"); return done()
            }
            func rate(_ label: String, parked: Bool, _ next: @escaping () -> Void) {
                if let web = (page as? WebKitTab)?.webView {
                    let t0 = CACurrentMediaTime()
                    let config = WKSnapshotConfiguration()
                    config.afterScreenUpdates = true
                    web.takeSnapshot(with: config) { [self] image, _ in
                        let ms = Int((CACurrentMediaTime() - t0) * 1000)
                        check(image != nil && ms < 250, "parked [\(label)]: WebKit draws a fresh frame of the page at once (\(ms) ms)")
                    }
                }
                read("window.__raf || 0", from: page) { [self] a in
                    let n0 = number(a)
                    after(1.0) { [self] in
                        read("window.__raf || 0", from: page) { [self] b in
                            let n = n0 >= 0 && number(b) >= 0 ? number(b) - n0 : -1
                            check(n >= 50 && w.isParked(page) == parked,
                                  "parked [\(label)]: the page draws at its full rate (\(n) animation frames/s, \(parked ? "parked" : "in the main view"))")
                            next()
                        }
                    }
                }
            }
            page.evaluate("window.__raf=0;(function f(){window.__raf++;requestAnimationFrame(f)})();1") { [self] _ in
                rate("main view", parked: false) { [self] in
                    c.show(home)
                    wait({ w.isParked(page) && AgentPaneLiveView.current?.window != nil }, 4) { [self] in
                        after(0.3) { [self] in
                            rate("parked", parked: true) { [self] in
                                after(1.0) { [self] in
                                    rate("parked 2 s later", parked: true) { [self] in
                                        cardMoves { [self] moving in
                                            check(moving, "parked: the pane's card shows the page moving")
                                            c.show(e.tabID)
                                            wait({ !w.isParked(page) }, 4) { [self] in
                                                after(0.5) { [self] in
                                                    rate("back in the main view", parked: false) { [self] in
                                                        run.stop()
                                                        k.untilIdle(8) { done() }
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
    }
}
#endif

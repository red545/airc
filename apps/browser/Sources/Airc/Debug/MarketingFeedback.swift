// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// The marketing shot of Help › Send Feedback… (docs/user/feedback.md), the marketing scenario's part "feedback"
/// (`scripts/marketing-shots.sh --parts feedback`):
///   - send-feedback: the Studio Space's design page, Send Feedback… over it: a message, two pictures (this window's,
///     and a picture of the sidebar as if pasted), app info ticked, and "What will be sent" listing each part. Nothing
///     is sent.
extension SnapshotRunner {
    func mkFeedbackShots(_ d: MarketingDemo) {
        mkShow(d, "studio", "hig")
        mkSettleShown()
        run { [self] in
            guard let app else { return note("marketing: MISSING send-feedback: no app") }
            FeedbackSheet.show(from: c.window, app: app)
            guard let s = FeedbackSheet.active else { return note("marketing: MISSING send-feedback: no sheet") }
            s.message = "Love the new Split View. One thing: after switching Spaces, the right pane forgets where I'd scrolled to."
            s.includeAppInfo = true
            s.addWindowPicture()
            if let image = render(c.sidebar), let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                s.add([png], source: .pasted)
            }
        }
        step { [self] done in waitUntil({ (FeedbackSheet.active?.attachments.count ?? 0) >= 2 && FeedbackSheet.active?.preparing == 0 }, timeout: 8) { done() } }
        wait(0.6)
        mkWindowShot("send-feedback") { [self] frame in
            guard let s = FeedbackSheet.active?.sheet, let card = mkContentImage(s) else {
                note("marketing: MISSING send-feedback: no sheet")
                return []
            }
            let sf = s.frame, wf = c.window.frame
            return [MarketingStudio.Layer(image: card, frame: NSRect(x: frame.minX + sf.minX - wf.minX, y: frame.minY + sf.minY - wf.minY,
                                                                     width: sf.width, height: sf.height), radius: 16, shadow: .panel)]
        }
        run { FeedbackSheet.active?.close() }
        wait(0.4)
    }
}
#endif

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit

/// Ask on Page (Arc Max, docs/user/ai.md): ⌘F's other mode, or the Command Bar's "Ask This Page…". A question about the
/// page shown is answered by Apple's on-device model from the page's visible text (PageReader, at most
/// `AskPageLimits.readCap` characters; AircKit's AskPageRun plans the passages that fit the model's context window and
/// streams the answer), in a card under the bar with the page's own sentences behind it; a click on one scrolls the
/// page to it and highlights it. Main windows only: a private window's find bar never gets the Ask button.
@MainActor
enum AskPageFeature {
    /// The bar's and the card's width while asking.
    static let width: CGFloat = 400
    /// The search field's own magnifier, put back when Ask goes back to Find.
    static var findGlyph: NSImage?

    final class Session {
        let card: AskAnswerView
        weak var tab: EngineTab?
        /// The profile of the page asked about, taken when the question was asked (so Clear Data and Delete Profile
        /// find the session even once the profile itself is gone).
        var profileID: String?
        var page: PageText?
        var run: AskPageRun?
        /// A read or a question that's been replaced: its late answer is dropped.
        var generation = 0
        init(card: AskAnswerView) { self.card = card }
    }

    /// Each find bar's Ask session (its card).
    static var sessions: [ObjectIdentifier: Session] = [:]

    /// The setting went off: every window's Ask closes back to Find.
    static func closeAll() {
        for c in (NSApp.delegate as? AppDelegate)?.controllers ?? [] {
            guard let bar = c.findBar, bar.isAsking else { continue }
            c.leaveAsk(bar)
        }
    }

    /// The scripted check reads the session of a window's bar.
    static func session(of c: WindowController) -> Session? { c.findBar.flatMap { sessions[ObjectIdentifier($0)] } }

    /// Clear Data and Delete Profile (AIFeatures.forget): every window's Ask session about a page of that profile
    /// closes: its question stops (the model's stream and its check end), a page read still on its way is dropped, the
    /// card with the page's text, the answer and its quotes goes, and the bar goes back to Find with the question
    /// cleared. Sessions of other profiles stay.
    static func forget(profileID: String) {
        guard let app = NSApp.delegate as? AppDelegate else { return }
        for c in app.controllers {
            guard let bar = c.findBar, let s = sessions[ObjectIdentifier(bar)] else { continue }
            let shown = s.tab.flatMap { app.profiles.profileID(for: $0.profile) }
            guard s.profileID == profileID || shown == profileID else { continue }
            c.purgeAsk(bar)
        }
    }
}

extension FindBarView {
    func setAsking(_ on: Bool) {
        isAsking = on
        field.placeholderString = on ? "Ask about this page" : "Find on page"
        // The field's glyph: ✦ while asking, the magnifier for Find.
        if let button = (field.cell as? NSSearchFieldCell)?.searchButtonCell {
            if on, AskPageFeature.findGlyph == nil { AskPageFeature.findGlyph = button.image }
            button.image = on ? NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Ask") : AskPageFeature.findGlyph ?? button.image
        }
        field.needsDisplay = true
        askButton.tint = on ? NSColor.controlAccentColor : askButton.tint
        askButton.toolTip = on ? "Back to Find (⌘F)" : "Ask about this page (⌘↩)"
        needsLayout = true
    }
}

// FindBar.swift and the Command Bar call these from WindowController's own (not actor-isolated) code; the work is on
// the main actor, like AIFeatures and AircKit's AskPageRun.
extension WindowController {
    func prepareAsk(_ bar: FindBarView) { MainActor.assumeIsolated { askPrepare(bar) } }
    func layoutAskCard(_ bar: FindBarView) { MainActor.assumeIsolated { askLayout(bar) } }
    func closeAskCard(_ bar: FindBarView) { MainActor.assumeIsolated { askClose(bar) } }
    func showAsk(question: String? = nil) { MainActor.assumeIsolated { askShow(question) } }
    /// ⌘F while asking: back to Find.
    func findInsteadOfAsking(_ bar: FindBarView) { MainActor.assumeIsolated { leaveAsk(bar) } }
}

@MainActor
extension WindowController {
    /// ⌘F's bar gets its Ask button when Ask on Page is on and can run.
    func askPrepare(_ bar: FindBarView) {
        guard app?.settings.values.askPage == true, AIFeatures.shared.canAsk else { return }
        bar.askButton.isHidden = false
        bar.onToggleAsk = { [weak self, weak bar] in
            guard let self, let bar else { return }
            if bar.isAsking { self.leaveAsk(bar) } else { self.enterAsk(bar) }
        }
        bar.onAsk = { [weak self, weak bar] question in
            guard let self, let bar else { return }
            if !bar.isAsking { self.enterAsk(bar) }
            self.ask(question, in: bar)
        }
    }

    /// The Command Bar's "Ask This Page…" (and ⌘↩ in the find field): the bar in Ask mode, focused.
    func askShow(_ question: String?) {
        guard let id = shownTabID, engineTab(for: id) != nil else { return NSSound.beep() }
        // A bar already up stays as it is (⌘F would take it back to Find).
        if findBar == nil { showFind() }
        guard let bar = findBar else { return }
        if bar.askButton.isHidden {
            // Off, or no model: the bar says why instead of asking.
            enterAsk(bar)
            AskPageFeature.sessions[ObjectIdentifier(bar)]?.card.show(refusal: .unavailable)
            layoutFindBar()
            return
        }
        enterAsk(bar)
        if let question, !question.isEmpty {
            bar.field.stringValue = question
            ask(question, in: bar)
        }
    }

    func enterAsk(_ bar: FindBarView) {
        guard !bar.isAsking else { return }
        if let id = shownTabID, let page = engineTab(for: id) { page.stopFinding() }
        bar.setAsking(true)
        let key = ObjectIdentifier(bar)
        if AskPageFeature.sessions[key] == nil {
            let card = AskAnswerView(palette: currentPalette)
            card.onJump = { [weak self, weak bar] quote in
                guard let self, let bar, let s = AskPageFeature.sessions[ObjectIdentifier(bar)], let tab = s.tab else { return }
                guard !tab.isClosed, self.shownTabID.flatMap({ self.engineTab(for: $0) }) === tab else { return }
                PageReader.jump(tab, to: quote)
            }
            AskPageFeature.sessions[key] = AskPageFeature.Session(card: card)
        }
        layoutFindBar()
        window.makeFirstResponder(bar.field)
        bar.field.currentEditor()?.selectAll(nil)
        AppleIntelligence.prewarmAsk()
    }

    func leaveAsk(_ bar: FindBarView) {
        askClose(bar)
        bar.setAsking(false)
        layoutFindBar()
        window.makeFirstResponder(bar.field)
    }

    /// The session's profile was cleared or deleted: as leaving Ask, with the question typed in the field cleared too,
    /// and the keyboard left where it is (the person is in Settings).
    func purgeAsk(_ bar: FindBarView) {
        askClose(bar)
        bar.field.stringValue = ""
        bar.setAsking(false)
        layoutFindBar()
    }

    /// The card hangs under the bar, as wide as it, as tall as its answer.
    func askLayout(_ bar: FindBarView) {
        guard let s = AskPageFeature.sessions[ObjectIdentifier(bar)] else { return }
        let card = s.card
        guard card.hasContent else {
            if card.superview != nil { card.removeFromSuperview() }
            return
        }
        if card.superview !== root {
            root.addSubview(card, positioned: .below, relativeTo: bar)
            card.present()
        }
        let m = AskAnswerView.margin
        let page = self.card.frame
        let width = bar.frame.width
        let height = min(card.fittingHeight(width: width), max(160, page.maxY - bar.frame.maxY - 20))
        card.frame = NSRect(x: bar.frame.minX - m, y: bar.frame.maxY + 8 - m, width: width + 2 * m, height: height + 2 * m)
    }

    /// The find bar closing (Esc, ✕, another tab shown) or Ask switched off: the question stops (the model's stream
    /// ends), the highlight goes, and the session lets go of the page, the question and the answer.
    func askClose(_ bar: FindBarView) {
        guard let s = AskPageFeature.sessions.removeValue(forKey: ObjectIdentifier(bar)) else { return }
        s.generation += 1
        s.run?.cancel()
        s.run = nil
        s.page = nil
        if let tab = s.tab, !tab.isClosed { PageReader.clearHighlight(tab) }
        let card = s.card
        card.layer?.fade(from: 1, to: 0, duration: 0.1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { card.removeFromSuperview() }
    }

    /// Reads the shown page (again, if it changed) and asks.
    func ask(_ question: String, in bar: FindBarView) {
        guard let s = AskPageFeature.sessions[ObjectIdentifier(bar)] else { return }
        s.run?.cancel()
        s.generation += 1
        let g = s.generation
        let ai = AIFeatures.shared
        guard let id = shownTabID, let tab = engineTab(for: id) else { return }
        // Before reading anything: off or no model, or nothing asked.
        let early: AskPageRefusal? = !ai.canAsk ? .unavailable : AIText.collapse(question).isEmpty ? .emptyQuestion : nil
        if let early {
            s.card.show(refusal: early)
            return layoutFindBar()
        }
        if let old = s.tab, old !== tab, !old.isClosed { PageReader.clearHighlight(old) }
        s.tab = tab
        s.profileID = app?.profiles.profileID(for: tab.profile)
        s.card.showReading(question: question)
        layoutFindBar()
        ai.recordUse(.aiAskPage(.used))
        PageReader.read(tab, cap: AskPageLimits.readCap) { [weak self, weak bar] page in
            guard let self, let bar, let s = AskPageFeature.sessions[ObjectIdentifier(bar)], s.generation == g else { return }
            if let r = AskPageRefusal.check(question: question, page: page, isPrivate: false, available: ai.canAsk) {
                s.card.show(refusal: r)
                return self.layoutFindBar()
            }
            guard let page, let model = ai.askModel else { return }
            s.page = page
            var o = AskPageRun.Options()
            o.budget = AskPageBudget(contextTokens: AppleIntelligence.contextSize)
            #if AIRC_TESTING
            if let t = AskPageFeature.testOptions { o = t }
            #endif
            let run = AskPageRun(question: question, page: page, model: model, options: o)
            s.run = run
            // The run holds this callback, so it holds the run weakly (and `cancel` drops it).
            run.onUpdate = { [weak self, weak bar, weak run] state in
                guard let self, let bar, let run, let s = AskPageFeature.sessions[ObjectIdentifier(bar)], s.run === run else { return }
                s.card.update(state)
                self.layoutFindBar()
            }
            run.start()
        }
    }
}

#if AIRC_TESTING
extension AskPageFeature {
    /// Scripted checks: shorter timeouts.
    static var testOptions: AskPageRun.Options?
}
#endif

/// The answer card: the answer as it streams (soft placeholder lines until its first words), the page's sentences
/// behind it (each a row that scrolls the page to it), and a line on where the answer came from. Layers on the Space's
/// surface at popover elevation; the view is larger than the card by the shadow's reach.
final class AskAnswerView: NSView {
    static let margin: CGFloat = 20
    static let inset: CGFloat = 14

    var onJump: ((PageQuote) -> Void)?
    private(set) var hasContent = false
    private(set) var state: AskPageRun.State?
    private(set) var refusal: AskPageRefusal?

    private let plate = CALayer()
    private let header = NSTextField(labelWithString: "")
    let answerLabel = NSTextField(wrappingLabelWithString: "")
    /// Over the quotes when they don't confirm the answer: "Related text, not proof".
    let relatedLabel = NSTextField(labelWithString: "")
    private(set) var quoteRows: [AskQuoteRow] = []
    let footer = NSTextField(wrappingLabelWithString: "")
    private var placeholders: [CALayer] = []
    private let palette: Palette

    init(palette: Palette) {
        self.palette = palette
        super.init(frame: .zero)
        wantsLayer = true
        let t = palette.resolved
        plate.cornerRadius = AircRadius.popover
        plate.cornerCurve = .continuous
        plate.backgroundColor = t.surface.nsColor.cgColor
        plate.borderColor = t.surfaceBorder.nsColor.cgColor
        plate.borderWidth = 0.5
        plate.applyAircShadow(.popover)
        layer?.addSublayer(plate)
        header.font = AircFont.caption.appFont
        header.textColor = t.surfaceTextSecondary.nsColor
        answerLabel.font = AircFont.body.appFont
        answerLabel.textColor = t.surfaceText.nsColor
        answerLabel.isSelectable = true
        footer.font = AircFont.caption.appFont
        footer.textColor = t.surfaceTextSecondary.nsColor.withAlphaComponent(0.8)
        relatedLabel.font = AircFont.caption.weight(.semibold).appFont
        relatedLabel.textColor = t.surfaceTextSecondary.nsColor
        for v in [header, answerLabel, relatedLabel, footer] {
            v.drawsBackground = false
            v.isBezeled = false
            addSubview(v)
        }
        for _ in 0..<3 {
            let l = CALayer()
            l.cornerRadius = 4
            l.backgroundColor = t.surfaceTextSecondary.nsColor.withAlphaComponent(0.14).cgColor
            layer?.addSublayer(l)
            placeholders.append(l)
        }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var cardRect: NSRect { bounds.insetBy(dx: Self.margin, dy: Self.margin) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview, cardRect.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point) ?? self
    }

    override func mouseDown(with event: NSEvent) {}

    func showReading(question: String) {
        hasContent = true
        refusal = nil
        state = nil
        header.stringValue = "Reading this page…"
        answerLabel.stringValue = ""
        relatedLabel.stringValue = ""
        setQuotes([])
        footer.stringValue = ""
        setWaiting(true)
    }

    func show(refusal r: AskPageRefusal) {
        hasContent = true
        refusal = r
        state = nil
        header.stringValue = r == .privateWindow ? "Private window" : "Ask on Page"
        answerLabel.stringValue = r.message
        answerLabel.textColor = palette.resolved.surfaceTextSecondary.nsColor
        relatedLabel.stringValue = ""
        setQuotes([])
        footer.stringValue = ""
        setWaiting(false)
    }

    func update(_ s: AskPageRun.State) {
        hasContent = true
        state = s
        refusal = nil
        answerLabel.textColor = palette.resolved.surfaceText.nsColor
        answerLabel.stringValue = s.answer
        switch s.phase {
        case .answering:
            header.stringValue = s.checking ? "Checking against the page…" : s.answer.isEmpty ? "Thinking…" : "Answer"
            setWaiting(s.answer.isEmpty)
        case .done:
            header.stringValue = "Answer"
            setWaiting(false)
        case .refused(let r):
            return show(refusal: r)
        case .declined, .failed, .timedOut:
            // Never shown as a finished answer: what came is kept, marked unfinished, and the footer says why.
            header.stringValue = s.answer.isEmpty ? "Answer" : "Unfinished answer"
            setWaiting(false)
            let note: String
            switch s.phase {
            case .declined: note = "Apple Intelligence couldn't answer this question about this page."
            case .timedOut: note = "Apple Intelligence took too long to answer."
            default: note = "Apple Intelligence couldn't answer right now. Try again in a moment."
            }
            answerLabel.stringValue = s.answer.isEmpty ? note : s.answer + "…"
            if s.answer.isEmpty { answerLabel.textColor = palette.resolved.surfaceTextSecondary.nsColor }
        }
        setQuotes(s.phase == .done ? s.quotes : [])
        // Sentences that don't confirm the answer are shown as what they are.
        relatedLabel.stringValue = s.phase == .done && s.grounding == .unconfirmed && !s.quotes.isEmpty ? "Related text, not proof" : ""
        if s.isUnfinished {
            let why: String
            switch s.phase {
            case .timedOut: why = "Apple Intelligence took too long to finish this answer."
            case .declined: why = "Apple Intelligence stopped answering partway."
            default: why = "Apple Intelligence stopped before finishing this answer."
            }
            footer.stringValue = why + " Answered on this Mac."
        } else if s.isFinished {
            let partial = (s.plan?.left ?? 0) > 0
            var source = partial ? "From the parts of this page that match your question." : "From this page's text."
            // Only the check against the page's sentences confirms an answer (AircKit's AskPageSupport); words never do.
            switch s.grounding {
            case .verified: source = partial ? "Checked against the parts of this page that match your question." : "Checked against this page's text."
            case .contradicted: source = "Apple Intelligence's answer didn't match the page; above is what the page says."
            case .unconfirmed: source = s.answerReplaced ? "" : "Not confirmed by the page."
            case .notOnPage: if !s.answerReplaced { source = "No sentence on this page backs this answer up." }
            case .none: break
            }
            footer.stringValue = (source.isEmpty ? "" : source + " ") + "Answered on this Mac."
        } else {
            footer.stringValue = ""
        }
        needsLayout = true
    }

    private func setQuotes(_ quotes: [PageQuote]) {
        quoteRows.forEach { $0.removeFromSuperview() }
        quoteRows = quotes.map { q in
            let row = AskQuoteRow(quote: q, palette: palette)
            row.action = { [weak self] in self?.onJump?(q) }
            addSubview(row)
            return row
        }
    }

    private func setWaiting(_ on: Bool) {
        placeholders.forEach { $0.isHidden = !on }
        if on {
            for (i, l) in placeholders.enumerated() where l.animation(forKey: "pulse") == nil {
                let a = CABasicAnimation(keyPath: "opacity")
                a.fromValue = 1
                a.toValue = 0.45
                a.duration = 0.9
                a.beginTime = CACurrentMediaTime() + Double(i) * 0.12
                a.autoreverses = true
                a.repeatCount = .infinity
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                l.add(a, forKey: "pulse")
            }
        } else {
            placeholders.forEach { $0.removeAllAnimations() }
        }
        needsLayout = true
    }

    private func textHeight(_ f: NSTextField, _ w: CGFloat) -> CGFloat {
        guard !f.stringValue.isEmpty else { return 0 }
        f.preferredMaxLayoutWidth = w
        return ceil(f.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: w, height: 10_000)).height ?? 0)
    }

    /// The card's height for a width (without the shadow's room).
    func fittingHeight(width: CGFloat) -> CGFloat {
        let w = width - 2 * Self.inset
        var h = Self.inset + 14 + 8
        if placeholders.first?.isHidden == false { h += 3 * 12 + 2 * 7 } else { h += textHeight(answerLabel, w) }
        if !relatedLabel.stringValue.isEmpty { h += 10 + 14 }
        if !quoteRows.isEmpty { h += 10 + quoteRows.reduce(0) { $0 + $1.height(width: w) + 4 } }
        if !footer.stringValue.isEmpty { h += 10 + textHeight(footer, w) }
        return h + Self.inset
    }

    override func layout() {
        super.layout()
        let card = cardRect
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        plate.frame = card
        plate.shadowPath = CGPath(roundedRect: plate.bounds, cornerWidth: AircRadius.popover, cornerHeight: AircRadius.popover, transform: nil)
        let x = card.minX + Self.inset, w = card.width - 2 * Self.inset
        var y = card.minY + Self.inset
        header.frame = NSRect(x: x - 2, y: y, width: w, height: 14)
        y += 14 + 8
        if placeholders.first?.isHidden == false {
            for (i, l) in placeholders.enumerated() {
                l.frame = NSRect(x: x, y: y + 1, width: i == 2 ? w * 0.55 : w, height: 10)
                y += 12 + (i < 2 ? 7 : 0)
            }
            answerLabel.frame = .zero
        } else {
            let ah = textHeight(answerLabel, w)
            answerLabel.frame = NSRect(x: x - 2, y: y, width: w + 4, height: ah)
            y += ah
        }
        if !relatedLabel.stringValue.isEmpty {
            y += 10
            relatedLabel.frame = NSRect(x: x - 2, y: y, width: w, height: 14)
            y += 14
        } else {
            relatedLabel.frame = .zero
        }
        if !quoteRows.isEmpty {
            y += 10
            for r in quoteRows {
                let rh = r.height(width: w)
                r.frame = NSRect(x: x - 6, y: y, width: w + 12, height: rh)
                y += rh + 4
            }
        }
        if !footer.stringValue.isEmpty {
            y += 10
            footer.frame = NSRect(x: x - 2, y: y, width: w + 4, height: textHeight(footer, w))
        } else {
            footer.frame = .zero
        }
        CATransaction.commit()
    }

    func present() {
        layer?.fade(from: 0, to: 1, duration: 0.14)
        let curve = AircCurve.dialog
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.97
        grow.toValue = 1
        grow.duration = curve.duration
        grow.timingFunction = curve.timingFunction
        plate.add(grow, forKey: "grow")
    }
}

/// One of the page's sentences under an answer: a quote mark, the sentence (two lines at most) and an arrow; a click
/// scrolls the page to it.
final class AskQuoteRow: NSView {
    let quote: PageQuote
    var action: (() -> Void)?
    let label = NSTextField(wrappingLabelWithString: "")
    private let mark = NSImageView()
    private let palette: Palette
    private var hovered = false { didSet { updateFill() } }

    init(quote: PageQuote, palette: Palette) {
        self.quote = quote
        self.palette = palette
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = AircRadius.control
        layer?.cornerCurve = .continuous
        label.stringValue = quote.text
        label.font = AircFont.callout.appFont
        label.textColor = palette.resolved.surfaceTextSecondary.nsColor
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byWordWrapping
        label.cell?.truncatesLastVisibleLine = true
        label.isSelectable = false
        label.drawsBackground = false
        mark.image = NSImage(systemSymbolName: "text.quote", accessibilityDescription: nil)
        mark.contentTintColor = palette.resolved.surfaceTextSecondary.nsColor.withAlphaComponent(0.7)
        mark.symbolConfiguration = .init(pointSize: 10, weight: .medium)
        addSubview(mark)
        addSubview(label)
        toolTip = "Show on the page"
        setAccessibilityRole(.button)
        setAccessibilityLabel("Show on the page: " + quote.text)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func height(width: CGFloat) -> CGFloat {
        let w = width - 22
        label.preferredMaxLayoutWidth = w
        let h = ceil(label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: w, height: 1000)).height ?? 16)
        return max(24, h + 8)
    }

    override func layout() {
        super.layout()
        mark.frame = NSRect(x: 6, y: 6, width: 14, height: 14)
        label.frame = NSRect(x: 24, y: 4, width: bounds.width - 30, height: bounds.height - 8)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }
    override func accessibilityPerformPress() -> Bool { action?(); return true }

    private func updateFill() {
        layer?.backgroundColor = hovered ? palette.resolved.surfaceHover.nsColor.cgColor : nil
        label.textColor = hovered ? palette.resolved.surfaceText.nsColor : palette.resolved.surfaceTextSecondary.nsColor
    }
}

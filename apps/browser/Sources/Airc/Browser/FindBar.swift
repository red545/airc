// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import AircKit

/// ⌘F (CB-2): a find field over the page's top-right corner. ↩ / ⌘G next, ⇧↩ / ⇧⌘G previous, Esc closes.
/// ⌥⌘F (K05, Arc's Find and Replace): a second row with a Replace field, Replace (↩ in it) and All (⌥↩). It replaces in
/// the page's editable text (`PageReplace`): the field that has the keyboard, else every editable field on the page.
final class FindBarView: NSView, NSSearchFieldDelegate {
    let field = NSSearchField()
    private let status = NSTextField(labelWithString: "")
    private let previous = GlyphButton(symbol: "chevron.up", size: 11)
    private let next = GlyphButton(symbol: "chevron.down", size: 11)
    private let close = GlyphButton(symbol: "xmark", size: 10)
    var onFind: ((String, Bool) -> Void)?
    var onClose: (() -> Void)?
    /// Ask on Page (AI/AskPageCard.swift): the bar's other mode, a question about the page. Hidden unless the main
    /// window prepares it (never in a private window).
    let askButton = GlyphButton(symbol: "sparkles", size: 12)
    var isAsking = false
    var onAsk: ((String) -> Void)?
    var onToggleAsk: (() -> Void)?
    /// The modifier keys of the key being handled (the scripted checks stand in for the keyboard).
    var modifiers: () -> NSEvent.ModifierFlags = { NSApp.currentEvent?.modifierFlags ?? [] }
    /// Find and Replace's row (hidden for Find alone).
    let replaceField = NSTextField()
    let replaceButton = NSButton(title: "Replace", target: nil, action: nil)
    let replaceAllButton = NSButton(title: "All", target: nil, action: nil)
    private(set) var isReplacing = false
    /// What Replace works in: "field" (the one that had the keyboard) or "page" (every editable field), as it opened.
    var replaceScope = "auto"
    /// What the last Replace or All did (the scripted checks read it).
    var lastReplace: PageReplace.Result?
    /// (find, replace with, all).
    var onReplace: ((String, String, Bool) -> Void)?

    static let size = NSSize(width: 340, height: 40)
    static let replacingHeight: CGFloat = 74
    var preferredHeight: CGFloat { isReplacing ? Self.replacingHeight : Self.size.height }

    init(palette: Palette) {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = palette.panelBackground.cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = palette.panelBorder.cgColor
        layer?.applyAircShadow(.popover)
        field.placeholderString = "Find on page"
        field.focusRingType = .none
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.target = self
        field.action = #selector(changed)
        status.font = AircFont.callout.appFont
        status.textColor = palette.panelSecondary
        status.alignment = .right
        for b in [previous, next, close] {
            b.tint = palette.panelSecondary
            b.hoverFill = palette.panelSelection
        }
        previous.toolTip = "Previous (⇧⌘G)"
        next.toolTip = "Next (⌘G)"
        close.toolTip = "Close (Esc)"
        previous.action = { [weak self] in self?.find(forward: false) }
        next.action = { [weak self] in self?.find(forward: true) }
        close.action = { [weak self] in self?.onClose?() }
        askButton.tint = palette.panelSecondary
        askButton.hoverFill = palette.panelSelection
        askButton.toolTip = "Ask about this page (⌘↩)"
        askButton.isHidden = true
        askButton.action = { [weak self] in self?.onToggleAsk?() }
        replaceField.placeholderString = "Replace with"
        replaceField.focusRingType = .none
        replaceField.bezelStyle = .roundedBezel
        replaceField.font = field.font
        replaceField.delegate = self
        for (b, all) in [(replaceButton, false), (replaceAllButton, true)] {
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = AircFont.callout.appFont
            b.target = self
            b.action = all ? #selector(replaceAllPressed) : #selector(replacePressed)
        }
        replaceButton.toolTip = "Replace the next match (↩ in the field)"
        replaceAllButton.toolTip = "Replace every match (⌥↩)"
        field.nextKeyView = replaceField
        replaceField.nextKeyView = field
        for v in [field, status, previous, next, close, askButton, replaceField, replaceButton, replaceAllButton] as [NSView] { addSubview(v) }
        setReplacing(false)
    }

    /// Shows or hides the Replace row. `scope` is what it replaces in, said in its placeholder.
    func setReplacing(_ on: Bool, scope: String? = nil) {
        isReplacing = on
        for v in [replaceField, replaceButton, replaceAllButton] as [NSView] { v.isHidden = !on }
        if let scope { replaceField.placeholderString = scope }
        needsLayout = true
    }

    /// Nothing on the page to replace in: the buttons say so by being off.
    func setReplaceEnabled(_ on: Bool) {
        replaceButton.isEnabled = on
        replaceAllButton.isEnabled = on
    }

    /// After a replace: "2 replaced" (or none).
    func setReplaced(_ n: Int) {
        status.stringValue = n == 0 ? "None replaced" : "\(n) replaced"
    }

    @objc func replacePressed() { onReplace?(field.stringValue, replaceField.stringValue, false) }
    @objc func replaceAllPressed() { onReplace?(field.stringValue, replaceField.stringValue, true) }

    required init?(coder: NSCoder) { fatalError() }
    override var mouseDownCanMoveWindow: Bool { false }

    override func layout() {
        super.layout()
        // The find row is the top 40 points; Replace's row is below it (not while asking: one row then).
        let h = Self.size.height, top = bounds.height - h
        for v in [replaceField, replaceButton, replaceAllButton] as [NSView] { v.isHidden = !isReplacing || isAsking }
        if isReplacing && !isAsking {
            let y = (top - 24) / 2 + 2
            replaceAllButton.frame = NSRect(x: bounds.width - 8 - 46, y: y, width: 46, height: 24)
            replaceButton.frame = NSRect(x: replaceAllButton.frame.minX - 4 - 70, y: y, width: 70, height: 24)
            replaceField.frame = NSRect(x: 8, y: y, width: replaceButton.frame.minX - 6 - 8, height: 24)
        }
        func row(_ r: NSRect) -> NSRect { r.offsetBy(dx: 0, dy: top) }
        close.frame = NSRect(x: bounds.width - 8 - 24, y: (h - 24) / 2, width: 24, height: 24)
        // Ask on Page's button sits left of ✕; while asking, the arrows and the count give way to the question.
        var right = close.frame.minX
        if !askButton.isHidden {
            askButton.frame = NSRect(x: right - 26, y: (h - 24) / 2, width: 24, height: 24)
            right = askButton.frame.minX
        }
        for v in [next, previous, status] as [NSView] { v.isHidden = isAsking }
        next.frame = NSRect(x: right - 26, y: (h - 24) / 2, width: 24, height: 24)
        previous.frame = NSRect(x: next.frame.minX - 26, y: (h - 24) / 2, width: 24, height: 24)
        status.frame = NSRect(x: previous.frame.minX - 84, y: (h - 16) / 2, width: 78, height: 16)
        let end = isAsking ? right - 6 : status.frame.minX - 6
        field.frame = NSRect(x: 8, y: (h - 24) / 2, width: end - 8, height: 24)
        for v in [close, next, previous, status, field] as [NSView] { v.frame = row(v.frame) }
        if !askButton.isHidden { askButton.frame = row(askButton.frame) }
    }

    /// `active`: the 1-based match the page is on, when the engine reports it (Chromium): "2 of 5".
    func setStatus(found: Bool?, matches: Int?, active: Int? = nil) {
        switch (found, matches) {
        case (nil, _): status.stringValue = ""
        case (false?, _): status.stringValue = "No matches"
        case (true?, let n?):
            if let active, active > 0 { status.stringValue = "\(active) of \(n)" }
            else { status.stringValue = n == 1 ? "1 match" : "\(n) matches" }
        case (true?, nil): status.stringValue = ""
        }
    }

    var statusText: String { status.stringValue }

    /// Finds in the page; never while asking (the field holds a question then, and typing it searches nothing).
    func find(forward: Bool) {
        guard !isAsking else { return }
        onFind?(field.stringValue, forward)
    }

    @objc private func changed() { find(forward: true) }

    #if canImport(AircCore)
    /// Chromium reports which match is active as the page moves between them: the bar of the window showing that
    /// page (the main window or a private one) shows "2 of 5".
    static func routeFindState(_ tab: EngineTab, _ state: [String: Any]) {
        // The browser window with the page (WIN-7), else the private window showing it.
        let app = NSApp.delegate as? AppDelegate
        let c = app?.controller(owning: tab) ?? app?.controller
        let bar = c.flatMap { c in c.shownTabID.flatMap { c.engineTab(for: $0) } === tab ? c.findBar : nil }
            ?? PrivateBrowsing.shared.windows.first { $0.shownPage === tab }?.findBar
        guard let bar, (state["text"] as? String) == bar.field.stringValue else { return }
        let matches = (state["matches"] as? NSNumber)?.intValue ?? 0
        let active = (state["active"] as? NSNumber)?.intValue ?? 0
        bar.setStatus(found: matches > 0, matches: matches, active: active)
    }
    #endif

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        // The Replace field: ↩ replaces the next match, ⌥↩ every match; Esc closes.
        if control === replaceField {
            switch selector {
            case #selector(NSResponder.cancelOperation(_:)): onClose?(); return true
            case #selector(NSResponder.insertNewline(_:)):
                onReplace?(field.stringValue, replaceField.stringValue, modifiers().contains(.option))
                return true
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                onReplace?(field.stringValue, replaceField.stringValue, true)
                return true
            default: return false
            }
        }
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            // Ask on Page: ↩ in Ask mode, ⌘↩ in Find mode.
            let flags = modifiers()
            if !askButton.isHidden, isAsking || flags.contains(.command) {
                onAsk?(field.stringValue)
                return true
            }
            find(forward: !flags.contains(.shift))
            return true
        default:
            return false
        }
    }
}

extension WindowController {
    /// ⌘F: opens (or focuses) the find field over the page.
    func showFind() {
        guard let id = shownTabID, engineTab(for: id) != nil || shownNote != nil else { return NSSound.beep() }
        Telemetry.shared.record(.featureUsed(.find))
        if let bar = findBar {
            // ⌘F while asking goes back to Find; while replacing, to Find alone.
            if bar.isAsking { findInsteadOfAsking(bar) }
            if bar.isReplacing { bar.setReplacing(false); layoutFindBar() }
            window.makeFirstResponder(bar.field)
            bar.field.currentEditor()?.selectAll(nil)
            return
        }
        let bar = FindBarView(palette: currentPalette)
        bar.onFind = { [weak self] text, forward in self?.find(text, forward: forward) }
        bar.onReplace = { [weak self] text, with, all in self?.replaceInPage(text, with: with, all: all) }
        #if canImport(AircCore)
        (app?.engine as? ChromiumEngine)?.findStateDidChange = FindBarView.routeFindState
        #endif
        bar.onClose = { [weak self] in self?.closeFind(refocusPage: true) }
        findBar = bar
        prepareAsk(bar)
        // A note (Notes/NoteCenter.swift): the same bar finds in its text; Ask on Page is for pages.
        if shownNote != nil {
            bar.askButton.isHidden = true
            bar.field.placeholderString = "Find in note"
        }
        root.addSubview(bar, positioned: .below, relativeTo: toast)
        layoutFindBar()
        bar.layer?.fade(from: 0, to: 1, duration: 0.12)
        window.makeFirstResponder(bar.field)
    }

    func layoutFindBar() {
        guard let bar = findBar else { return }
        let s = FindBarView.size
        // SV-1: over the focused pane, which it searches.
        var page = card.frame
        if shownSplitID != nil, let id = shownTabID, let pane = splitContainer.pane(for: id) {
            page = splitContainer.convert(pane.frame, to: root)
        }
        let width = bar.isAsking ? AskPageFeature.width : s.width
        let height = bar.isAsking ? s.height : bar.preferredHeight
        bar.frame = NSRect(x: page.maxX - width - 12, y: page.minY + 12, width: width, height: height)
        layoutAskCard(bar)
    }

    /// ⌘G / ⇧⌘G.
    func findAgain(forward: Bool) {
        guard let bar = findBar, !bar.field.stringValue.isEmpty else { return showFind() }
        bar.find(forward: forward)
    }

    private func find(_ text: String, forward: Bool) {
        if let note = shownNote {
            let (matches, active) = note.view.find(text, forward: forward)
            findBar?.setStatus(found: text.isEmpty ? nil : matches > 0, matches: matches, active: active)
            return
        }
        guard let id = shownTabID, let page = engineTab(for: id) else { return }
        guard !text.isEmpty else {
            page.stopFinding()
            findBar?.setStatus(found: nil, matches: nil)
            return
        }
        page.find(text, forward: forward) { [weak self] found, matches in self?.findBar?.setStatus(found: found, matches: matches) }
    }

    // MARK: Find and Replace (K05)

    /// ⌥⌘F (Arc's Find and Replace): the find bar with its Replace row, for the page's editable text: the field that has
    /// the keyboard when it opens, else every editable field on the page and in its same-origin frames. A note finds
    /// only (its own text has the Mac's find).
    func showFindAndReplace() {
        showFind()
        guard let bar = findBar else { return }
        guard shownNote == nil, let page = shownPage else { return }
        bar.setReplacing(true, scope: "Replace with")
        layoutFindBar()
        page.evaluate(PageReplace.script(op: "scope", find: "", with: "", scope: "auto")) { [weak bar] v in
            guard let bar, bar.isReplacing else { return }
            let r = PageReplace.Result(v)
            bar.replaceScope = r.field ? "field" : "page"
            bar.setReplacing(true, scope: r.fields == 0 ? "No editable text on this page" : r.field ? "Replace in this field" : "Replace in the page's fields")
            bar.setReplaceEnabled(r.fields > 0)
        }
    }

    /// Replace (the next match) or All, in the scope the bar opened with; then the page's matches are found again.
    func replaceInPage(_ text: String, with replacement: String, all: Bool) {
        guard let bar = findBar, bar.isReplacing, !text.isEmpty, let page = shownPage else { return NSSound.beep() }
        page.evaluate(PageReplace.script(op: all ? "all" : "one", find: text, with: replacement, scope: bar.replaceScope)) { [weak bar] v in
            let r = PageReplace.Result(v)
            bar?.lastReplace = r
            bar?.setReplaced(r.replaced)
            if r.replaced == 0 { NSSound.beep() }
            // The highlights follow the page's new text (the count stays "N replaced" until the next find).
            page.find(text, forward: true) { _, _ in }
        }
    }

    /// Esc, the ✕, or another tab shown.
    func closeFind(refocusPage: Bool) {
        guard let bar = findBar else { return }
        findBar = nil
        closeAskCard(bar)
        if let note = shownNote {
            note.view.stopFinding()
            if refocusPage { note.focus() }
        }
        if let id = shownTabID, let page = engineTab(for: id) {
            page.stopFinding()
            if refocusPage { page.focus() }
        }
        bar.layer?.fade(from: 1, to: 0, duration: 0.1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { bar.removeFromSuperview() }
    }

    // MARK: Chrome's page commands (CB-2)

    private var shownPage: EngineTab? { shownTabID.flatMap { engineTab(for: $0) } }

    func reloadIgnoringCache() { shownPage?.reloadIgnoringCache() }

    func zoom(step: Int) {
        guard let page = shownPage else { return }
        page.zoom(step: step)
        showToast(String(format: "%.0f %%", page.zoomFactor * 100))
    }

    func showDevTools(console: Bool) {
        guard let page = shownPage else { return }
        if !page.showDevTools(console: console) {
            showToast("Right-click the page and choose Inspect Element")
        }
    }

    func viewSource() {
        guard let url = shownPage?.url, url.scheme == "http" || url.scheme == "https" else { return NSSound.beep() }
        if app?.engine.name.hasPrefix("Chromium") == true, let source = URL(string: "view-source:" + url.absoluteString) {
            navigate(to: source, newTab: true)
        } else {
            showToast("View Source needs the Chromium engine")
        }
    }

    func printPage() {
        if printNote() { return }
        guard let page = shownPage else { return NSSound.beep() }
        if !page.printPage(from: window) { showToast("Printing isn't available in this engine yet") }
    }

    /// ⌘Y: Chromium's history page; the Command Bar's history on the dev engine.
    func showHistory() {
        if app?.engine.name.hasPrefix("Chromium") == true, let url = URL(string: "chrome://history") {
            navigate(to: url, newTab: true)
        } else {
            openCommandBar(mode: .newTab)
        }
    }
}

/// Find and Replace in a page (K05): one script per action, evaluated in the page's top frame, which reaches the
/// documents of its same-origin frames (another origin's frames are out of reach and left alone).
///   - Where: "field": the editable element that has the keyboard (through same-origin frames); "page": every editable
///     field: text-like `input`s (text, search, email, url, tel), `textarea`s and contenteditable areas. Never a
///     password field, nor a read-only or disabled one. "auto" picks "field" when one has the keyboard.
///   - How: as typing would, through the page's own editing (`execCommand('insertText')` on the match selected), so the
///     page sees its input events and ⌘Z in the page undoes it: Replace All is one undo step per text field, one per
///     replacement in a contenteditable area. A field whose selection can't be set (an email field) takes the value with
///     an input event instead (no undo there).
///   - Matching is case-insensitive, like the find bar's; a match split across two elements of rich text isn't replaced.
enum PageReplace {
    struct Result {
        var replaced = 0
        var remaining = 0
        var fields = 0
        var field = false
        var frames = 0
        init(_ v: Any?) {
            guard let s = v as? String, let o = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] else { return }
            replaced = (o["replaced"] as? NSNumber)?.intValue ?? 0
            remaining = (o["remaining"] as? NSNumber)?.intValue ?? 0
            fields = (o["fields"] as? NSNumber)?.intValue ?? 0
            field = o["field"] as? Bool == true
            frames = (o["frames"] as? NSNumber)?.intValue ?? 0
        }
    }

    static func script(op: String, find: String, with replacement: String, scope: String) -> String {
        let args = (try? JSONSerialization.data(withJSONObject: [op, find, replacement, scope]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return "(" + runtime + ").apply(null, " + args + ")"
    }

    static let runtime = #"""
    function (op, find, repl, scope) {
      var needle = String(find || '').toLowerCase(), docs = [];
      function collect(d) {
        docs.push(d);
        var fs = d.querySelectorAll('iframe, frame');
        for (var i = 0; i < fs.length; i++) { try { var cd = fs[i].contentDocument; if (cd && cd.documentElement) collect(cd); } catch (e) {} }
      }
      collect(document);
      function host(el) { while (el && el.parentElement && el.parentElement.isContentEditable) el = el.parentElement; return el; }
      function textField(el) {
        if (el.localName === 'textarea') return true;
        if (el.localName !== 'input') return false;
        var t = String(el.getAttribute('type') || 'text').toLowerCase();
        return t === 'text' || t === 'search' || t === 'email' || t === 'url' || t === 'tel';
      }
      function editable(el) {
        if (!el || el.nodeType !== 1 || el.disabled || el.readOnly) return false;
        if (el.localName === 'input' || el.localName === 'textarea') return textField(el);
        return el.isContentEditable === true;
      }
      // The editable element with the keyboard, through same-origin frames.
      function focused() {
        var d = document, el = d.activeElement;
        while (el && (el.localName === 'iframe' || el.localName === 'frame')) {
          try { d = el.contentDocument; el = d && d.activeElement; } catch (e) { return null; }
        }
        if (el && el.isContentEditable) el = host(el);
        return editable(el) ? el : null;
      }
      var target = focused(), useField = !!target && scope !== 'page';
      var fields = [];
      if (useField) fields = [target];
      else for (var di = 0; di < docs.length; di++) {
        var list = docs[di].querySelectorAll('input, textarea, [contenteditable]');
        for (var li = 0; li < list.length; li++) {
          var el = list[li].isContentEditable ? host(list[li]) : list[li];
          if (editable(el) && fields.indexOf(el) < 0) fields.push(el);
        }
      }
      function isText(el) { return el.localName === 'input' || el.localName === 'textarea'; }
      function textOf(el) { return isText(el) ? String(el.value) : String(el.textContent); }
      function count(s) {
        if (!needle) return 0;
        var n = 0, i = 0, l = s.toLowerCase();
        while ((i = l.indexOf(needle, i)) >= 0) { n++; i += needle.length; }
        return n;
      }
      function total() { var n = 0; for (var i = 0; i < fields.length; i++) n += count(textOf(fields[i])); return n; }
      function result(replaced) {
        return JSON.stringify({ replaced: replaced, remaining: total(), fields: fields.length, field: useField, frames: docs.length - 1 });
      }
      if (op === 'scope' || !needle) return result(0);

      // The page's own editing: the match selected, then typed over.
      function typeOver(el, d, text) {
        if (text === '') return d.execCommand('delete', false, null);
        return d.execCommand('insertText', false, text);
      }
      function replaceInText(el, at, len, text) {
        var d = el.ownerDocument, before = String(el.value);
        el.focus();
        var selected = true;
        try { el.setSelectionRange(at, at + len); } catch (e) { selected = false; }
        if (selected && typeOver(el, d, text) && String(el.value) !== before) return true;
        el.value = before.slice(0, at) + text + before.slice(at + len);
        el.dispatchEvent(new (d.defaultView.InputEvent || Event)('input', { bubbles: true, inputType: 'insertReplacementText', data: text }));
        return true;
      }
      // A match in rich text, as a range inside one text node (null when it spans elements).
      function rangeAt(el, at, len) {
        var d = el.ownerDocument, w = d.createTreeWalker(el, 4), pos = 0, n;
        while ((n = w.nextNode())) {
          var l = n.nodeValue.length;
          if (at >= pos && at + len <= pos + l) { var r = d.createRange(); r.setStart(n, at - pos); r.setEnd(n, at - pos + len); return r; }
          if (at < pos + l) return null;
          pos += l;
        }
        return null;
      }
      function replaceInRich(el, at, len, text) {
        var r = rangeAt(el, at, len);
        if (!r) return false;
        var d = el.ownerDocument, s = d.defaultView.getSelection();
        el.focus();
        s.removeAllRanges(); s.addRange(r);
        return typeOver(el, d, text);
      }
      function matches(el) {
        var out = [], i = 0, l = textOf(el).toLowerCase();
        while ((i = l.indexOf(needle, i)) >= 0) { out.push(i); i += needle.length; }
        return out;
      }

      if (op === 'all') {
        var done = 0;
        for (var fi = 0; fi < fields.length; fi++) {
          var f = fields[fi], at = matches(f);
          if (!at.length) continue;
          if (isText(f)) {
            // One step for the whole field: its new text typed over all of it.
            var v = String(f.value), next = '', last = 0;
            for (var k = 0; k < at.length; k++) { next += v.slice(last, at[k]) + repl; last = at[k] + needle.length; }
            next += v.slice(last);
            if (replaceInText(f, 0, v.length, next)) done += at.length;
          } else {
            // Last first, so the earlier positions stay where they were.
            for (var m = at.length - 1; m >= 0; m--) if (replaceInRich(f, at[m], needle.length, repl)) done++;
          }
        }
        return result(done);
      }

      // Replace: the next match after the last one replaced (in field order, then from the start again).
      var key = '__aircReplaceNext', last = window[key];
      var start = 0, from = 0;
      if (last && fields.indexOf(last.el) >= 0) { start = fields.indexOf(last.el); from = last.at; }
      for (var pass = 0; pass <= fields.length; pass++) {
        var idx = (start + pass) % (fields.length || 1), el2 = fields[idx];
        if (!el2) break;
        var spots = matches(el2);
        for (var q = 0; q < spots.length; q++) {
          if (pass === 0 && spots[q] < from) continue;
          var ok = isText(el2) ? replaceInText(el2, spots[q], needle.length, repl) : replaceInRich(el2, spots[q], needle.length, repl);
          if (!ok) continue;
          try { Object.defineProperty(window, key, { value: { el: el2, at: spots[q] + repl.length }, configurable: true, writable: true }); } catch (e) {}
          return result(1);
        }
        from = 0;
      }
      return result(0);
    }
    """#
}


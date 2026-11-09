// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import AppKit

/// K05 (Arc's Edit and Format menus, Arc 1.170's MainMenu): the Mac's own editing commands. Spelling and Grammar,
/// Substitutions, Transformations and Speech go down the responder chain to whatever has the keyboard (a page, a
/// note, a field), so each is enabled only where it works. Find adds Use Selection to Find and Jump to Selection, for
/// pages and notes; Format › Font's Bold, Italic and Underline give a note its own marks (Notes/NoteEditor.swift), a
/// rich text field its font traits, and an editable page its own bold, italic and underline.
enum NativeEditingMenus {
    /// One of the Mac's editing actions: its title, the responder method, and its usual key.
    struct Action {
        let title: String
        let selector: Selector
        var key = ""
        var modifiers: NSEvent.ModifierFlags = []
    }

    static func action(_ title: String, _ selector: String, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = []) -> Action {
        Action(title: title, selector: NSSelectorFromString(selector), key: key, modifiers: modifiers)
    }

    /// Edit's submenus, in Arc's order (nil: a separator).
    static let submenus: [(title: String, actions: [Action?])] = [
        ("Spelling and Grammar", [
            action("Show Spelling and Grammar", "showGuessPanel:", ":", .command),
            action("Check Document Now", "checkSpelling:", ";", .command),
            nil,
            action("Check Spelling While Typing", "toggleContinuousSpellChecking:"),
            action("Check Grammar With Spelling", "toggleGrammarChecking:"),
            action("Correct Spelling Automatically", "toggleAutomaticSpellingCorrection:"),
        ]),
        ("Substitutions", [
            action("Show Substitutions", "orderFrontSubstitutionsPanel:"),
            nil,
            action("Smart Copy/Paste", "toggleSmartInsertDelete:"),
            action("Smart Quotes", "toggleAutomaticQuoteSubstitution:"),
            action("Smart Dashes", "toggleAutomaticDashSubstitution:"),
            action("Smart Links", "toggleAutomaticLinkDetection:"),
            action("Data Detectors", "toggleAutomaticDataDetection:"),
            action("Text Replacement", "toggleAutomaticTextReplacement:"),
        ]),
        ("Transformations", [
            action("Make Upper Case", "uppercaseWord:"),
            action("Make Lower Case", "lowercaseWord:"),
            action("Capitalize", "capitalizeWord:"),
        ]),
        ("Speech", [
            action("Start Speaking", "startSpeaking:"),
            action("Stop Speaking", "stopSpeaking:"),
        ]),
    ]

    /// Edit's Delete, after Paste and Match Style (AppKit's own, for fields and notes; pages take it too).
    static let delete = action("Delete", "delete:")

    /// The submenu items, each sent to the first responder (target nil): AppKit enables one only when something in the
    /// key window's responder chain answers it.
    static func editSubmenuItems() -> [NSMenuItem] {
        submenus.map { s in
            let item = NSMenuItem(title: s.title, action: nil, keyEquivalent: "")
            let sub = NSMenu(title: s.title)
            for a in s.actions {
                guard let a else { sub.addItem(.separator()); continue }
                let i = sub.addItem(withTitle: a.title, action: a.selector, keyEquivalent: a.key)
                i.keyEquivalentModifierMask = a.modifiers
            }
            item.submenu = sub
            return item
        }
    }

    /// The app menu's Services (K05): the Mac's own submenu (NSApp.servicesMenu), filled by macOS. Text and rich text go
    /// to a service and come back: the page views of both engines are services requestors for their selection (and
    /// take a service's text back into an editable selection), notes and text fields are AppKit's own.
    static func servicesItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Services")
        item.submenu = menu
        NSApp.servicesMenu = menu
        // AppKit asks a view with the types registered here, as they are: Chromium's page view answers the modern
        // string type, WebKit's the legacy names (NSStringPboardType, NSRTFPboardType), so both are registered.
        let types: [NSPasteboard.PasteboardType] = [.string, .rtf, legacyString, .init("NSRTFPboardType")]
        NSApp.registerServicesMenuSendTypes(types, returnTypes: types)
        return item
    }

    /// The legacy string type (NSStringPboardType), which WebKit's view answers for Services.
    static let legacyString = NSPasteboard.PasteboardType("NSStringPboardType")

    /// Format › Font: Bold, Italic, Underline (⌘B ⌘I ⌘U), through FormatRouter.
    static func formatMenu() -> NSMenu {
        let format = NSMenu(title: "Format")
        let font = NSMenuItem(title: "Font", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "Font")
        for t in FormatRouter.Trait.allCases {
            let i = sub.addItem(withTitle: t.title, action: #selector(FormatRouter.apply(_:)), keyEquivalent: t.key)
            i.keyEquivalentModifierMask = .command
            i.target = FormatRouter.shared
            i.tag = t.rawValue
        }
        font.submenu = sub
        format.addItem(font)
        return format
    }

    /// The view in a page's hierarchy that answers `selector` (Chromium's and WebKit's page views answer the editing
    /// commands their engine supports), depth first.
    static func responder(for selector: Selector, under view: NSView) -> NSView? {
        if view.responds(to: selector) { return view }
        for v in view.subviews { if let r = responder(for: selector, under: v) { return r } }
        return nil
    }

    /// What answers `selector` in `window` now (the first responder or one of its next responders) and whether it
    /// would enable an item for it: what the menu shows while the window is key.
    static func target(of selector: Selector, in window: NSWindow?, item: NSMenuItem? = nil) -> (responder: NSResponder, enabled: Bool)? {
        var r: NSResponder? = window?.firstResponder
        while let x = r {
            if x.responds(to: selector) {
                let probe = item ?? NSMenuItem(title: "", action: selector, keyEquivalent: "")
                let enabled = (x as? NSMenuItemValidation)?.validateMenuItem(probe)
                    ?? (x as? NSUserInterfaceValidations)?.validateUserInterfaceItem(probe) ?? true
                return (x, enabled)
            }
            r = x.nextResponder
        }
        return nil
    }
}

/// Format › Font's Bold, Italic and Underline for whatever has the keyboard: a note's own marks (stored in the note),
/// a rich text field's font traits, or the page's own bold, italic and underline for its focused editable text (a page
/// that has the keyboard enables them; a focused element that isn't editable beeps). Disabled anywhere else.
final class FormatRouter: NSObject, NSMenuItemValidation {
    static let shared = FormatRouter()

    enum Trait: Int, CaseIterable {
        case bold = 1, italic, underline
        var title: String { ["Bold", "Italic", "Underline"][rawValue - 1] }
        var key: String { ["b", "i", "u"][rawValue - 1] }
        var noteMark: NoteMarks { [.bold, .italic, .underline][rawValue - 1] }
        var command: String { ["bold", "italic", "underline"][rawValue - 1] }
    }

    /// Where a trait goes in `window` now.
    enum Target {
        case note(NoteTextView)
        case text(NSTextView)
        case page(EngineTab)
    }

    func target(in window: NSWindow?) -> Target? {
        guard let window else { return nil }
        if let note = window.firstResponder as? NoteTextView { return .note(note) }
        if let text = window.firstResponder as? NSTextView, text.isRichText, text.isEditable, !text.isFieldEditor { return .text(text) }
        let app = NSApp.delegate as? AppDelegate
        if let c = app?.controller(for: window), let page = c.focusedPage { return .page(page) }
        return nil
    }

    @objc func apply(_ sender: NSMenuItem) {
        guard let trait = Trait(rawValue: sender.tag) else { return }
        apply(trait, in: NSApp.keyWindow)
    }

    func apply(_ trait: Trait, in window: NSWindow?) {
        if let t = target(in: window), pageHadTheKey(t) { return }
        switch target(in: window) {
        case .note(let note): note.toggle(trait.noteMark)
        case .text(let text):
            if trait == .underline { text.underline(nil); return }
            let item = NSMenuItem()
            item.tag = Int(trait == .bold ? NSFontTraitMask.boldFontMask.rawValue : NSFontTraitMask.italicFontMask.rawValue)
            let fonts = NSFontManager.shared, before = fonts.target
            fonts.target = text
            fonts.addFontTrait(item)
            fonts.target = before
        case .page(let page): page.evaluate(Self.pageScript(trait)) { v in if (v as? Bool) != true { NSSound.beep() } }
        case nil: NSSound.beep()
        }
    }

    /// The page's own command for its focused editable text; false when what has the focus isn't editable.
    static func pageScript(_ trait: Trait) -> String {
        "(function(){var e=document.activeElement;if(!e||!(e.isContentEditable||/^(input|textarea)$/i.test(e.tagName)))return false;"
            + "return document.execCommand('\(trait.command)')})()"
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { validate(menuItem, in: NSApp.keyWindow) }

    /// ⌘B ⌘I ⌘U pressed in a page: its own editor applies them; the menu's key equivalent must not apply them again
    /// (WebKit hands the key on to the menus after the page used it). A click on the menu item still does.
    private func pageHadTheKey(_ t: Target) -> Bool {
        guard case .page = t else { return false }
        return NSApp.currentEvent?.type == .keyDown
    }

    /// Enabled where the trait would apply; a note's item is ticked while the text has it.
    func validate(_ menuItem: NSMenuItem, in window: NSWindow?) -> Bool {
        guard let trait = Trait(rawValue: menuItem.tag), let t = target(in: window), !pageHadTheKey(t) else { menuItem.state = .off; return false }
        if case .note(let note) = t { menuItem.state = note.marks(at: note.selectedRange().location).contains(trait.noteMark) ? .on : .off }
        else { menuItem.state = .off }
        return true
    }
}

// MARK: Find's Use Selection to Find and Jump to Selection

extension CommandMenus {
    /// Edit's Find additions (Arc's Find menu). Use Selection to Find has no key (⌘E is Extensions here).
    static func findExtras() -> [BrowserCommand] {
        [
            BrowserCommand("Use Selection to Find", id: "edit.useSelectionForFind") { $0.useSelectionForFind() }
                .enabled { $0.canFindInView },
            BrowserCommand("Jump to Selection", "j", .command, id: "edit.jumpToSelection") { $0.jumpToSelection() }
                .enabled { $0.canFindInView },
        ]
    }
}

extension WindowController {
    /// A page or a note is on screen to find in.
    var canFindInView: Bool { shownNote != nil || shownTabID.flatMap { engineTab(for: $0) } != nil }

    /// The text selected in the page or note on screen (a Peek's page first), "" when there's none.
    func selectedText(_ done: @escaping (String) -> Void) {
        if peek == nil, let note = shownNote {
            let tv = note.view.textView
            return done((tv.string as NSString).substring(with: tv.selectedRange()))
        }
        guard let page = displayedLinkPage else { return done("") }
        page.evaluate("String(window.getSelection() || '')") { done(($0 as? String) ?? "") }
    }

    /// Arc's "Use Selection to Find": the find bar opens with the selected text and finds it.
    func useSelectionForFind() {
        selectedText { [weak self] text in
            guard let self else { return }
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return NSSound.beep() }
            self.showFind()
            guard let bar = self.findBar else { return }
            bar.field.stringValue = String(t.prefix(200))
            bar.find(forward: true)
        }
    }

    /// Arc's "Jump to Selection" (⌘J): the page or note scrolls the selection to the middle of the view.
    func jumpToSelection() {
        if peek == nil, let note = shownNote { return note.view.textView.centerSelectionInVisibleArea(nil) }
        guard let page = displayedLinkPage else { return NSSound.beep() }
        page.evaluate(Self.jumpToSelectionScript) { v in if (v as? Bool) != true { NSSound.beep() } }
    }

    /// Scrolls the page so the selection's first line is in the middle; false without a selection.
    static let jumpToSelectionScript = """
    (function(){var s=window.getSelection();if(!s||!s.rangeCount||s.isCollapsed)return false;
      var r=s.getRangeAt(0).getBoundingClientRect();if(!r||(r.width===0&&r.height===0))return false;
      window.scrollBy({top:r.top+r.height/2-window.innerHeight/2,left:0,behavior:'instant'});return true})()
    """
}

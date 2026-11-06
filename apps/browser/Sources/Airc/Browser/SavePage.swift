// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircKit
import UniformTypeIdentifiers
#if canImport(AircCore)
import AircCore
#endif

/// ⇧⌘S Save Page As… (SB-60: ⌘S is the sidebar, so Chrome's Save Page moved here). Airc's own save panel, as a sheet
/// on the window, with Chrome's three formats under the name: Web Page, Complete (the page and a `<name>_files` folder
/// of its resources), Web Page, HTML Only, and Web Page, Single File (MHTML). The engine writes the file to the place
/// chosen (AircTab -savePageTo:format:completion:, engine/PASS-APIS.md) and says how it ended; the page's profile counts
/// it as a download, so a private window's isn't remembered.
///
/// Where the engine can't save the page (the WebKit dev engine and WebKit pages, Chrome's own pages, a PDF, a framework
/// from before that API), Save Page As offers Print → Save as PDF, which every engine has, and says so.
enum PageSaveFormat: String, CaseIterable {
    case complete, htmlOnly, singleFile

    var title: String {
        switch self {
        case .complete: "Web Page, Complete"
        case .htmlOnly: "Web Page, HTML Only"
        case .singleFile: "Web Page, Single File"
        }
    }

    var fileExtension: String { self == .singleFile ? "mhtml" : "html" }

    var contentType: UTType { self == .singleFile ? UTType(filenameExtension: "mhtml") ?? .data : .html }

}

/// What Save Page As needs from an engine: Chromium's SavePackage (WebContents::SavePage) for a page, to the path and in
/// the format Airc chose, and how it ended. ChromiumEngine adopts it (below).
protocol EnginePageSaving: AnyObject {
    /// The page can be saved (WebContents::IsSavable, the download policy, no "save" content restriction).
    func canSavePage(_ tab: EngineTab) -> Bool
    /// `completion(nil)` once the file is written; otherwise "busy", "notSavable", "cancelled" or "failed:<reason>".
    func savePage(_ tab: EngineTab, to url: URL, format: PageSaveFormat, completion: @escaping (String?) -> Void)
}

enum SavePage {
    private static let formatKey = "AircSavePageFormat"

    /// ⇧⌘S for `page`, shown in `window`.
    static func offer(for page: EngineTab?, in window: NSWindow, toast: @escaping (String) -> Void) {
        guard let page, let url = page.url, !URLRules.isNewTab(url.absoluteString) else { return NSSound.beep() }
        let engine = (NSApp.delegate as? AppDelegate)?.engine
        if let saver = engine as? EnginePageSaving, saver.canSavePage(page) {
            return savePanel(page, saver: saver, window: window, toast: toast)
        }
        offerPDF(page, in: window, toast: toast)
    }

    /// Print → Save as PDF, with a note that says why.
    static func offerPDF(_ page: EngineTab, in window: NSWindow, toast: @escaping (String) -> Void) {
        let alert = NSAlert()
        let title = page.title.isEmpty ? URLRules.displayHost(page.url?.absoluteString ?? "") : page.title
        alert.messageText = "Save “\(title)” as a PDF?"
        alert.informativeText = "Airc can’t save this page as a web page file. You can keep it as a PDF instead: in the Print window that opens next, choose PDF ▸ Save as PDF at the bottom left."
        alert.addButton(withTitle: "Print…")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak page, weak window] r in
            guard r == .alertFirstButtonReturn, let page, let window else { return }
            if !page.printPage(from: window) { toast("Printing isn't available in this engine yet") }
        }
    }

    /// The page's title as a file name: no slashes or colons, at most 120 characters.
    static func suggestedName(for page: EngineTab) -> String {
        let raw = page.title.isEmpty ? URLRules.displayHost(page.url?.absoluteString ?? "") : page.title
        let cleaned = raw.components(separatedBy: CharacterSet(charactersIn: "/:\\\0")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((cleaned.isEmpty ? "Page" : cleaned).prefix(120))
    }

    /// Airc's own panel, once an engine can save to a path it chooses: the format under the name, as Chrome's.
    private static func savePanel(_ page: EngineTab, saver: EnginePageSaving, window: NSWindow, toast: @escaping (String) -> Void) {
        let panel = NSSavePanel()
        let base = suggestedName(for: page)
        var format = PageSaveFormat(rawValue: UserDefaults.standard.string(forKey: formatKey) ?? "") ?? .complete
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: PageSaveFormat.allCases.map(\.title))
        popup.selectItem(at: PageSaveFormat.allCases.firstIndex(of: format) ?? 0)
        let chooser = FormatChooser { i in
            format = PageSaveFormat.allCases[i]
            panel.allowedContentTypes = [format.contentType]
            panel.nameFieldStringValue = base + "." + format.fileExtension
        }
        popup.target = chooser
        popup.action = #selector(FormatChooser.changed(_:))
        let row = NSStackView(views: [NSTextField(labelWithString: "Format:"), popup])
        row.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        panel.accessoryView = row
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = base + "." + format.fileExtension
        panel.isExtensionHidden = false
        panel.beginSheetModal(for: window) { r in
            withExtendedLifetime(chooser) {}
            guard r == .OK, let url = panel.url else { return }
            UserDefaults.standard.set(format.rawValue, forKey: formatKey)
            saver.savePage(page, to: url, format: format) { error in toast(message(error, file: url.lastPathComponent)) }
        }
    }

    /// The toast after a save: the engine's nil, busy, notSavable, cancelled or failed:<reason>.
    static func message(_ error: String?, file: String) -> String {
        switch error {
        case nil: "Saved “\(file)”"
        case "busy": "This page is still being saved"
        case "cancelled": "Save cancelled"
        case "notSavable": "Airc can’t save this page"
        default: "Airc couldn’t save the page"
        }
    }

    private final class FormatChooser: NSObject {
        let onChange: (Int) -> Void
        init(_ onChange: @escaping (Int) -> Void) { self.onChange = onChange }
        @objc func changed(_ sender: NSPopUpButton) { onChange(sender.indexOfSelectedItem) }
    }
}

#if canImport(AircCore)
/// Engine pass "APIs" (engine/PASS-APIS.md). A framework from before it has neither call: then nothing is saved this
/// way and Save Page As offers the PDF.
extension ChromiumEngine: EnginePageSaving {
    private static let canSaveSelector = #selector(getter: AircTab.canSavePage)
    private static let saveSelector = #selector(AircTab.savePage(to:format:completion:))

    func canSavePage(_ tab: EngineTab) -> Bool {
        guard let t = core(of: tab), t.responds(to: Self.canSaveSelector), t.responds(to: Self.saveSelector) else { return false }
        return t.canSavePage
    }

    func savePage(_ tab: EngineTab, to url: URL, format: PageSaveFormat, completion: @escaping (String?) -> Void) {
        guard let t = core(of: tab), t.responds(to: Self.saveSelector) else { return completion("notSavable") }
        let f: AircSavePageFormat = switch format {
        case .complete: .complete
        case .htmlOnly: .html
        case .singleFile: .mhtml
        }
        t.savePage(to: url.path, format: f, completion: completion)
    }
}
#endif

extension WindowController {
    /// ⇧⌘S.
    func savePage() {
        SavePage.offer(for: shownTabID.flatMap { engineTab(for: $0) }, in: window, toast: { [weak self] in self?.showToast($0) })
    }
}

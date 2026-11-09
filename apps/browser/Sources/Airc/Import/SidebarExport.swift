// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircKit
import UniformTypeIdentifiers

/// P04 (L07): Export Space… and Export All Spaces…: a file another app or browser can read, Markdown or HTML in the
/// bookmarks format every browser imports. Names, folders, order and addresses as the sidebar has them, without user
/// names and passwords in links, data:/blob:/javascript: links or notes' text (AircKit's `SidebarExport`). Favorites
/// go with Export All Spaces, once per profile. Private windows' tabs were never in the store; blank windows' Spaces
/// aren't exported.
extension WindowController {
    /// The file's text for one Space (nil: every Space, with the profiles' Favorites).
    func exportDocument(_ spaceID: String?, format: SidebarExportFormat) -> String? {
        let spaces = spaceID.map { store.exportSpace($0).map { [$0] } ?? [] } ?? store.exportAllSpaces()
        guard !spaces.isEmpty else { return nil }
        let favorites = spaceID == nil ? store.exportFavorites() : []
        switch format {
        case .markdown: return SidebarExport.markdown(spaces: spaces, favorites: favorites)
        case .html: return SidebarExport.html(spaces: spaces, favorites: favorites, title: spaceID == nil ? "Airc" : spaces[0].name)
        }
    }

    /// The Space menu's Export Space… (`spaceID`) and File › Export All Spaces… (nil): a save panel with the format.
    func exportSpace(_ spaceID: String?) {
        let name = spaceID.flatMap { store.space($0)?.name } ?? "Airc Spaces"
        let panel = NSSavePanel()
        panel.title = spaceID == nil ? "Export All Spaces" : "Export Space"
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = SidebarExportFile.safeName(name)
        let picker = SidebarExportFormatPicker(panel: panel, baseName: SidebarExportFile.safeName(name))
        panel.accessoryView = picker.view
        picker.apply(.markdown)
        let done: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] r in
            guard r == .OK, let self, let url = panel?.url else { return }
            do {
                try SidebarExportFile.write(self, spaceID: spaceID, format: picker.format, to: url)
                self.showToast("Exported \(spaceID == nil ? "all Spaces" : name) to \(url.lastPathComponent)")
            } catch {
                self.showToast("Couldn't export: \(error.localizedDescription)")
            }
        }
        SidebarExportFile.shownPanel = panel
        if window.attachedSheet == nil { panel.beginSheetModal(for: window, completionHandler: done) } else { done(panel.runModal()) }
    }
}

enum SidebarExportFile {
    /// The save panel up now (checks cancel it).
    static weak var shownPanel: NSSavePanel?

    static func write(_ c: WindowController, spaceID: String?, format: SidebarExportFormat, to url: URL) throws {
        guard let text = c.exportDocument(spaceID, format: format) else { throw CocoaError(.fileNoSuchFile) }
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    /// A Space's name as a file name (no slashes or colons; never empty or hidden).
    static func safeName(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        return cleaned.isEmpty ? "Space" : cleaned
    }
}

/// The save panel's Format pop-up: Markdown or HTML (bookmarks); the file name's extension and type follow it.
private final class SidebarExportFormatPicker: NSObject {
    let view: NSView
    private let popup = NSPopUpButton()
    private weak var panel: NSSavePanel?
    private let baseName: String
    private(set) var format = SidebarExportFormat.markdown

    init(panel: NSSavePanel, baseName: String) {
        self.panel = panel
        self.baseName = baseName
        view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        super.init()
        let label = NSTextField(labelWithString: "Format:")
        label.frame = NSRect(x: 20, y: 11, width: 60, height: 17)
        popup.frame = NSRect(x: 84, y: 6, width: 200, height: 26)
        popup.addItems(withTitles: ["Markdown", "HTML (bookmarks)"])
        popup.target = self
        popup.action = #selector(changed)
        view.addSubview(label)
        view.addSubview(popup)
        objc_setAssociatedObject(panel, &Self.key, self, .OBJC_ASSOCIATION_RETAIN)
    }

    private static var key = 0

    @objc private func changed() { apply(popup.indexOfSelectedItem == 1 ? .html : .markdown) }

    func apply(_ f: SidebarExportFormat) {
        format = f
        popup.selectItem(at: f == .html ? 1 : 0)
        panel?.allowedContentTypes = [f == .html ? .html : UTType(filenameExtension: "md") ?? .plainText]
        let current = panel?.nameFieldStringValue ?? ""
        let stem = current.isEmpty ? baseName : (current as NSString).deletingPathExtension
        panel?.nameFieldStringValue = stem + "." + f.fileExtension
    }
}

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import AircKit
import SwiftUI

/// One extension of the current Space's profile and its toolbar action on the shown page (engine/PASS7.md).
struct ExtensionAction: Identifiable, Equatable {
    let id: String
    let name: String
    /// The action's title for this page (its tooltip and accessibility label), else the extension's name.
    var title: String
    var icon: NSImage?
    var badge: String
    var badgeColor: NSColor?
    var badgeTextColor: NSColor?
    /// Turned on in chrome://extensions.
    var isEnabled: Bool
    /// The action runs on this page (Chrome greys it out on pages extensions can't touch, like the Web Store).
    var isActive: Bool

    static func color(_ hex: Any?) -> NSColor? {
        guard let s = hex as? String, let c = RGBA(hex: s.hasPrefix("#") ? String(s.dropFirst()) : s) else { return nil }
        return c.nsColor
    }
}

/// Extension toolbar actions (engine/PASS7.md "Extension UI request"). Pinned, enabled actions draw in the URL field
/// while the sidebar is hovered, with their badge; a click presents the action's popup anchored on its button (the core
/// performs the action itself, so it is never executed first). ⌘E and the puzzle button list every extension of this
/// Space's profile with a pin toggle, then Manage Extensions… and Chrome Web Store…. Pins are per profile, on this Mac.
/// Everything is queried when it's about to show (hover, the list opening, after a click); nothing polls.
extension WindowController {
    var currentProfileID: String { store.profile(ofSpace: currentSpaceID).id }

    /// The current profile's extensions with their action state on the shown page (never a page of another window
    /// or profile).
    func extensionActions() -> [ExtensionAction] {
        guard let engine = app?.engine, let profile = profiles.engineProfile(for: currentProfileID) else { return [] }
        let installed = engine.installedExtensions(for: profile)
        guard !installed.isEmpty else { return [] }
        let ids = installed.compactMap { $0["id"] as? String }
        let page = shownTabID.flatMap { id in store.tab(id)?.profileID == currentProfileID ? engineTab(for: id) : nil }
        let states = page.map { engine.extensionActions(ids, for: $0) } ?? [:]
        return installed.compactMap { e in
            guard let id = e["id"] as? String else { return nil }
            let s = states[id] ?? [:]
            let name = e["name"] as? String ?? id
            let title = (s["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name
            return ExtensionAction(id: id, name: name, title: title, icon: engine.extensionActionIcon(s),
                                   badge: s["badgeText"] as? String ?? "", badgeColor: ExtensionAction.color(s["badgeColor"]),
                                   badgeTextColor: ExtensionAction.color(s["badgeTextColor"]),
                                   isEnabled: e["enabled"] as? Bool ?? true, isActive: s["enabled"] as? Bool ?? (page != nil))
        }
    }

    var pinnedExtensionIDs: [String] { app?.settings.values.pinnedExtensions[currentProfileID] ?? [] }

    func setExtension(_ id: String, pinned: Bool) {
        guard let settings = app?.settings else { return }
        var ids = settings.values.pinnedExtensions[currentProfileID] ?? []
        ids.removeAll { $0 == id }
        if pinned { ids.append(id) }
        settings.values.pinnedExtensions[currentProfileID] = ids
        refreshExtensionButtons()
    }

    /// The URL field's pinned actions, fresh from the engine.
    func refreshExtensionButtons() {
        guard let field = pageView(for: currentSpaceID)?.urlField else { return }
        let pinned = pinnedExtensionIDs
        let all = extensionActions()
        field.setExtensions(pinned.compactMap { id in all.first { $0.id == id && $0.isEnabled } })
    }

    /// Runs an action: its popup opens anchored on `rect` of `view` (inside this window). False: no popup (an action
    /// without one has run).
    @discardableResult
    func runExtension(_ id: String, anchor view: NSView, rect: NSRect) -> Bool {
        guard let engine = app?.engine, let tabID = shownTabID, store.tab(tabID)?.profileID == currentProfileID,
              let page = engineTab(for: tabID) else {
            showToast("Open a page to use this extension")
            return false
        }
        let shown = engine.presentExtensionAction(id, for: page, anchorRect: rect.intersection(view.bounds), in: view)
        // The action may change its badge.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.refreshExtensionButtons() }
        return shown
    }

    func closeExtensionPopup() { app?.engine.closeExtensionPopup(in: engineWindow) }

    /// ⌘E and the puzzle button: every extension of this profile, with pin toggles, under the URL field.
    func showExtensions() {
        guard let field = pageView(for: currentSpaceID)?.urlField, field.window != nil, !sidebarHidden else {
            return showExtensionsMenu()
        }
        extensionsPopover?.close()
        let ui = currentPalette.resolved
        let actions = extensionActions()
        let p = NSPopover()
        p.behavior = .transient
        p.animates = true
        p.appearance = NSAppearance(named: ui.isDark ? .darkAqua : .aqua)
        let list = ExtensionsList(actions: actions, pinned: Set(pinnedExtensionIDs),
                                  onRun: { [weak self, weak p] id in
                                      p?.close()
                                      guard let self, let field = self.pageView(for: self.currentSpaceID)?.urlField else { return }
                                      self.runExtension(id, anchor: field, rect: field.extensionAnchor(for: id))
                                  },
                                  onPin: { [weak self] id, on in self?.setExtension(id, pinned: on) },
                                  onManage: { [weak self, weak p] in p?.close(); self?.openExtensionsPage() },
                                  onStore: { [weak self, weak p] in
                                      p?.close()
                                      self?.navigate(to: URL(string: "https://chromewebstore.google.com/")!, newTab: true)
                                  })
        let host = NSHostingController(rootView: list.aircTheme(DesignTheme.default.resolved(systemIsDark: ui.isDark)))
        p.contentViewController = host
        p.contentSize = host.view.fittingSize
        p.show(relativeTo: field.bounds, of: field, preferredEdge: .maxY)
        extensionsPopover = p
    }

    /// With the sidebar hidden: the same list as a menu at the window's top left.
    private func showExtensionsMenu() {
        let menu = NSMenu()
        let actions = extensionActions()
        if actions.isEmpty { menu.addItem(withTitle: "No extensions in this profile", action: nil, keyEquivalent: "").isEnabled = false }
        let pinned = Set(pinnedExtensionIDs)
        for a in actions {
            let item = menu.add(a.title + (a.badge.isEmpty ? "" : "  " + a.badge)) { [weak self] in
                guard let self else { return }
                self.runExtension(a.id, anchor: self.card, rect: NSRect(x: 8, y: self.card.bounds.maxY - 8, width: 1, height: 1))
            }
            item.image = a.icon.map { img in NSImage(size: NSSize(width: 16, height: 16), flipped: false) { r in img.draw(in: r); return true } }
            item.isEnabled = a.isEnabled
            let pin = menu.add(pinned.contains(a.id) ? "Unpin \(a.name)" : "Pin \(a.name) to the URL field") { [weak self] in
                self?.setExtension(a.id, pinned: !pinned.contains(a.id))
            }
            pin.isAlternate = true
            pin.keyEquivalentModifierMask = .option
        }
        menu.addItem(.separator())
        menu.add("Manage Extensions…") { [weak self] in self?.openExtensionsPage() }
        menu.add("Chrome Web Store…") { [weak self] in self?.navigate(to: URL(string: "https://chromewebstore.google.com/")!, newTab: true) }
        menu.popUp(positioning: nil, at: NSPoint(x: 12, y: AircMetrics.Sidebar.urlFieldTop), in: root)
    }

    func openExtensionsPage() { navigate(to: URL(string: "chrome://extensions")!, newTab: true) }

    /// Web Store installs are reviewed in the key browser window (the engine refuses them without a handler).
    func setUpExtensionInstalls() {
        #if canImport(AircCore)
        guard app?.engine is ChromiumEngine else { return }
        ChromiumRuntime.extensionInstallHandler = { [weak app = self.app, weak self] prompt, resolve in
            guard let c = app?.controller ?? self else { return resolve(false) }
            c.reviewExtensionInstall(prompt, resolve: resolve)
        }
        ChromiumRuntime.extensionInstallFailedHandler = { [weak app = self.app, weak self] message in
            (app?.controller ?? self)?.showToast("The extension couldn't be added: \(message)")
        }
        #endif
    }

    /// "Add to Chrome" in the Web Store: the extension, what it can do and the profile it goes to, on Airc's review
    /// card (ExtensionInstallSheet.swift); Add Extension or Cancel. Scripted runs (`--script extension`) accept only
    /// uBlock Origin Lite, the test extension.
    func reviewExtensionInstall(_ prompt: [String: Any], resolve: @escaping (Bool) -> Void) {
        let name = prompt["name"] as? String ?? "this extension"
        let permissions = prompt["permissions"] as? [String] ?? []
        let icon = app?.engine.extensionActionIcon(["icon": prompt["icon"] ?? ""])
        presentExtensionReview(name: name, icon: icon, permissions: permissions, resolve: resolve)
    }
}

/// The ⌘E list (design: a calm list on `surface`, like the command bar's rows): icon, title and badge run the action;
/// the switch pins it to the URL field.
private struct ExtensionsList: View {
    let actions: [ExtensionAction]
    @State var pinned: Set<String>
    let onRun: (String) -> Void
    let onPin: (String, Bool) -> Void
    let onManage: () -> Void
    let onStore: () -> Void
    @Environment(\.aircTheme) private var ui

    private func footerRow(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(ui.surfaceTextSecondary.color)
                    .frame(width: 20)
                Text(title).aircFont(AircFont.body).foregroundStyle(ui.surfaceText.color)
                Spacer(minLength: 0)
            }
            .frame(height: 28)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Extensions").aircFont(AircFont.caption).foregroundStyle(ui.surfaceTextTertiary.color)
                .padding(.horizontal, 8).padding(.bottom, 4)
            if actions.isEmpty {
                Text("No extensions in this profile yet.").aircFont(AircFont.body).foregroundStyle(ui.surfaceTextSecondary.color)
                    .padding(.horizontal, 8).padding(.vertical, 6)
            }
            ForEach(actions) { a in
                HStack(spacing: 8) {
                    Button { onRun(a.id) } label: {
                        HStack(spacing: 8) {
                            ExtensionIcon(icon: a.icon, badge: a.badge, badgeColor: a.badgeColor, badgeTextColor: a.badgeTextColor)
                            Text(a.title).aircFont(AircFont.body).foregroundStyle(ui.surfaceText.color).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!a.isEnabled)
                    .opacity(a.isEnabled && a.isActive ? 1 : 0.45)
                    .help(a.isEnabled ? a.title : "\(a.name) is turned off")
                    AircSwitch(isOn: Binding(get: { pinned.contains(a.id) }, set: { on in
                        if on { pinned.insert(a.id) } else { pinned.remove(a.id) }
                        onPin(a.id, on)
                    }))
                    .help("Show in the URL field")
                    .accessibilityLabel("Pin \(a.name)")
                }
                .frame(height: 32)
                .padding(.horizontal, 8)
            }
            Rectangle().fill(ui.surfaceBorder.color).frame(height: 0.5).padding(.vertical, 6)
            footerRow("Manage Extensions…", symbol: "gearshape", action: onManage)
            footerRow("Chrome Web Store…", symbol: "bag", action: onStore)
        }
        .padding(10)
        .frame(width: 300)
        .background(ui.surface.color)
    }
}

/// An action's 16 pt icon with its badge (the extension's colours, Chrome's 8.5 pt pill at the bottom right).
struct ExtensionIcon: View {
    let icon: NSImage?
    let badge: String
    let badgeColor: NSColor?
    let badgeTextColor: NSColor?
    @Environment(\.aircTheme) private var ui

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let icon { Image(nsImage: icon).resizable().interpolation(.high) }
                else { Image(systemName: "puzzlepiece.extension").foregroundStyle(ui.surfaceTextSecondary.color) }
            }
            .frame(width: 16, height: 16)
            if !badge.isEmpty {
                Text(badge).font(.system(size: 8.5, weight: .semibold)).lineLimit(1)
                    .foregroundStyle(Color(nsColor: badgeTextColor ?? .white))
                    .padding(.horizontal, 3).frame(height: 11)
                    .background(Capsule().fill(Color(nsColor: badgeColor ?? NSColor(red: 0.36, green: 0.36, blue: 0.40, alpha: 1))))
                    .offset(x: 6, y: 4)
            }
        }
        .frame(width: 20, height: 20)
    }
}

/// A pinned action in the URL field: the icon on a hover plate, the badge drawn over its corner.
final class ExtensionButton: NSView {
    let id: String
    var action: ((ExtensionButton) -> Void)?
    private let image = NSImageView()
    private let badge = CATextLayer()
    private let badgePlate = CALayer()
    private var hovered = false { didSet { layer?.backgroundColor = hovered ? hoverFill.cgColor : nil } }
    var hoverFill: NSColor = .clear

    init(id: String) {
        self.id = id
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        image.imageScaling = .scaleProportionallyUpOrDown
        addSubview(image)
        badgePlate.cornerCurve = .continuous
        layer?.addSublayer(badgePlate)
        badge.alignmentMode = .center
        badge.fontSize = 8.5
        badge.font = NSFont.systemFont(ofSize: 8.5, weight: .semibold)
        badge.contentsScale = 2
        badgePlate.addSublayer(badge)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func configure(_ a: ExtensionAction, palette: Palette) {
        image.image = a.icon ?? Symbols.image("puzzlepiece.extension", size: 13, weight: .medium)
        image.contentTintColor = a.icon == nil ? palette.glyph : nil
        toolTip = a.title
        setAccessibilityLabel(a.title)
        hoverFill = palette.hover
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        badgePlate.isHidden = a.badge.isEmpty
        badge.string = a.badge
        badge.foregroundColor = (a.badgeTextColor ?? .white).cgColor
        badgePlate.backgroundColor = (a.badgeColor ?? NSColor(red: 0.36, green: 0.36, blue: 0.40, alpha: 1)).cgColor
        CATransaction.commit()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let s: CGFloat = 16
        image.frame = NSRect(x: (bounds.width - s) / 2, y: (bounds.height - s) / 2, width: s, height: s)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let text = (badge.string as? String) ?? ""
        let w = max(11, ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 8.5, weight: .semibold)]).width) + 6)
        let flipped = isFlipped
        badgePlate.frame = NSRect(x: min(bounds.width - w, image.frame.maxX - w + 6), y: flipped ? image.frame.maxY - 7 : image.frame.minY - 4,
                                  width: w, height: 11)
        badgePlate.cornerRadius = 5.5
        badge.frame = badgePlate.bounds.offsetBy(dx: 0, dy: -0.5)
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { action?(self) }
}

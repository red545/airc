// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import AircKit
import SwiftUI

/// "Add to Chrome" in the Web Store: the review card, with the information Chrome's install dialog gives (the
/// extension's name and icon and what it will be able to do), plus which profile it goes to. Same treatment as the
/// Create Profile card (design.md §7 "Profiles"): over the page card on a scrim, the sidebar untouched.
final class ExtensionInstallModel: ObservableObject {
    let name: String
    let icon: NSImage?
    let permissions: [String]
    let profileName: String
    let ui: ResolvedTheme
    var onAnswer: ((Bool) -> Void)?

    init(name: String, icon: NSImage?, permissions: [String], profileName: String, ui: ResolvedTheme) {
        self.name = name
        self.icon = icon
        self.permissions = permissions
        self.profileName = profileName
        self.ui = ui
    }

    var title: String { "Add “\(name)”?" }
}

struct ExtensionInstallCard: View {
    @ObservedObject var model: ExtensionInstallModel
    private var ui: ResolvedTheme { model.ui }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                icon
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.title)
                        .aircFont(AircFont.title3)
                        .foregroundStyle(ui.surfaceText.color)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Only in the \(model.profileName) profile")
                        .aircFont(AircFont.callout)
                        .foregroundStyle(ui.surfaceTextSecondary.color)
                }
                Spacer(minLength: 0)
            }
            permissions
                .padding(.top, 18)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel") { model.onAnswer?(false) }
                    .buttonStyle(.airc(.secondary, size: .large))
                    .keyboardShortcut(.cancelAction)
                    .testAnchor("extension.cancel")
                Button("Add Extension") { model.onAnswer?(true) }
                    .buttonStyle(.airc(.primary, size: .large))
                    .keyboardShortcut(.defaultAction)
                    .testAnchor("extension.add")
            }
            .padding(.top, 22)
        }
        .padding(24)
        .frame(width: 420)
        .testAnchorRoot()
        .aircTheme(ui)
    }

    /// The extension's own icon on a `tileFill` plate (a puzzle glyph while it has none).
    private var icon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(ui.tileFill.color)
            if let img = model.icon {
                Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(width: 32, height: 32)
            } else {
                Image(systemName: "puzzlepiece.extension").font(.system(size: 20, weight: .medium))
                    .foregroundStyle(ui.surfaceTextSecondary.color)
            }
        }
        .frame(width: 48, height: 48)
    }

    @ViewBuilder private var permissions: some View {
        if model.permissions.isEmpty {
            Text("It doesn’t ask for any special permissions.")
                .aircFont(AircFont.body)
                .foregroundStyle(ui.surfaceTextSecondary.color)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("It can:")
                    .aircFont(AircFont.body.weight(.medium))
                    .foregroundStyle(ui.surfaceText.color)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(model.permissions.prefix(12).enumerated()), id: \.offset) { _, p in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle().fill(ui.surfaceTextSecondary.color).frame(width: 4, height: 4).offset(y: -2)
                            Text(p)
                                .aircFont(AircFont.body)
                                .foregroundStyle(ui.surfaceText.color)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(ui.fieldFill.color))
            }
        }
    }
}

/// A scrim over the page card with the review card centred on it, slightly above centre; a click on the scrim is
/// Cancel, like Esc.
final class ExtensionInstallPanelHost: NSView {
    let model: ExtensionInstallModel
    private let scrim = NSView()
    private let card = NSView()
    private let host: AircFirstClickHostingView<ExtensionInstallCard>

    init(model: ExtensionInstallModel, palette: Palette) {
        self.model = model
        host = AircFirstClickHostingView(rootView: ExtensionInstallCard(model: model))
        super.init(frame: .zero)
        wantsLayer = true
        scrim.wantsLayer = true
        scrim.layer?.backgroundColor = NSColor.black.withAlphaComponent(palette.isDark ? 0.40 : 0.22).cgColor
        scrim.layer?.cornerRadius = AircMetrics.Window.cardRadius
        addSubview(scrim)
        card.wantsLayer = true
        card.layer?.cornerRadius = 18
        card.layer?.cornerCurve = .continuous
        card.layer?.backgroundColor = model.ui.surface.nsColor.cgColor
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = model.ui.surfaceBorder.nsColor.cgColor
        card.layer?.applyAircShadow(.panel)
        addSubview(card)
        card.addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    var hostingView: NSView { host }

    func layoutIn(page: NSRect) {
        frame = page
        scrim.frame = bounds
        let size = host.fittingSize
        card.frame = NSRect(x: ((bounds.width - size.width) / 2).rounded(), y: max(16, ((bounds.height - size.height) / 2 - 24).rounded()),
                            width: size.width, height: size.height)
        host.frame = card.bounds
    }

    override func mouseDown(with event: NSEvent) {
        if !card.frame.contains(convert(event.locationInWindow, from: nil)) { model.onAnswer?(false) }
    }

    /// Drops in 24 pt and fades in on the dialog curve; leaves by fading.
    func present() {
        guard let layer = card.layer else { return }
        let curve = AircCurve.dialog
        let drop = CABasicAnimation(keyPath: "transform.translation.y")
        drop.fromValue = -24
        drop.toValue = 0
        drop.duration = curve.duration
        drop.timingFunction = curve.timingFunction
        layer.add(drop, forKey: "drop")
        self.layer?.fade(from: 0, to: 1, duration: 0.15)
    }
}

extension WindowController {
    /// The review card for a Web Store install (replaces the stock alert). `resolve` gets the answer once.
    func presentExtensionReview(name: String, icon: NSImage?, permissions: [String], resolve: @escaping (Bool) -> Void) {
        closeExtensionReview(answer: false)
        closeCommandBar()
        let pal = currentPalette
        let model = ExtensionInstallModel(name: name, icon: icon, permissions: permissions,
                                          profileName: store.profile(ofSpace: currentSpaceID).name, ui: pal.resolved)
        var answered = false
        model.onAnswer = { [weak self] yes in
            guard !answered else { return }
            answered = true
            self?.closeExtensionReview(answer: nil)
            resolve(yes)
            if yes {
                Telemetry.shared.record(.featureUsed(.extensionInstalled))
                self?.showToast("\(name) added. Pin it to the URL field with ⌘E.")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.refreshExtensionButtons() }
            }
        }
        let panel = ExtensionInstallPanelHost(model: model, palette: pal)
        pendingExtensionReview = panel
        root.addSubview(panel, positioned: .below, relativeTo: toast)
        panel.layoutIn(page: card.frame)
        panel.present()
        window.makeFirstResponder(panel.hostingView)
    }

    /// `answer`: the reply to give a review still open (nil: it's being answered already).
    func closeExtensionReview(answer: Bool?) {
        guard let p = pendingExtensionReview else { return }
        pendingExtensionReview = nil
        if let answer { p.model.onAnswer?(answer) }
        p.layer?.fade(from: 1, to: 0, duration: 0.12)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { p.removeFromSuperview() }
    }
}

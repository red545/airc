// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import SwiftUI
import AircDesign
import AircKit
import QuartzCore

/// The full-bleed window background (WIN-1): one AircDesign SpaceBackgroundView (Arc's shader + grain).
///
/// Speed (§2.12, a Space switch under 2 ms of main-thread work): every Space's colour layer is rendered ahead, off the
/// main thread, into `AircBackgroundCache` at the window's size (`prewarm`, at idle), so a switch only swaps a cached
/// image. A swipe between two Spaces blends in the same view (`setBlend`), so no second background is stacked. One
/// blur sits under it (`drawsMaterial = false` on the view).
final class ThemeBackgroundView: NSView {
    private let material = AircMaterialView()
    private let base: SpaceBackgroundView

    var translucency: AircTranslucency = .off {
        didSet {
            guard translucency != oldValue else { return }
            material.isHidden = translucency == .off
            base.translucency = translucency
        }
    }

    init(theme: ResolvedTheme) {
        base = SpaceBackgroundView(theme: theme)
        super.init(frame: .zero)
        wantsLayer = true
        material.isHidden = true
        material.autoresizingMask = [.width, .height]
        addSubview(material)
        base.drawsMaterial = false
        base.autoresizingMask = [.width, .height]
        addSubview(base)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { true }

    var current: ResolvedTheme { base.theme }

    /// Renders every theme the window can switch to, at its current size, off the main thread. Call at idle.
    func prewarm(_ themes: [ResolvedTheme]) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        AircBackgroundCache.shared.prerender(themes, size: bounds.size)
    }

    /// Shows `from` blended toward `to` by `t` (0 = only `from`). Used every frame of a swipe.
    func show(_ from: ResolvedTheme, _ to: ResolvedTheme? = nil, t: Double = 0) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        base.setTheme(from, animated: false)
        if let to, to != from, t > 0.0001 { base.setBlend(to, fraction: t) } else { base.setBlend(nil, fraction: 0) }
        CATransaction.commit()
    }

    /// Clicks and keys to a neighbouring Space: the whole window changes colour at once (Arc's τ ≈ 30 ms), as the
    /// view's own 90 ms cross-fade between two cached colour layers.
    func crossfade(to theme: ResolvedTheme) {
        Perf.time("bg.blend") { base.setBlend(nil, fraction: 0) }
        Perf.time("bg.setTheme") { base.setTheme(theme, animated: true) }
    }

    override func layout() {
        super.layout()
        material.frame = bounds
        base.frame = bounds
    }
}

/// The engine's page container (both engines). The page is never a window-drag area: not for a press on the window
/// background, and not where the card reaches into the titlebar band at the window's top (the card starts 10 pt down;
/// the band is ~28 pt), where the window server drags the window unless a view claims the area. Chromium's page view
/// answers `mouseDownCanMoveWindow` with YES and, drawing out of process, looks transparent to AppKit; Chrome claims
/// its pages the same way, in BridgedContentView.
final class PageHostView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    /// AppKit's (private) question: which part of this view the window server mustn't drag the window from when it
    /// lies in the titlebar.
    @objc func _opaqueRectForWindowMoveWhenInTitlebar() -> NSRect { bounds }
}

/// A hosting view that, hidden, takes no clicks. NSHostingView's own hitTest answers for its bounds even while it is
/// hidden, so the empty-Space view (built ahead at idle and kept hidden above the page) took every click meant for the
/// page under it, on both engines (owner P0, 2026-11-05).
final class HiddenSafeHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { isHidden ? nil : super.hitTest(point) }
}

/// The page sits in a rounded card inset 10 pt (WIN-1). The engine's host view goes inside.
final class PageCardView: NSView {
    /// What an empty Space shows (design.md §7 "Empty Space").
    struct EmptySpace: Equatable {
        var emoji: String?
        var name: String
        /// Set only while several profiles are in use.
        var profile: AircProfileIdentity?
    }

    /// The shadow behind the clipped page and the hairline above it (design.md §7 "Page card edge", visual review #15).
    private let edge = AircPageCardView(theme: DesignTheme.default.resolved(systemIsDark: false))
    private let content = NSView()
    private var emptyView: HiddenSafeHostingView<AnyView>?
    private(set) var hostView: NSView?
    var palette: Palette? { didSet { if palette != oldValue { applyPalette() } } }
    /// The SwiftUI view only re-renders while it shows (a Space switch sets this for every Space; rendering the hidden
    /// view cost ~3 ms of each switch, §2.12); a stale one catches up when it's shown.
    var emptySpace = EmptySpace(emoji: nil, name: "") {
        didSet { if emptySpace != oldValue { emptyViewStale = true; if showsEmptyState { updateEmptyView() } } }
    }
    private var emptyViewStale = true
    /// The ⌘ T hint as a button.
    var onNewTab: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        edge.frame = bounds
        edge.autoresizingMask = [.width, .height]
        addSubview(edge)
        edge.contentView = content
    }

    required init?(coder: NSCoder) { fatalError() }

    func embed(_ host: NSView) {
        hostView = host
        host.frame = content.bounds
        host.autoresizingMask = [.width, .height]
        content.addSubview(host, positioned: .below, relativeTo: nil)
    }

    var showsEmptyState = false {
        didSet {
            guard showsEmptyState != oldValue else { return }
            if showsEmptyState, emptyViewStale || emptyView == nil { updateEmptyView() }
            emptyView?.isHidden = !showsEmptyState
        }
    }

    /// The New Space card knows the Space it will make: its empty view is rendered now, hidden, so Create only has to
    /// show it (SwiftUI's render was ~4 ms of the New Space frame, §2.12). Not while the card shows the current Space's.
    func prepareEmptySpace(_ e: EmptySpace) {
        guard !showsEmptyState else { return }
        if e != emptySpace || emptyViewStale || emptyView == nil {
            emptySpace = e
            updateEmptyView()
            emptyView?.isHidden = true
        }
    }

    /// Builds the empty-Space view ahead, hidden, so the first empty Space doesn't pay for a SwiftUI host.
    func prewarmEmptyView() {
        guard emptyView == nil else { return }
        updateEmptyView()
        emptyView?.isHidden = !showsEmptyState
    }

    private func updateEmptyView() {
        guard let palette else { return }
        emptyViewStale = false
        let e = emptySpace
        let root = AnyView(AircEmptySpaceView(emoji: e.emoji, name: e.name, profile: e.profile,
                                              onNewTab: { [weak self] in self?.onNewTab?() })
            .aircTheme(palette.resolved))
        if let emptyView {
            emptyView.rootView = root
        } else {
            let v = HiddenSafeHostingView(rootView: root)
            v.frame = content.bounds
            v.autoresizingMask = [.width, .height]
            v.isHidden = !showsEmptyState
            content.addSubview(v)
            emptyView = v
        }
    }

    private func applyPalette() {
        guard let p = palette else { return }
        edge.theme = p.resolved
        emptyViewStale = true
        if emptyView != nil, showsEmptyState { updateEmptyView() }
    }
}

/// "Copied Current URL", "Space deleted! Use ⌘Z to undo." (Arc ref §6.1 toast motion).
final class ToastView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?
    /// What it says while it shows, else nil (the real-event checks read it).
    var shownText: String? { isHidden ? nil : label.stringValue }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = AircRadius.toast
        layer?.cornerCurve = .continuous
        layer?.apply(.toast)
        label.font = AircFont.body.weight(.medium).appFont
        label.alignment = .center
        addSubview(label)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ text: String, palette: Palette, in container: NSRect, duration: Double = AircMetrics.Toast.defaultDuration) {
        label.stringValue = text
        label.textColor = palette.panelText
        layer?.backgroundColor = palette.panelBackground.cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = palette.panelBorder.cgColor
        label.sizeToFit()
        let h = AircMetrics.Toast.height
        let w = label.frame.width + 2 * AircSpacing.l
        frame = NSRect(x: container.midX - w / 2, y: container.minY + AircMetrics.Toast.topInset, width: w, height: h)
        label.frame = NSRect(x: AircSpacing.l, y: (h - label.frame.height) / 2, width: label.frame.width, height: label.frame.height)
        isHidden = false
        guard let layer else { return }
        // In: from 0.7 scale on Arc's pop spring, fading in.
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: frame.midX, y: frame.midY)
        layer.add(AircSpring.pop.caAnimation(keyPath: "transform.scale", from: 0.7, to: 1), forKey: "in")
        layer.fade(from: 0, to: 1, duration: AircCurve.previewIn.duration)
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.layer?.fade(from: 1, to: 0, duration: AircCurve.toastOut.duration)
            DispatchQueue.main.asyncAfter(deadline: .now() + AircCurve.toastOut.duration) { self.isHidden = true }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}

/// A view whose empty areas drag the window (Arc: empty sidebar space and margins move it).
class PassthroughView: NSView {
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
}

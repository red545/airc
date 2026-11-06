// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import AircKit

// What the person sees of protected media (docs/user/protected-media.md): once per service, a note over the page that
// it plays with Safari's engine, with Why? (Site Controls says why and has the switch) and ✕. It has no timer: only
// its ✕ closes it for good, so Airc knows it was seen. One left open comes back the next session.

/// "Spotify plays with Safari's engine"  Why?  ✕
final class ProtectedMediaToastView: NSView {
    let service: String
    private let label = NSTextField(labelWithString: "")
    private let why = NSButton(title: "Why?", target: nil, action: nil)
    private let close = GlyphButton(symbol: "xmark", size: 10)
    var onWhy: (() -> Void)?
    var onClose: (() -> Void)?
    private static let closeSize: CGFloat = 24
    /// Right of the ✕: its plate keeps the toast's rounded end.
    private static let endInset: CGFloat = 6

    init(service: String, palette: Palette) {
        self.service = service
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = AircRadius.toast
        layer?.cornerCurve = .continuous
        layer?.apply(.toast)
        label.stringValue = "\(service) plays with Safari's engine"
        label.font = AircFont.body.weight(.medium).appFont
        label.lineBreakMode = .byTruncatingTail
        why.isBordered = false
        why.target = self
        why.action = #selector(whyPressed)
        why.setAccessibilityLabel("Why does \(service) play with Safari's engine?")
        close.toolTip = "Don't show again"
        close.plateRadius = 12
        close.action = { [weak self] in self?.onClose?() }
        close.setAccessibilityLabel("Close")
        for v in [label, why, close] as [NSView] { addSubview(v) }
        apply(palette)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func apply(_ palette: Palette) {
        layer?.backgroundColor = palette.panelBackground.cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = palette.panelBorder.cgColor
        label.textColor = palette.panelText
        why.attributedTitle = NSAttributedString(string: "Why?", attributes: [
            .font: AircFont.body.weight(.semibold).appFont, .foregroundColor: palette.panelText,
            .underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: palette.panelSecondary,
        ])
        close.tint = palette.panelSecondary
        close.hoverFill = palette.panelSelection
    }

    /// Its size for its text: label, Why? and the ✕, on one line.
    var fittingWidth: CGFloat {
        label.sizeToFit()
        why.sizeToFit()
        return ceil(AircSpacing.l + label.frame.width + AircSpacing.s + why.frame.width + AircSpacing.xs + Self.closeSize + Self.endInset)
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        label.sizeToFit()
        why.sizeToFit()
        let c = Self.closeSize
        close.frame = NSRect(x: bounds.width - Self.endInset - c, y: (h - c) / 2, width: c, height: c)
        why.frame = NSRect(x: close.frame.minX - AircSpacing.xs - why.frame.width, y: (h - why.frame.height) / 2,
                           width: why.frame.width, height: why.frame.height)
        let labelWidth = max(0, why.frame.minX - AircSpacing.s - AircSpacing.l)
        label.frame = NSRect(x: AircSpacing.l, y: (h - label.frame.height) / 2, width: labelWidth, height: label.frame.height)
    }

    @objc private func whyPressed() { onWhy?() }

    /// In: Arc's toast motion (from 0.7 scale on the pop spring, fading in).
    func present() {
        guard let layer else { return }
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: frame.midX, y: frame.midY)
        layer.add(AircSpring.pop.caAnimation(keyPath: "transform.scale", from: 0.7, to: 1), forKey: "in")
        layer.fade(from: 0, to: 1, duration: AircCurve.previewIn.duration)
    }

    func dismiss() {
        layer?.fade(from: 1, to: 0, duration: AircCurve.toastOut.duration)
        DispatchQueue.main.asyncAfter(deadline: .now() + AircCurve.toastOut.duration) { [weak self] in self?.removeFromSuperview() }
    }
}

extension ProtectedMedia {
    /// Services whose toast showed this session (shown again on their page until its ✕).
    private static var shownThisSession: Set<String> = []

    /// The service the shown WebKit page plays ("Spotify"), or nil: a Chromium page, or a page away from a listed site
    /// (a WebKit page signing in elsewhere keeps no toast).
    func toastService(for page: EngineTab?) -> String? {
        guard Self.isWebKitPage(page), let s = service(of: page?.url), !wasTold(s) else { return nil }
        return s
    }

    // MARK: Pages that ask for Widevine (Site Controls' switch on Chromium pages)

    /// Hosts a Chromium page asked for Widevine on (the page script's `drm` part), per page.
    private static var widevinePages: [ObjectIdentifier: (ref: Weak, host: String)] = [:]
    private final class Weak { weak var page: EngineTab?; init(_ p: EngineTab) { page = p } }

    /// Whether `page` asked for Widevine on the site it shows now.
    func askedForWidevine(_ page: EngineTab?) -> Bool {
        guard let page, let e = Self.widevinePages[ObjectIdentifier(page)], e.ref.page === page else { return false }
        return e.host == page.url?.host?.lowercased()
    }

    /// The page script's part that notices `navigator.requestMediaKeySystemAccess` for Widevine (Chromium pages; a
    /// WebKit page asks for FairPlay). Installed once, before the first page.
    static func installWidevineProbe() {
        guard !probeInstalled, let scripts = PageScripts.shared else { return }
        probeInstalled = true
        scripts.set("drm", source: """
        function (post) {
          try {
            var nav = navigator, original = nav.requestMediaKeySystemAccess, told = false;
            if (typeof original !== 'function') return null;
            nav.requestMediaKeySystemAccess = function (keySystem) {
              if (!told && /widevine/i.test(String(keySystem))) { told = true; post('widevine', '{}'); }
              return original.apply(this, arguments);
            };
          } catch (e) {}
          return null;
        }
        """) { page, message in
            guard message.kind == "widevine", let host = URL(string: message.origin)?.host?.lowercased() ?? page.url?.host?.lowercased()
            else { return }
            widevinePages = widevinePages.filter { $0.value.ref.page != nil }
            widevinePages[ObjectIdentifier(page)] = (Weak(page), page.url?.host?.lowercased() ?? host)
            NotificationCenter.default.post(name: widevineAsked, object: page)
        }
    }
    private static var probeInstalled = false
    static let widevineAsked = Notification.Name("AircProtectedMediaWidevineAsked")
}

extension WindowController {
    /// A page is on screen (shown, in a split, after its handoff or a navigation): its service's toast, once.
    func protectedMediaPageShown(_ tabID: String) {
        guard tabID == shownTabID else { return }
        let service = ProtectedMedia.shared.toastService(for: engineTab(for: tabID))
        if let toast = protectedMediaToast, toast.service != service {
            toast.dismiss()
            protectedMediaToast = nil
        }
        guard let service, protectedMediaToast == nil else { return }
        let toast = ProtectedMediaToastView(service: service, palette: currentPalette)
        toast.onWhy = { [weak self] in self?.showSiteControls() }
        toast.onClose = { [weak self, weak toast] in
            ProtectedMedia.shared.told(service)
            toast?.dismiss()
            if self?.protectedMediaToast === toast { self?.protectedMediaToast = nil }
        }
        root.addSubview(toast, positioned: .below, relativeTo: self.toast)
        protectedMediaToast = toast
        layoutProtectedMediaToast()
        toast.present()
    }

    /// Top centre of the page (or the focused pane), where Airc's toasts appear.
    func layoutProtectedMediaToast() {
        guard let toast = protectedMediaToast else { return }
        var page = card.frame
        if shownSplitID != nil, let id = shownTabID, let pane = splitContainer.pane(for: id) {
            page = splitContainer.convert(pane.frame, to: root)
        }
        let w = min(toast.fittingWidth, page.width - 2 * AircSpacing.l)
        toast.frame = NSRect(x: page.midX - w / 2, y: page.minY + AircMetrics.Toast.topInset, width: w, height: AircMetrics.Toast.height)
    }

    /// Site Controls' "Safari's engine" switch: the page's site plays in `engine` from now on, and the page opens again
    /// there at once.
    func setProtectedMediaEngine(_ engine: PageEngine, for page: EngineTab) {
        guard let url = page.url else { return }
        ProtectedMedia.shared.choose(engine, for: url)
        engineWindow.load(url, in: page)
    }
}

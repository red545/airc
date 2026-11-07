// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import Combine
import AircDesign
import AircKit
import SwiftUI

/// State of the Create a Space card (SP-10; design mockup profiles.html §1–2).
final class NewSpaceModel: ObservableObject {
    @Published var name = ""
    @Published var icon: String? = nil { didSet { onIconChange?() } }
    var onIconChange: (() -> Void)?
    /// The theme being picked; nil keeps Settings → Appearance → New Spaces.
    @Published var theme: SpaceTheme? = nil { didSet { onPreview?(currentTheme) } }
    @Published var profileID: String
    @Published var profiles: [Profile] = []
    @Published var error: String?
    /// The card's own colours: the theme it previews (its accent is Create Space's, as in Arc).
    @Published var resolved: ResolvedTheme
    /// Create Space was pressed: the card leaves bottom-up.
    @Published var leaving = false

    /// Settings → Appearance → New Spaces.
    var defaultTheme: SpaceTheme = .neutral
    var currentTheme: SpaceTheme { theme ?? defaultTheme }
    var profile: Profile? { profiles.first { $0.id == profileID } }
    var canCreate: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Where the Profile pill and the theme row are, in the hosting view (for the menu and the popover).
    var pillFrame: CGRect = .zero
    var themeRowFrame: CGRect = .zero

    var onPreview: ((SpaceTheme) -> Void)?
    var onCreate: (() -> Void)?
    var onCancel: (() -> Void)?
    var onProfileMenu: (() -> Void)?
    var onChooseTheme: (() -> Void)?

    init(profileID: String, resolved: ResolvedTheme) {
        self.profileID = profileID
        self.resolved = resolved
    }
}

struct NewSpaceForm: View {
    @ObservedObject var model: NewSpaceModel
    @FocusState private var nameFocused: Bool
    @State private var showIconPicker = false

    private var ui: ResolvedTheme { model.resolved }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12).frame(maxHeight: .infinity).layoutPriority(-1)
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    // 96 × 64 (visual review #13): the drawing is made at 128 × 86 and scaled.
                    CreateSpaceIllustration().frame(width: 128, height: 86)
                        .scaleEffect(AircMetrics.CreateSpace.illustration.width / 128)
                        .frame(width: AircMetrics.CreateSpace.illustration.width, height: AircMetrics.CreateSpace.illustration.height)
                    Text("Create a Space")
                        .aircFont(AircTextStyle(size: 15, weight: .semibold, lineHeight: 20))
                        .foregroundStyle(ui.text.color)
                        .padding(.top, 12)
                    Text("Give each part of your life its own tabs.")
                        .aircFont(AircFont.callout)
                        .foregroundStyle(ui.textSecondary.color)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 3)
                }
                .leaves(model.leaving, delay: 0.13)
                VStack(spacing: 8) {
                    nameField
                    profileRow
                    themeRow
                }
                .padding(.top, 18)
                .leaves(model.leaving, delay: 0.08)
                VStack(spacing: 6) {
                    if let error = model.error {
                        Text(error)
                            .aircFont(AircFont.caption)
                            .foregroundStyle(AircColor.destructive.color)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Create Space") { model.onCreate?() }
                        .buttonStyle(.airc(.primary, size: .large, fullWidth: true))
                        .disabled(!model.canCreate)
                        .keyboardShortcut(.defaultAction)
                        .testAnchor("new.create")
                    Button { model.onCancel?() } label: {
                        // Quieter than Create Space: plain, secondary ink, regular weight (visual review #13).
                        Text("Cancel").fontWeight(.regular).foregroundStyle(ui.textSecondary.color)
                    }
                        .buttonStyle(.airc(.plain, size: .regular, fullWidth: true))
                        .keyboardShortcut(.cancelAction)
                        .testAnchor("new.cancel")
                }
                .padding(.top, 14)
                .leaves(model.leaving, delay: 0)
            }
            .padding(.horizontal, 12)
            Spacer(minLength: 12).frame(maxHeight: .infinity).layoutPriority(-1)
            Spacer(minLength: 0).frame(maxHeight: 60)
        }
        .testAnchorRoot()
        .aircTheme(ui)
        .onAppear {
            // Focus once the card is in the window (FocusState set during the first appearance is dropped).
            DispatchQueue.main.async { nameFocused = true }
        }
    }

    // MARK: Rows (200 × 36, radius 10, fieldFill; label body in textSecondary, control 7 pt in)

    private var nameField: some View {
        HStack(spacing: 4) {
            Button { showIconPicker.toggle() } label: {
                Group {
                    if let icon = model.icon { Text(icon).font(.system(size: 16)) }
                    else { Image(systemName: "face.smiling").font(.system(size: 14)).foregroundStyle(ui.textTertiary.color) }
                }
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(ui.tileHoverFill.color))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Choose an icon")
            .testAnchor("new.icon")
            .popover(isPresented: $showIconPicker, arrowEdge: .bottom) {
                EmojiPicker(onPick: { model.icon = $0; showIconPicker = false }).frame(width: 273, height: 273)
            }
            TextField("Space name", text: $model.name)
                .textFieldStyle(.plain)
                .aircFont(AircFont.body)
                .foregroundStyle(ui.text.color)
                .focused($nameFocused)
                .onSubmit { if model.canCreate { model.onCreate?() } }
                .testAnchor("new.name")
        }
        .padding(.leading, 4)
        .padding(.trailing, 10)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(ui.fieldFill.color))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).inset(by: -1)
            .stroke(ui.focusRing.color, lineWidth: 2).opacity(nameFocused ? 1 : 0))
    }

    private var profileRow: some View {
        CardRow(label: "Profile", ui: ui, action: { model.onProfileMenu?() }) {
            HStack(spacing: 5) {
                if let p = model.profile {
                    AircProfileAvatar(emoji: p.emoji, name: p.name, color: p.color.aircColor, size: 16)
                    Text(p.name).aircFont(AircTextStyle(size: 12, weight: .medium, lineHeight: 15)).foregroundStyle(ui.text.color).lineLimit(1)
                }
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(ui.textSecondary.color)
            }
            .padding(.leading, 3)
            .padding(.trailing, 7)
            .frame(height: 22)
            .background(Capsule().fill(ui.tileHoverFill.color))
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(Self.space)) }) { model.pillFrame = $0 }
        }
        .testAnchor("new.profile")
    }

    private var themeRow: some View {
        CardRow(label: "Choose a Theme", ui: ui, action: { model.onChooseTheme?() }) {
            HStack(spacing: 6) {
                AircThemeChip(theme: model.currentTheme.design.resolved(systemIsDark: ui.isDark))
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(ui.textSecondary.color)
            }
            .padding(.trailing, 4)
        }
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(Self.space)) }) { model.themeRowFrame = $0 }
        .testAnchor("new.theme")
    }

    static let space = "new-space-card"
}

/// One of the card's 36 pt rows: a label and a trailing control; the whole row is the button.
private struct CardRow<Trailing: View>: View {
    let label: String
    let ui: ResolvedTheme
    let action: () -> Void
    @ViewBuilder let trailing: Trailing
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(label).aircFont(AircFont.body).foregroundStyle(ui.textSecondary.color)
                Spacer(minLength: 6)
                trailing
            }
            .padding(.leading, 12)
            .padding(.trailing, 7)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(ui.fieldFill.color))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(ui.text.alpha(hovered ? 0.05 : 0).color))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// Arc's three stacked pages above "Create a Space".
private struct CreateSpaceIllustration: View {
    var body: some View {
        ZStack {
            page(AircColor(0x9FDDBD), lines: AircColor(0x5BAE86)).rotationEffect(.degrees(-11)).offset(x: -26, y: 4)
            page(AircColor(0xF4AEB8), lines: AircColor(0xD27585)).rotationEffect(.degrees(11)).offset(x: 26, y: 4)
            page(AircColor(0xB4C4F6), lines: AircColor(0x6F86D6)).offset(y: -2)
        }
    }

    private func page(_ fill: AircColor, lines: AircColor) -> some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(LinearGradient(colors: [AircColor.mix(fill, .white(), 0.35).color, fill.color], startPoint: .top, endPoint: .bottom))
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach([0.7, 0.85, 0.55, 0.8], id: \.self) { w in
                        Capsule().fill(lines.alpha(0.55).color).frame(width: 34 * w, height: 3)
                    }
                }
                .padding(.top, 12).padding(.leading, 9)
            }
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).inset(by: 0.25).stroke(AircColor.white(0.6).color, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
            .frame(width: 54, height: 68)
    }
}

private extension View {
    /// After Create the card leaves bottom-up: each part fades and sinks 8 pt over 150 ms, staggered 0/80/130 ms.
    func leaves(_ leaving: Bool, delay: Double) -> some View {
        opacity(leaving ? 0 : 1)
            .offset(y: leaving ? 8 : 0)
            .animation(.easeOut(duration: 0.15).delay(leaving ? delay : 0), value: leaving)
    }
}

/// Fills the sidebar column below the header, like Arc's create page: the card sits on the theme itself.
final class NewSpacePanelHost: NSView {
    let model: NewSpaceModel
    private let host: AircFirstClickHostingView<AnyView>

    init(model: NewSpaceModel) {
        self.model = model
        host = AircFirstClickHostingView(rootView: AnyView(NewSpaceForm(model: model).coordinateSpace(name: NewSpaceForm.space)))
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    var hostingView: NSView { host }

    func layoutIn(_ bounds: NSRect, sidebarFrame: NSRect) {
        let top = AircMetrics.Sidebar.urlFieldTop
        frame = NSRect(x: sidebarFrame.minX, y: top, width: sidebarFrame.width,
                       height: max(0, bounds.height - top - AircMetrics.Footer.height))
        host.frame = self.bounds
    }

    /// A rect of the form (SwiftUI's top-left coordinates) in this view.
    func rect(_ r: CGRect) -> NSRect { host.convert(r, to: self) }
}

private extension NSView {
    /// Pages the view sideways on Arc's settle spring (render server, no main-thread work): it ends at opacity `o1`
    /// and back in place; the slide from `x` only plays.
    func page(fromX x: CGFloat, opacity o0: CGFloat, to o1: CGFloat) {
        alphaValue = o1
        guard let layer else { return }
        let spring = Spring(AircSpring.settle)
        func anim(_ key: String, _ from: Any, _ to: Any) -> CASpringAnimation {
            let a = CASpringAnimation(keyPath: key)
            a.fromValue = from
            a.toValue = to
            a.mass = 1
            a.stiffness = spring.omega * spring.omega
            a.damping = 2 * spring.dampingRatio * spring.omega
            a.duration = a.settlingDuration
            return a
        }
        layer.add(anim("transform.translation.x", x, 0), forKey: "page.x")
        layer.add(anim("opacity", Float(o0), Float(o1)), forKey: "page.opacity")
    }

    /// Slides out by `x` while fading to 0 (the model is transparent at once; the slide only plays).
    func pageAway(toX x: CGFloat) {
        alphaValue = 0
        guard let layer else { return }
        let spring = Spring(AircSpring.settle)
        for (key, from, to) in [("transform.translation.x", 0.0 as Any, x as Any), ("opacity", Float(1) as Any, Float(0) as Any)] {
            let a = CASpringAnimation(keyPath: key)
            a.fromValue = from
            a.toValue = to
            a.mass = 1
            a.stiffness = spring.omega * spring.omega
            a.damping = 2 * spring.dampingRatio * spring.omega
            a.duration = a.settlingDuration
            layer.add(a, forKey: "page." + key)
        }
    }
}

extension WindowController {
    /// "+" → New Space…, ⌘⇧N-style commands, the Command Bar's "/" action and Settings → Spaces.
    func openNewSpacePanel() {
        if newSpacePanel != nil { return }
        closeCommandBar()
        closeCreateProfile()
        if sidebarHidden { toggleSidebar() }
        let model = NewSpaceModel(profileID: store.profile(ofSpace: currentSpaceID).id,
                                  resolved: Palette(theme: app?.settings.defaultTheme ?? .neutral, systemDark: systemDark).resolved)
        model.defaultTheme = app?.settings.defaultTheme ?? .neutral
        model.profiles = store.orderedProfiles
        let originalTheme = store.space(currentSpaceID)?.theme ?? .neutral
        let fromPalette = currentPalette
        model.onPreview = { [weak self, weak model] theme in
            // TH-1: the window wears the new Space's theme while you pick (the default one as soon as it opens).
            guard let self else { return }
            let p = Palette(theme: theme, systemDark: self.systemDark)
            self.background.show(fromPalette.resolved, p.resolved, t: 1)
            self.previewTheme = theme
            model?.resolved = p.resolved
            self.refreshChrome()
            self.queueNewSpacePrerender()
        }
        model.onCancel = { [weak self] in
            guard let self else { return }
            self.background.show(Palette(theme: originalTheme, systemDark: self.systemDark).resolved)
            self.closeNewSpacePanel(created: false)
        }
        model.onCreate = { [weak self, weak model] in
            guard let self, let model else { return }
            self.commitNewSpace(model)
        }
        model.onIconChange = { [weak self] in self?.refreshChrome(); self?.queueNewSpacePrerender() }
        newSpaceObserver = model.$name.combineLatest(model.$profileID)
            .debounce(for: .seconds(0.12), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.queueNewSpacePrerender() }
        model.onProfileMenu = { [weak self] in self?.showNewSpaceProfileMenu() }
        model.onChooseTheme = { [weak self] in self?.showNewSpaceThemePicker() }
        let panel = NewSpacePanelHost(model: model)
        newSpacePanel = panel
        root.addSubview(panel, positioned: .below, relativeTo: toast)
        panel.layoutIn(root.bounds, sidebarFrame: sidebar.frame)
        model.onPreview?(model.currentTheme)
        // A new sidebar page: the current one slides away to the left, the card arrives from the right.
        pageView(for: currentSpaceID)?.pageAway(toX: -28)
        panel.page(fromX: 36, opacity: 0, to: 1)
    }

    /// Draws the spare page for the card's current profile and theme a moment after they settle (not on every slider
    /// step).
    func queueNewSpacePrerender() {
        prerenderToken += 1
        let token = prerenderToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, token == self.prerenderToken, let m = self.newSpacePanel?.model else { return }
            self.prerenderNewSpacePage(profileID: m.profileID, theme: m.currentTheme,
                                       name: m.name.trimmingCharacters(in: .whitespaces), icon: m.icon)
            self.card.prepareEmptySpace(self.emptySpaceContent(name: m.name.trimmingCharacters(in: .whitespaces),
                                                               emoji: m.icon, profileID: m.profileID, adding: true))
        }
    }

    /// `created`: the card leaves bottom-up over the new Space; otherwise it pages back to the Space it came from.
    func closeNewSpacePanel(created: Bool) {
        guard let p = newSpacePanel else { return }
        newSpacePanel = nil
        newSpaceObserver = nil
        if !created { hideSparePage() }
        themePopover?.close()
        if previewTheme != nil {
            previewTheme = nil
            if created {
                let old = currentSpaceID
                afterCreateFrame { [weak self] in self?.pageView(for: old)?.reload(animated: false) }
            } else {
                refreshChrome()
                pageView(for: currentSpaceID)?.reload(animated: false)
            }
        }
        let page = pageView(for: currentSpaceID)
        if created {
            // The Space it came from is off screen once the new one shows; it comes back as it was.
            page?.alphaValue = 1
            // The card's SwiftUI leave starts in the next frame, not the one that shows the new Space (§2.12: within
            // one frame of Enter); its first 80 ms barely move anyway.
            afterCreateFrame { p.model.leaving = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { p.removeFromSuperview() }
        } else {
            page?.page(fromX: -28, opacity: 0, to: 1)
            p.pageAway(toX: 36)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { p.removeFromSuperview() }
        }
    }

    /// Main-queue async work can still run before Core Animation commits Create's frame.
    /// Give the new Space a frame before starting SwiftUI's leave and redrawing the old page.
    private func afterCreateFrame(_ work: @escaping () -> Void) {
        #if AIRC_TESTING
        if ProcessInfo.processInfo.environment["AIRC_NEW_SPACE_BASELINE"] == "1" {
            DispatchQueue.main.async(execute: work)
            return
        }
        #endif
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: work)
    }

    /// SP-11: the native profile menu under the pill: avatar, name, the Google account, ✓, then New Profile….
    private func showNewSpaceProfileMenu() {
        guard let panel = newSpacePanel else { return }
        profiles.prepareSpare()
        let model = panel.model
        let menu = NSMenu()
        for p in store.orderedProfiles {
            let item = menu.add(p.name) { [weak self, weak model] in
                model?.profileID = p.id
                self?.queueNewSpacePrerender()
            }
            item.image = ProfileAvatarImage.image(p, size: 20)
            if #available(macOS 14.4, *), let account = p.googleAccount { item.subtitle = account }
            item.state = p.id == model.profileID ? .on : .off
        }
        menu.addItem(.separator())
        let new = menu.add("New Profile…") { [weak self, weak model] in
            guard let self, let model else { return }
            self.openCreateProfile(forNewSpace: model)
        }
        new.image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: nil)
        let pill = panel.rect(model.pillFrame)
        menu.popUp(positioning: nil, at: NSPoint(x: pill.minX - 4, y: pill.maxY + 4), in: panel)
    }

    #if AIRC_TESTING
    /// The theme row's action, for the scripted runs.
    func showThemePickerForTests() { showNewSpaceThemePicker() }
    #endif

    /// SP-10: "Choose a Theme" opens the theme picker beside the card; the window follows every change.
    private func showNewSpaceThemePicker() {
        guard let panel = newSpacePanel else { return }
        let model = panel.model
        showThemePicker(theme: model.currentTheme, relativeTo: panel.rect(model.themeRowFrame), of: panel) { [weak model] t in
            model?.theme = t
        }
    }

    /// Enter: creates the Space and switches to it in the same frame (§2.12: within one frame). One store
    /// transaction; only the new Space's page is built; the next spare is prepared after the frame.
    private func commitNewSpace(_ model: NewSpaceModel) {
        guard model.canCreate else { return }
        beginQuiet()
        defer { endQuiet() }
        let created: Space
        do {
            // Written to disk with the next flush (2 s, or at quit), not inside the frame that shows the Space.
            created = try Perf.time("new.store") {
                try store.perform(nil, deferred: true) {
                    try store.createSpace(name: model.name.trimmingCharacters(in: .whitespaces), icon: model.icon.map(SpaceIcon.emoji),
                                          theme: model.currentTheme, profileID: model.profileID, after: currentSpaceID)
                }
            }
        } catch {
            // Never fail silently (P0, 2026-11-05): say what went wrong on the card and keep it open.
            NSLog("Airc: creating a Space failed: \(error)")
            model.error = "Couldn’t create the Space: \(error.localizedDescription)"
            return
        }
        Telemetry.shared.record(.featureUsed(.spaceCreate))
        Perf.time("new.closePanel") { closeNewSpacePanel(created: true) }
        Perf.time("new.addPage") { addPage(for: created.id) }
        Perf.time("new.switch") { switchToSpace(created.id, animated: false) }
        Perf.time("new.background") { background.show(palette(for: created).resolved) }
    }
}

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import AircKit
import Combine
import SwiftUI

/// Arc's two-step Create Profile card (SP-11; design mockup profiles.html §4–5), centred over the page.
/// From Create a Space it is one step: the new Space is the answer to step 2.
final class CreateProfileModel: ObservableObject {
    enum Step { case name, spaces }

    struct SpaceTile: Identifiable {
        var id: String
        var name: String
        var icon: String
        var theme: ResolvedTheme
        var profile: Profile
    }

    @Published var step: Step = .name
    @Published var name = ""
    @Published var emoji = CreateProfileModel.emoji[0]
    @Published var colorIndex = 2
    @Published var chosen: Set<String> = []
    @Published var error: String?
    let oneStep: Bool
    let spaces: [SpaceTile]
    let ui: ResolvedTheme

    var validate: ((String) -> ProfileNameProblem?)?
    var onCreate: (() -> Void)?
    var onCancel: (() -> Void)?

    /// The design's suggested icons; ••• opens the full emoji picker.
    static let emoji = ["🪴", "🌱", "⚡️", "🍊", "🎧", "📚", "🧪", "🏄", "🐙"]

    init(oneStep: Bool, spaces: [SpaceTile], preselected: Set<String>, ui: ResolvedTheme) {
        self.oneStep = oneStep
        self.spaces = spaces
        self.ui = ui
        chosen = preselected
    }

    var color: AircColor { AircProfileColor.choices[colorIndex % AircProfileColor.choices.count] }
    var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    var problemText: String? {
        guard !trimmedName.isEmpty else { return nil }
        switch validate?(trimmedName) {
        case .taken: return "There’s already a Profile with this name."
        case .tooLong: return "Invalid Profile name."
        case .empty, nil: return nil
        }
    }

    var canContinue: Bool { !trimmedName.isEmpty && problemText == nil }

    /// "Studio and Clients move over…" under the tiles.
    var summary: String? {
        let names = spaces.filter { chosen.contains($0.id) }.map(\.name)
        guard !names.isEmpty else { return nil }
        let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!
        return "\(list) move\(names.count == 1 ? "s" : "") over. Their pinned tabs and folders stay; open tabs reload."
    }
}

struct CreateProfileCard: View {
    @ObservedObject var model: CreateProfileModel
    @FocusState private var nameFocused: Bool
    @State private var showEmojiPicker = false

    private var ui: ResolvedTheme { model.ui }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !model.oneStep { dots.padding(.bottom, 16) }
            switch model.step {
            case .name: nameStep
            case .spaces: spacesStep
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, model.oneStep ? 28 : 22)
        .padding(.bottom, 22)
        .frame(width: 528)
        .testAnchorRoot()
        .aircTheme(ui)
        .onAppear { DispatchQueue.main.async { nameFocused = true } }
    }

    private var dots: some View {
        HStack(spacing: 4) {
            Capsule().fill((model.step == .name ? ui.accent : ui.surfaceText.alpha(0.18)).color).frame(width: model.step == .name ? 20 : 5, height: 5)
            Capsule().fill((model.step == .spaces ? ui.accent : ui.surfaceText.alpha(0.18)).color).frame(width: model.step == .spaces ? 20 : 5, height: 5)
        }
        .aircAnimation(AircSpring.toggle, value: model.step == .name)
    }

    // MARK: Step 1

    private var nameStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Create a new Profile").aircFont(AircFont.title2).foregroundStyle(ui.surfaceText.color)
            Text("Each Profile keeps its own logins, history, saved passwords and extensions, so the Spaces that use it stay apart from the rest. Keep work and home signed in side by side.")
                .aircFont(AircFont.body)
                .foregroundStyle(ui.surfaceTextSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            Text("What do you want to call this Profile?")
                .aircFont(AircFont.body.weight(.medium))
                .foregroundStyle(ui.surfaceText.color)
                .padding(.top, 20)
            HStack(alignment: .top, spacing: 14) {
                AircProfileAvatar(emoji: model.emoji, name: model.name, color: model.color, size: 56)
                    .padding(3)
                    .overlay(Circle().stroke(ui.surfaceText.alpha(0.08).color, lineWidth: 1))
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Personal", text: $model.name)
                        .textFieldStyle(.plain)
                        .aircFont(AircFont.body)
                        .foregroundStyle(ui.surfaceText.color)
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ui.surface.color))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).inset(by: nameFocused ? -0.5 : 0.25)
                            .stroke((nameFocused ? ui.focusRing : ui.surfaceBorder).color, lineWidth: nameFocused ? 2 : 0.5))
                        .focused($nameFocused)
                        .onSubmit(primary)
                        .testAnchor("profile.name")
                    Text(model.problemText ?? "Shown in the Space header and the Profile menu.")
                        .aircFont(AircFont.caption)
                        .foregroundStyle(model.problemText == nil ? ui.surfaceTextTertiary.color : AircColor.destructive.color)
                }
            }
            .padding(.top, 10)
            HStack(spacing: 6) {
                Text("Icon").aircFont(AircFont.callout).foregroundStyle(ui.surfaceTextSecondary.color).frame(width: 56, alignment: .leading)
                ForEach(CreateProfileModel.emoji, id: \.self) { e in
                    Button { model.emoji = e } label: {
                        Text(e).font(.system(size: 17)).frame(width: 30, height: 30)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ui.surfaceText.alpha(model.emoji == e ? 0.07 : 0).color))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).inset(by: 0.5)
                                .stroke(ui.accent.color, lineWidth: 1.5).opacity(model.emoji == e ? 1 : 0))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Button { showEmojiPicker.toggle() } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(ui.surfaceTextSecondary.color)
                        .frame(width: 30, height: 30)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ui.surfaceText.alpha(0.05).color))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("More icons")
                .popover(isPresented: $showEmojiPicker, arrowEdge: .bottom) {
                    EmojiPicker(onPick: { model.emoji = $0 ?? model.emoji; showEmojiPicker = false }).frame(width: 273, height: 273)
                }
            }
            .padding(.top, 18)
            HStack(spacing: 10) {
                Text("Colour").aircFont(AircFont.callout).foregroundStyle(ui.surfaceTextSecondary.color).frame(width: 52, alignment: .leading)
                AircProfileColorPicker(selection: $model.colorIndex)
            }
            .padding(.top, 8)
            buttons(back: false)
                .padding(.top, 24)
        }
    }

    // MARK: Step 2

    private var spacesStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Choose the Spaces for this Profile").aircFont(AircFont.title2).foregroundStyle(ui.surfaceText.color)
            Text("In the new Profile these Spaces start clean: you’ll sign in to sites again and add your passwords and extensions there. You can move them back to their old Profile at any time.")
                .aircFont(AircFont.body)
                .foregroundStyle(ui.surfaceTextSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(88), spacing: 8, alignment: .top), count: 5), alignment: .leading, spacing: 12) {
                ForEach(model.spaces) { s in tile(s) }
            }
            .padding(.top, 16)
            if let summary = model.summary {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    AircProfileAvatar(emoji: model.emoji, name: model.name, color: model.color, size: 16).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                    (Text(model.trimmedName).fontWeight(.semibold).foregroundColor(ui.surfaceText.color)
                     + Text(" · " + summary).foregroundColor(ui.surfaceTextSecondary.color))
                        .aircFont(AircFont.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 14)
            }
            buttons(back: true)
                .padding(.top, 20)
        }
    }

    /// AircSpaceTile (visual review #16): the Space in its own theme with a hint of its sidebar, the ring 2 pt off it.
    private func tile(_ s: CreateProfileModel.SpaceTile) -> some View {
        AircSpaceTile(theme: s.theme, emoji: s.icon, name: s.name,
                      currentProfile: AircProfileIdentity(name: s.profile.name, emoji: s.profile.emoji, color: s.profile.color.aircColor),
                      isOn: Binding(get: { model.chosen.contains(s.id) },
                                    set: { on in if on { model.chosen.insert(s.id) } else { model.chosen.remove(s.id) } }))
            .testAnchor("profile.space.\(s.name)")
    }

    // MARK: Buttons

    private func buttons(back: Bool) -> some View {
        HStack(spacing: 8) {
            if back {
                Button("Back") { withAnimation(.easeOut(duration: 0.15)) { model.step = .name } }
                    .buttonStyle(.airc(.plain, size: .large))
            }
            Spacer()
            Button("Cancel") { model.onCancel?() }
                .buttonStyle(.airc(.secondary, size: .large))
                .keyboardShortcut(.cancelAction)
                .testAnchor("profile.cancel")
            Button(primaryTitle, action: primary)
                .buttonStyle(.airc(.primary, size: .large))
                .disabled(!model.canContinue)
                .keyboardShortcut(.defaultAction)
                .testAnchor("profile.primary")
        }
    }

    private var primaryTitle: String { model.oneStep || model.step == .spaces ? "Create Profile" : "Next" }

    private func primary() {
        guard model.canContinue else { return }
        if model.oneStep || model.step == .spaces { model.onCreate?() }
        else { withAnimation(.easeOut(duration: 0.15)) { model.step = .spaces } }
    }
}

/// A scrim over the page with the card centred on it; the sidebar stays as it is (Arc's Create Profile).
final class CreateProfilePanelHost: NSView {
    let model: CreateProfileModel
    private let scrim = NSView()
    private let card = NSView()
    private let host: AircFirstClickHostingView<CreateProfileCard>
    private var pageRect: NSRect = .zero

    init(model: CreateProfileModel, palette: Palette) {
        self.model = model
        host = AircFirstClickHostingView(rootView: CreateProfileCard(model: model))
        super.init(frame: .zero)
        wantsLayer = true
        scrim.wantsLayer = true
        scrim.layer?.backgroundColor = NSColor.black.withAlphaComponent(palette.isDark ? 0.40 : 0.22).cgColor
        scrim.layer?.cornerRadius = AircMetrics.Window.cardRadius
        addSubview(scrim)
        card.wantsLayer = true
        card.layer?.cornerRadius = 18
        card.layer?.cornerCurve = .continuous
        card.layer?.backgroundColor = palette.resolved.surface.nsColor.cgColor
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = palette.resolved.surfaceBorder.nsColor.cgColor
        card.layer?.applyAircShadow(.panel)
        addSubview(card)
        card.addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    var hostingView: NSView { host }

    /// Covers the page card; clicks on the sidebar go through to it.
    func layoutIn(page: NSRect) {
        pageRect = page
        frame = page
        scrim.frame = bounds
        let size = host.fittingSize
        card.frame = NSRect(x: (bounds.width - size.width) / 2, y: max(16, (bounds.height - size.height) / 2 - 20),
                            width: size.width, height: size.height)
        host.frame = card.bounds
    }

    /// The content changed (the step, a ticked Space that brings the summary line, the name): the card grows or shrinks
    /// around its centre. SwiftUI applies a change on a later run-loop turn, and animates it, so the card follows the
    /// content's fitting size for the next 0.4 s after each change, in one loop however many changes come; sized once,
    /// right after a change, it could keep the old height and cut off the button (seen under load). Followed on step
    /// changes only, it kept step two's first height when ticking a Space added the summary line, and "Create Profile"
    /// hung below the card, where clicks miss it.
    func relayout() {
        followUntil = CACurrentMediaTime() + 0.4
        guard !following else { return }
        following = true
        followFittingSize()
    }

    private var following = false
    private var followUntil: CFTimeInterval = 0

    private func followFittingSize() {
        if host.fittingSize != card.frame.size { layoutIn(page: pageRect) }
        guard CACurrentMediaTime() < followUntil else { following = false; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [weak self] in self?.followFittingSize() }
    }

    // A click on the scrim cancels, like Esc.
    override func mouseDown(with event: NSEvent) {
        if !card.frame.contains(convert(event.locationInWindow, from: nil)) { model.onCancel?() }
    }
}

extension WindowController {
    /// Space menu → Set Profile › New Profile…, Settings → Profiles → New Profile…: both steps, with `spaceID` ticked.
    func openCreateProfile(forSpace spaceID: String?) {
        presentCreateProfile(oneStep: false, preselected: spaceID.map { [$0] } ?? []) { [weak self] profile, chosen in
            guard let self else { return }
            for id in chosen { self.setProfile(ofSpace: id, to: profile.id) }
        }
    }

    /// Create a Space → Profile › New Profile…: one step; the new profile becomes the card's choice.
    func openCreateProfile(forNewSpace model: NewSpaceModel) {
        presentCreateProfile(oneStep: true, preselected: []) { [weak self, weak model] profile, _ in
            model?.profiles = self?.store.orderedProfiles ?? []
            model?.profileID = profile.id
            self?.queueNewSpacePrerender()
        }
    }

    func closeCreateProfile() {
        guard let p = createProfilePanel else { return }
        createProfilePanel = nil
        p.layer?.fade(from: 1, to: 0, duration: 0.12)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { p.removeFromSuperview() }
    }

    private func presentCreateProfile(oneStep: Bool, preselected: Set<String>, then: @escaping (Profile, Set<String>) -> Void) {
        profiles.prepareSpare()
        closeCreateProfile()
        closeCommandBar()
        let pal = currentPalette
        let tiles = store.orderedSpaces.map { s in
            CreateProfileModel.SpaceTile(id: s.id, name: s.name, icon: s.iconLabel, theme: palette(for: s).resolved,
                                         profile: store.profile(ofSpace: s.id))
        }
        let model = CreateProfileModel(oneStep: oneStep, spaces: tiles, preselected: preselected, ui: pal.resolved)
        model.colorIndex = store.orderedProfiles.count % AircProfileColor.choices.count
        model.validate = { [weak self] in self?.store.validateProfileName($0) }
        model.onCancel = { [weak self] in self?.closeCreateProfile() }
        model.onCreate = { [weak self, weak model] in
            guard let self, let model else { return }
            do {
                // Ready at once: the warm spare engine profile is bound to it (SP-11).
                let p = try self.profiles.createProfile(name: model.trimmedName, emoji: model.emoji, color: RGBA(model.color))
                Telemetry.shared.record(.featureUsed(.profileCreate))
                self.closeCreateProfile()
                then(p, model.oneStep ? [] : model.chosen)
                self.refreshChrome()
            } catch StoreError.profileNameTaken {
                model.error = "There’s already a Profile with this name."
            } catch {
                NSLog("Airc: creating a Profile failed: \(error)")
                model.error = "Couldn’t create the Profile: \(error.localizedDescription)"
            }
        }
        let panel = CreateProfilePanelHost(model: model, palette: pal)
        createProfilePanel = panel
        root.addSubview(panel, positioned: .below, relativeTo: toast)
        panel.layoutIn(page: card.frame)
        panel.layer?.fade(from: 0, to: 1, duration: 0.15)
        // Every change of the card's model, not only its step (the summary line comes with the first ticked Space).
        stepObserver = model.objectWillChange.sink { [weak panel] _ in DispatchQueue.main.async { panel?.relayout() } }
    }

    /// Changes a Space's profile without asking (the Create Profile card already said what happens).
    private func setProfile(ofSpace spaceID: String, to profileID: String) {
        guard let reload = try? store.setProfile(ofSpace: spaceID, to: profileID) else { return }
        reloadPagesInNewProfile(reload)
        if spaceID == currentSpaceID, let p = profiles.engineProfile(for: profileID) { engineWindow.activeProfile = p }
    }

    /// The theme picker beside `rect` of `view` (Create a Space, Space menu → Edit Theme Color…), in the edited theme.
    func showThemePicker(theme: SpaceTheme, relativeTo rect: NSRect, of view: NSView, onChange: @escaping (SpaceTheme) -> Void) {
        themePopover?.close()
        let picker = ThemePickerPanel(theme: theme, systemIsDark: systemDark, onChange: onChange)
        picker.show(relativeTo: rect, of: view)
        themePopover = picker
    }
}

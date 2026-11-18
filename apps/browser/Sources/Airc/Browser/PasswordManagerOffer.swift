// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import SwiftUI
#if canImport(AircCore)
import AircCore
#endif

// Settings › Passwords › "Offer to save and fill passwords" (docs/user/extensions.md, "Password managers"): with it off,
// Airc neither asks to save a login (Chromium's credentials_enable_service) nor lists saved logins under a field (the
// engine hands its list to the app, which drops it: PagePrompts.swift), so a password manager's extension has the field
// to itself. On by default. The first time a profile has a password manager's extension on, a card offers, once and
// without blocking anything, to switch it off for that profile.
extension AppDelegate {
    /// Airc's own saving and filling of passwords in a profile.
    func setAircPasswords(_ on: Bool, profileID: String) {
        if let ep = profiles.engineProfile(for: profileID) {
            engine.setPasswordsOffered(on, for: ep)
            PasswordFilling.set(on, ep)
        }
        var off = settings.values.passwordFillOff
        off.removeAll { $0 == profileID }
        if !on { off.append(profileID) }
        if off != settings.values.passwordFillOff { settings.values.passwordFillOff = off }
    }

    /// Airc lists a profile's saved logins under its fields.
    func fillsPasswords(profileID: String) -> Bool { !settings.values.passwordFillOff.contains(profileID) }

    /// Airc's saving and filling are both on in the profile (nil saving: an engine without the pref).
    func aircPasswordsOn(profileID: String) -> Bool {
        guard fillsPasswords(profileID: profileID) else { return false }
        guard let ep = profiles.engineProfile(for: profileID) else { return true }
        return engine.passwordsOffered(for: ep) ?? true
    }
}

/// The engine's side of "fill": Chromium itself stops filling (no fill on page load either) in a profile with it off
/// (AircProfile.passwordsFilled, engine patch 040). In memory, so it's applied to each profile as it loads.
enum PasswordFilling {
    static func apply(_ e: EngineProfile, profileID: String) {
        guard let app = NSApp.delegate as? AppDelegate, let settings = app.settings else { return }
        set(!settings.values.passwordFillOff.contains(profileID), e)
    }
    static func set(_ filled: Bool, _ e: EngineProfile) {
        #if canImport(AircCore)
        (e as? ChromiumProfile)?.core.passwordsFilled = filled
        #endif
    }
}

/// The once-per-profile card: "<Manager> is on in this profile. Let it handle passwords?". An ordinary view at the
/// window's bottom right, as the blocker card: it never takes focus, activates the app or blocks the page.
enum PasswordManagerOffer {
    private static var shown: [ObjectIdentifier: (profile: String, view: NSView)] = [:]

    /// A password manager's extension that is on in the window's profile and that Airc hasn't offered for yet.
    static func consider(in controller: WindowController, actions: [ExtensionAction], forCheck: Bool = false) {
        guard let app = controller.app, forCheck || !app.options.isAutomated else { return }
        let profile = controller.currentProfileID
        let key = ObjectIdentifier(controller.window)
        if let s = shown[key], s.profile != profile || s.view.superview == nil { dismiss(key) }
        guard shown[key] == nil, !app.settings.values.passwordManagerOffered.contains(profile),
              app.aircPasswordsOn(profileID: profile),
              let manager = PasswordManagerCatalog.all.first(where: { m in
                  actions.contains { a in a.isEnabled && a.id == (PasswordManagerCatalog.installID(m) ?? "") }
              }),
              let content = controller.window.contentView else { return }
        let profileName = controller.store.profile(profile)?.name ?? "this profile"
        let theme = controller.currentPalette.resolved
        let card = PasswordManagerOfferCard(manager: manager.name, profileName: profileName) { [weak app] letItHandle in
            guard let app else { return }
            if letItHandle { app.setAircPasswords(false, profileID: profile) }
            if !app.settings.values.passwordManagerOffered.contains(profile) {
                app.settings.values.passwordManagerOffered.append(profile)
            }
            dismiss(key)
            if letItHandle { controller.showToast("\(manager.name) handles passwords in \(profileName) now") }
        }
        .padding(20).frame(width: 360)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.surface.color))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(theme.surfaceBorder.color, lineWidth: 0.5))
        .environment(\.aircTheme, theme)
        let host = AircFirstClickHostingView(rootView: card)
        host.safeAreaRegions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(host)
        NSLayoutConstraint.activate([
            host.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            host.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
        ])
        shown[key] = (profile, host)
    }

    static func dismiss(_ key: ObjectIdentifier) { shown.removeValue(forKey: key)?.view.removeFromSuperview() }

    #if AIRC_TESTING
    static func card(in controller: WindowController) -> NSView? { shown[ObjectIdentifier(controller.window)]?.view }
    #endif
}

struct PasswordManagerOfferCard: View {
    let manager: String
    let profileName: String
    var answered: (_ letItHandle: Bool) -> Void
    @Environment(\.aircTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "key.fill").font(.system(size: 22, weight: .medium)).foregroundStyle(theme.accent.color)
            Text("Let \(manager) handle passwords?").aircFont(AircFont.title3)
            Text("\(manager) is on in \(profileName). Airc can stop offering to save passwords and stop listing its saved logins under fields there, so only \(manager)'s show. Settings › Passwords changes this later.")
                .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Keep Both") { answered(false) }.buttonStyle(.airc(.secondary))
                    .testAnchor("pmoffer.keep")
                Spacer(minLength: 8)
                Button("Use \(manager)") { answered(true) }.buttonStyle(.airc(.primary))
                    .testAnchor("pmoffer.use")
            }
        }.foregroundStyle(theme.surfaceText.color)
    }
}

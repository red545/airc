// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit
import SwiftUI

/// A password manager the onboarding step offers: a Chrome Web Store extension, or Airc's own saved logins and passkeys.
struct PasswordManager: Identifiable, Equatable {
    /// Stable key for anchors and tests: "1password", "bitwarden", …, "airc".
    let id: String
    let name: String
    /// The Chrome Web Store ID (32 letters a–p); nil for Airc's own.
    let extensionID: String?
    /// The vendor's Mac app names, looked for in Applications to preselect (never Apple's Passwords app, which every Mac
    /// has).
    var apps: [String] = []
    /// The tile's colour and letter (no vendor artwork in the repo).
    let tint: AircColor
    let letter: String
    var symbol: String?

    var isBuiltin: Bool { extensionID == nil }
}

/// The step's choices, in Arc's order of popularity, then Airc's own. IDs checked against each listing on
/// chromewebstore.google.com/detail/<id> (artifacts/pwmanager/REPORT.md lists the sources).
enum PasswordManagerCatalog {
    static let all: [PasswordManager] = [
        .init(id: "1password", name: "1Password", extensionID: "aeblfdkhhhdcdjpifhhbdiojplfjncoa",
              apps: ["1Password.app", "1Password 7.app"], tint: AircColor(0x1A8CFF), letter: "1"),
        .init(id: "bitwarden", name: "Bitwarden", extensionID: "nngceckbapebfimnlniiiahkandclblb",
              apps: ["Bitwarden.app"], tint: AircColor(0x175DDC), letter: "B"),
        .init(id: "dashlane", name: "Dashlane", extensionID: "fdjamakpfbbddfjaooikfcpapjohcfmg",
              apps: ["Dashlane.app"], tint: AircColor(0x0E353D), letter: "D"),
        .init(id: "lastpass", name: "LastPass", extensionID: "hdokiejnpimakedhajhdlcegeplioahd",
              apps: ["LastPass.app"], tint: AircColor(0xD32D27), letter: "L"),
        .init(id: "protonpass", name: "Proton Pass", extensionID: "ghmbeldphafepmbegfdlkpapadhbakde",
              apps: ["Proton Pass.app"], tint: AircColor(0x6D4AFF), letter: "P"),
        .init(id: "keeper", name: "Keeper", extensionID: "bfogiafebfohielmmehodmfbbebbbpei",
              apps: ["Keeper Password Manager.app", "Keeper.app"], tint: AircColor(0xF5C200), letter: "K"),
        .init(id: "nordpass", name: "NordPass", extensionID: "eiaeiblijfjekdanodkjadfinkhbfgcd",
              apps: ["NordPass.app"], tint: AircColor(0x2CB9A5), letter: "N"),
        // Apple's "iCloud Passwords" extension: fills from the Mac's Passwords app.
        .init(id: "apple", name: "Apple Passwords", extensionID: "pejdijmoenmkgeppbflobdenhhabjlaj",
              tint: AircColor(0x8E8E93), letter: "", symbol: "key.fill"),
        .init(id: "airc", name: "Airc's own", extensionID: nil, tint: AircColor(0x3139FB), letter: "", symbol: "person.badge.key.fill"),
    ]

    #if AIRC_TESTING
    /// Automated runs install a synthetic CRX: its ID stands in for the chosen manager's.
    static var testExtensionIDs: [String: String] = [:]
    #endif

    /// The ID the install asks the engine for.
    static func installID(_ m: PasswordManager) -> String? {
        #if AIRC_TESTING
        if LaunchOptions.current.isAutomated, let id = testExtensionIDs[m.id] { return id }
        #endif
        return m.extensionID
    }

    /// Why a manager is preselected.
    enum Hint: Equatable {
        /// Its Mac app is in Applications.
        case app(String)
        /// The Arc import's extension checklist has it.
        case arc(String)
    }

    /// The preselection, without reading anything private: a vendor's app in /Applications or ~/Applications (only
    /// whether the bundle exists), else a manager the Arc import's extension checklist found (same Web Store IDs), else
    /// nothing. Automated runs look only in the synthetic home folder (BrowserImportLocator.home).
    static func preselect(home: URL?, systemApplications: Bool, checklistIDs: Set<String>) -> (PasswordManager, Hint)? {
        let fm = FileManager.default
        var dirs: [URL] = []
        if systemApplications { dirs.append(URL(fileURLWithPath: "/Applications")) }
        if let home { dirs.append(home.appendingPathComponent("Applications")) }
        for m in all where !m.apps.isEmpty {
            for d in dirs {
                for a in m.apps where fm.fileExists(atPath: d.appendingPathComponent(a).path) { return (m, .app(a)) }
            }
        }
        for m in all {
            if let id = m.extensionID, checklistIDs.contains(id) { return (m, .arc(m.name)) }
        }
        return nil
    }
}

/// One profile's line in the results.
struct PasswordManagerResult: Identifiable, Equatable {
    let profileID: String
    let profileName: String
    let message: String
    /// The extension is in the profile now (installed, or it already was).
    let present: Bool
    var id: String { profileID }
}

// MARK: - The step

/// "Your password manager": pick one, install its extension into the profiles you choose (one review each, a result for
/// each), or keep Airc's own. Not now changes nothing.
struct PasswordManagerStep: View {
    @ObservedObject var model: OnboardingModel
    @Environment(\.aircTheme) private var theme

    var body: some View {
        AircOnboardingPage(step: OnboardingStep.passwordManager.dot, of: model.dots, title: "Your password manager.",
                           subtitle: subtitle, drawsBackground: false) {
            SidebarPreview(model: model)
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                if let results = model.pmResults {
                    resultsList(results)
                } else {
                    grid
                    options
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .testAnchor("onboarding.content")
        } actions: {
            Button("Back") { model.onBack?() }.buttonStyle(.airc(.plain, size: .large))
            Spacer()
            actions
        }
        .overlay { review }
        .testAnchor("onboarding.pm")
    }

    private var chosen: PasswordManager? { PasswordManagerCatalog.all.first { $0.id == model.pmChoice } }

    private var subtitle: String {
        if !model.extensionsAvailable {
            return "Password manager extensions need the Chromium engine. This build runs on WebKit, so none can be installed here."
        }
        switch model.pmHint {
        case .app(let a)?: return "\(a.replacingOccurrences(of: ".app", with: "")) is on this Mac, so it's picked. Its extension fills your passwords in Airc."
        case .arc(let n)?: return "You used \(n) in Arc, so it's picked. Its extension fills your passwords in Airc."
        case nil: return "Pick the one you use and Airc adds its extension. Or keep Airc's own saved logins and passkeys."
        }
    }

    // MARK: Choices

    private var grid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(PasswordManagerCatalog.all) { m in tile(m) }
        }
        .testAnchor("onboarding.pm.grid")
    }

    private func tile(_ m: PasswordManager) -> some View {
        let selected = model.pmChoice == m.id
        let enabled = m.isBuiltin || model.extensionsAvailable
        return Button {
            withAircAnimation(AircSpring.toggle) { model.pmChoice = selected ? nil : m.id }
        } label: {
            HStack(spacing: 8) {
                PasswordManagerIcon(manager: m, size: 22)
                Text(m.name).aircFont(AircFont.callout.weight(.medium)).foregroundStyle(theme.surfaceText.color).lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: AircRadius.control, style: .continuous)
                .fill(selected ? theme.accent.color.opacity(0.14) : theme.fieldFill.color))
            .overlay(RoundedRectangle(cornerRadius: AircRadius.control, style: .continuous)
                .strokeBorder(selected ? theme.accent.color : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled || model.pmInstalling)
        .opacity(enabled ? 1 : 0.45)
        .help(m.isBuiltin ? "Airc saves logins and passkeys in each profile. Nothing to install." : "\(m.name)'s Chrome extension")
        .testAnchor("onboarding.pm.choice." + m.id)
    }

    @ViewBuilder private var options: some View {
        if let m = chosen, !m.isBuiltin, model.extensionsAvailable {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("Add it to").aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(model.pmProfiles, id: \.id) { p in profileChip(p.id, p.name) }
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.top, 10)
                ImportCheckRow(title: "Turn off Airc's own password saving and filling",
                               subtitle: "In these profiles, so \(m.name) is the one that asks and fills.",
                               isOn: $model.pmTurnOffSaving)
                    .testAnchor("onboarding.pm.turnOff")
            }
            .background(RoundedRectangle(cornerRadius: AircRadius.control + 2, style: .continuous).fill(theme.fieldFill.color.opacity(0.6)))
        } else if chosen?.isBuiltin == true {
            ImportInfoRow(symbol: "lock", title: "Nothing to install",
                          subtitle: model.extensionsAvailable
                              ? "Airc offers to save logins as you sign in, and keeps passkeys. Settings › Import can change this later."
                              : "Saved logins and passkeys come with the Chromium engine.")
        }
    }

    /// A profile to add the extension to: ticked or not, one tap.
    private func profileChip(_ id: String, _ name: String) -> some View {
        let on = model.pmChosenProfiles.contains(id)
        return Button {
            withAircAnimation(AircSpring.toggle) {
                if on { model.pmChosenProfiles.remove(id) } else { model.pmChosenProfiles.insert(id) }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.system(size: 12, weight: .medium))
                Text(name).aircFont(AircFont.callout.weight(.medium)).lineLimit(1)
            }
            .foregroundStyle(on ? theme.accent.color : theme.surfaceTextSecondary.color)
            .padding(.horizontal, 10).frame(height: 28)
            .background(Capsule().fill(on ? theme.accent.color.opacity(0.14) : theme.fieldFill.color))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
        .testAnchor("onboarding.pm.profile." + id)
    }

    // MARK: Results

    private func resultsList(_ results: [PasswordManagerResult]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if let m = chosen { PasswordManagerIcon(manager: m, size: 28) }
                Text(headline(results)).aircFont(AircFont.title3).foregroundStyle(theme.surfaceText.color)
                    .testAnchor("onboarding.pm.headline")
            }
            AircGroup {
                ForEach(results) { r in
                    HStack(spacing: 12) {
                        Image(systemName: r.present ? "checkmark.circle.fill" : "minus.circle")
                            .foregroundStyle(r.present ? theme.accent.color : theme.surfaceTextSecondary.color).frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.profileName).aircFont(AircFont.body).foregroundStyle(theme.surfaceText.color).lineLimit(1)
                            Text(r.message).aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if !r.present {
                            Button("Open in Web Store") { model.onPasswordManagerOpenStore?(r.profileID) }
                                .buttonStyle(.airc(.secondary, size: .small))
                                .testAnchor("onboarding.pm.store." + r.profileID)
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .testAnchor("onboarding.pm.result." + r.profileID)
                }
            }
            if !model.pmSavingTurnedOff.isEmpty {
                Text("Airc won't offer to save or fill passwords in \(model.pmSavingTurnedOff.count == 1 ? "that profile" : "those profiles"). Settings › Passwords turns it back on.")
                    .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .testAnchor("onboarding.pm.savingOff")
            }
        }
    }

    private func headline(_ results: [PasswordManagerResult]) -> String {
        let name = chosen?.name ?? "The extension"
        let n = results.filter(\.present).count
        if n == results.count { return results.count == 1 ? "\(name) is in." : "\(name) is in all \(n) profiles." }
        if n == 0 { return "\(name) wasn't added." }
        return "\(name) is in \(n) of \(results.count) profiles."
    }

    // MARK: Actions

    @ViewBuilder private var actions: some View {
        if model.pmResults != nil {
            Button("Continue") { model.onPasswordManagerContinue?() }.buttonStyle(.airc(.primary, size: .large))
                .keyboardShortcut(.defaultAction).testAnchor("onboarding.primary")
        } else if model.pmInstalling {
            Button("Adding…") {}.buttonStyle(.airc(.primary, size: .large)).disabled(true)
        } else {
            Button("Not now") { model.onPasswordManagerNotNow?() }.buttonStyle(.airc(.secondary, size: .large))
                .testAnchor("onboarding.pm.notNow")
            Button(primaryTitle) { model.onPasswordManagerInstall?() }
                .buttonStyle(.airc(.primary, size: .large))
                .disabled(!primaryEnabled)
                .keyboardShortcut(.defaultAction)
                .testAnchor("onboarding.primary")
        }
    }

    private var primaryTitle: String {
        guard let m = chosen else { return "Continue" }
        return m.isBuiltin ? "Use Airc's Own" : "Add \(m.name)"
    }

    private var primaryEnabled: Bool {
        guard let m = chosen else { return false }
        return m.isBuiltin || (model.extensionsAvailable && !model.pmChosenProfiles.isEmpty)
    }

    /// The engine's permission review for each profile, on this window (no browser window during the first run).
    @ViewBuilder private var review: some View {
        if let r = model.pmReview {
            ZStack {
                Color.black.opacity(theme.isDark ? 0.40 : 0.22).onTapGesture { r.onAnswer?(false) }
                ExtensionInstallCard(model: r)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(r.ui.surface.color))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(r.ui.surfaceBorder.color, lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
                    .testAnchor("onboarding.pm.review")
            }
            .transition(.opacity)
        }
    }
}

/// A manager's tile: a coloured rounded square with its initial (or a symbol). No vendor artwork.
struct PasswordManagerIcon: View {
    let manager: PasswordManager
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(manager.tint.color)
            if let s = manager.symbol {
                Image(systemName: s).font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(.white)
            } else {
                Text(manager.letter).font(.system(size: size * 0.55, weight: .bold, design: .rounded))
                    .foregroundStyle(manager.id == "keeper" ? Color.black : Color.white)
            }
        }
        .frame(width: size, height: size)
    }
}

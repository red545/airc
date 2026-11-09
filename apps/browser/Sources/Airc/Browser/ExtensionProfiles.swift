// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircKit
import AircDesign
import SwiftUI

struct ExtensionProfileResult {
    let profileID: String
    let profileName: String
    let message: String
    let tabID: String?
}

extension WindowController {
    static func extensionStoreURL(_ id: String) -> URL? {
        guard id.count == 32, id.allSatisfy({ ("a"..."p").contains(String($0)) }) else { return nil }
        return URL(string: "https://chromewebstore.google.com/detail/\(id)")
    }

    /// The engine currently has no host install-by-ID API. Each destination gets the Web Store's
    /// normal permission review in its own profile; never copy extension files between profiles.
    func installExtensionInAllProfiles(_ id: String, completion: @escaping ([ExtensionProfileResult]) -> Void) {
        guard let engine = app?.engine, let url = Self.extensionStoreURL(id) else { return completion([]) }
        let destinations = store.orderedProfiles.filter { $0.id != currentProfileID }
        var results: [ExtensionProfileResult] = []
        func next(_ index: Int) {
            guard index < destinations.count else { completion(results); return }
            let profile = destinations[index]
            func record(_ message: String, tab: String? = nil) {
                results.append(.init(profileID: profile.id, profileName: profile.name, message: message, tabID: tab))
                next(index + 1)
            }
            profiles.whenLoaded(profile.id, { [self] loaded in
                if engine.installedExtensions(for: loaded).contains(where: { $0["id"] as? String == id }) {
                    record("Already installed — skipped")
                    return
                }
                do {
                    guard let space = store.orderedSpaces.first(where: { $0.profileID == profile.id }) else {
                        record("No Space in this profile — create a Space first")
                        return
                    }
                    if let tab = store.state.tabs.values.first(where: {
                        $0.profileID == profile.id && ExtensionStoreURL.matches($0.url, extensionID: id)
                    }) {
                        record("Web Store page already open — choose Add to Chrome", tab: tab.id)
                    } else {
                        let tab = try store.openTab(url: url.absoluteString, inSpace: space.id, activate: false, title: "Install extension")
                        record("Web Store page opened — choose Add to Chrome", tab: tab.id)
                    }
                } catch { record("Could not open Web Store: \(error.localizedDescription)") }
            }, failed: { record("Could not load this profile — try again") })
        }
        next(0)
    }

    func offerExtensionInAllProfiles(_ id: String, name: String) {
        installExtensionInAllProfiles(id) { [weak self] results in
            guard let self else { return }
            let sheet = NSWindow()
            sheet.contentViewController = NSHostingController(rootView:
                ExtensionProfileResults(name: name, results: results, done: { [weak self, weak sheet] in
                    guard let sheet else { return }
                    self?.window.endSheet(sheet)
                }).aircTheme(DesignTheme.default.resolved(systemIsDark: self.currentPalette.resolved.isDark)))
            self.window.beginSheet(sheet)
        }
    }
}

struct ExtensionProfileResults: View {
    let name: String
    let results: [ExtensionProfileResult]
    let done: () -> Void
    @Environment(\.aircTheme) private var theme
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Install \(name) in all profiles").aircFont(AircFont.title2)
                .fixedSize(horizontal: false, vertical: true)
            Text("Choose Add to Chrome in each profile’s Web Store tab to review its permissions.")
                .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            if results.isEmpty { Text("There are no other profiles.").aircFont(AircFont.body) }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(results, id: \.profileID) { result in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.profileName).aircFont(AircFont.body)
                            Text(result.message).aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: min(240, CGFloat(max(1, results.count)) * 72))
            HStack { Spacer(); Button("Done", action: done).buttonStyle(.airc(.secondary)).keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 480).background(theme.surface.color)
    }
}

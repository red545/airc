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
    var extensionID: String = ""
    var resultID: String { profileID + ":" + extensionID }
}

extension WindowController {
    static func extensionStoreURL(_ id: String) -> URL? {
        guard id.count == 32, id.allSatisfy({ ("a"..."p").contains(String($0)) }) else { return nil }
        return URL(string: "https://chromewebstore.google.com/detail/\(id)")
    }

    /// Each profile gets Chromium's ordinary permission review in the invoking browser window.
    /// The current window is the minimal host for profiles without a Space: no Space or tab is created.
    func installExtensionInAllProfiles(_ id: String, completion: @escaping ([ExtensionProfileResult]) -> Void) {
        installExtensions(store.orderedProfiles.map { (id, $0.id) }, completion: completion)
    }

    func installExtensions(_ requests: [(String, String)], completion: @escaping ([ExtensionProfileResult]) -> Void) {
        guard let app else { completion([]); return }
        guard !ExtensionInstallBatch.running else {
            completion([.init(profileID: "", profileName: "Extensions", message: "An installation is already in progress.", tabID: nil)])
            return
        }
        if !LaunchOptions.current.isAutomated { window.makeKeyAndOrderFront(nil) }
        else if !window.isVisible { window.orderFront(nil) }
        ExtensionInstallBatch.run(app: app, requests, parent: window, completion: completion)
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
            Text("Each profile has its own permission review. Cancelling one leaves the others available.")
                .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            if results.isEmpty { Text("There are no profiles to install into.").aircFont(AircFont.body) }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(results, id: \.resultID) { result in
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

/// A single prompt at a time across windows, the import checklist and onboarding's password manager step.
enum ExtensionInstallBatch {
    static var running = false
    /// While set, Chromium's install prompts go here instead of the browser window's review card (onboarding shows
    /// them on its own window).
    static var reviewer: (([String: Any], @escaping (Bool) -> Void) -> Void)?

    /// Installs each (extension ID, Airc profile ID) in turn, one permission review each, skipping profiles that have it
    /// already; `parent` hosts the engine's dialogs. A result per request.
    static func run(app: AppDelegate, _ requests: [(String, String)], parent: NSWindow,
                    completion: @escaping ([ExtensionProfileResult]) -> Void) {
        guard !running else {
            completion([.init(profileID: "", profileName: "Extensions", message: "An installation is already in progress.", tabID: nil)])
            return
        }
        let engine: BrowserEngine = app.engine, store: SpacesStore = app.store, profiles: ProfileHost = app.profiles
        running = true
        var results: [ExtensionProfileResult] = []
        func next(_ index: Int) {
            guard index < requests.count else {
                running = false
                completion(results)
                return
            }
            let (id, profileID) = requests[index]
            let name = store.state.profiles[profileID]?.name ?? "Profile"
            func record(_ message: String) {
                results.append(.init(profileID: profileID, profileName: name, message: message, tabID: nil, extensionID: id))
                DispatchQueue.main.async { next(index + 1) }
            }
            guard WindowController.extensionStoreURL(id) != nil else { record("Failed — invalid extension ID"); return }
            profiles.whenLoaded(profileID, { loaded in
                if engine.installedExtensions(for: loaded).contains(where: { $0["id"] as? String == id }) {
                    record("Already installed — skipped"); return
                }
                engine.installExtension(id, profile: loaded, parent: parent) { outcome in record(outcome.message) }
            }, failed: { record("Failed — could not load this profile") })
        }
        next(0)
    }
}

struct ExtensionInstallOutcome {
    let status: String
    let reason: String
    var message: String {
        switch status {
        case "installed": return "Installed"
        case "alreadyInstalled": return "Already installed — skipped"
        case "denied": return "Denied — not installed"
        case "blockedByPolicy": return "Blocked by policy" + (reason.isEmpty ? "" : " — " + reason)
        default: return "Failed" + (reason.isEmpty ? "" : " — " + reason)
        }
    }
}

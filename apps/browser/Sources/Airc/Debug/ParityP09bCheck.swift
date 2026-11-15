// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AppKit
import AircKit
#if canImport(AircCore)
import AircCore
#endif
extension SnapshotRunner {
    func parityP09bScenario() {
        #if canImport(AircCore)
        guard app?.engine is ChromiumEngine,
              let fixture = ProcessInfo.processInfo.environment["AIRC_EXTENSION_FIXTURE"],
              let id = try? String(contentsOfFile: fixture + "/id.txt", encoding: .utf8) else {
            check(false, "parityp09b: requires Chromium and a synthetic CRX fixture"); finish(); return
        }
        var first = "", second = "", denied = ""
        var prompts = 0
        let prior = ChromiumRuntime.extensionInstallHandler
        run { [self] in
            do {
                first = try c.store.createProfile(name: "Install One").id
                second = try c.store.createProfile(name: "Install Two").id
                denied = try c.store.createProfile(name: "Declined").id
            } catch { check(false, "parityp09b: synthetic profiles: \(error)") }
            ChromiumEngine.installFixture = fixture + "/fixture.crx"
            ChromiumRuntime.extensionInstallHandler = { prompt, resolve in
                prompts += 1
                self.check(prompt["permissions"] as? [String] != nil, "parityp09b: Chromium permission prompt")
                let directory = prompt["profileDirectory"] as? String
                self.check(directory != nil, "parityp09b: permission review identifies destination profile")
                self.c.reviewExtensionInstall(prompt) { resolve($0) }
                let expected = self.c.store.orderedProfiles.first { $0.engineDirectory == directory }?.name
                self.check(self.c.pendingExtensionReview?.model.profileName == expected,
                           "parityp09b: visible review names destination profile")
                DispatchQueue.main.async {
                    self.c.pendingExtensionReview?.model.onAnswer?(directory != self.c.store.state.profiles[denied]?.engineDirectory)
                }
            }
        }
        step { [self] done in
            c.installExtensions([(id, first), (id, second), (id, denied)]) { results in
                check(results.map(\.message) == ["Installed", "Installed", "Denied — not installed"],
                      "parityp09b: two installs and denied: \(results.map(\.message))")
                check(prompts == 3, "parityp09b: each new install asked for consent")
                for pid in [first, second, denied] {
                    let profile = c.profiles.engineProfile(for: pid)
                    let installed = profile.map { app?.engine.installedExtensions(for: $0).contains { $0["id"] as? String == id } ?? false } ?? false
                    check(installed == (pid != denied), "parityp09b: registry matches consent for each profile")
                }
                check(c.store.orderedSpaces.allSatisfy { ![first, second, denied].contains($0.profileID) },
                      "parityp09b: no-Space profiles need no new Space")
                done()
            }
        }
        step { [self] done in
            c.installExtensions([(id, first), (id, second)]) { results in
                check(results.allSatisfy { $0.message == "Already installed — skipped" } && prompts == 3,
                      "parityp09b: already installed skipped without prompts")
                done()
            }
        }
        step { [self] done in
            guard let profile = c.profiles.engineProfile(for: first) else { done(); return }
            app?.engine.installExtension(id, profile: profile, parent: c.window) { result in
                check(result.status == "alreadyInstalled" && prompts == 3, "parityp09b: engine also skips an installed ID")
                done()
            }
        }
        step { [self] done in
            c.installExtensions([("bad-id", first)]) { results in
                check(results.first?.message.contains("invalid extension ID") == true, "parityp09b: failed outcome")
                done()
            }
        }
        step { [self] done in
            ChromiumEngine.installFixture = fixture + "/missing.crx"
            c.installExtensions([(id, denied)]) { results in
                check(results.first?.message.hasPrefix("Failed — ") == true, "parityp09b: engine install failure includes a reason")
                ChromiumEngine.installFixture = fixture + "/fixture.crx"
                done()
            }
        }
        run { [self] in
            ChromiumRuntime.extensionInstallHandler = prior
            ChromiumEngine.installFixture = nil
            finish()
        }
        #else
        step { [self] done in
            c.profiles.whenLoaded(c.currentProfileID) { profile in
                self.app?.engine.installExtension(String(repeating: "a", count: 32), profile: profile, parent: self.c.window) { result in
                    self.check(result.status == "failed" && result.reason.contains("Chromium"), "parityp09b: WebKit reports unsupported extensions")
                    done()
                }
            }
        }
        run { [self] in finish() }
        #endif
    }
}
#endif

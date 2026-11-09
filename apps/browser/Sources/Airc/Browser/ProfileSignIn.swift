// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircKit

/// One app-wide probe, only while a pending card has an open sign-in tab in that profile.
final class ProfileSignInCoordinator {
    static let shared = ProfileSignInCoordinator()
    private var app: AppDelegate? { NSApp.delegate as? AppDelegate }
    private var probe: GoogleAccountProbe?
    private var timer: Timer?
    private var reading: [String: UUID] = [:]
    // Identity survives Google’s final redirect. Only explicit sign-in replaces a tracked tab.
    private var signInTabs: [String: String] = [:]
    private var policy = ProfileSignInPolling()
    private var refreshing = false
    private var lastEligible: Set<String> = []
    private(set) var pollingProfiles: Set<String> = []

    func restart(_ id: String, tabID: String) {
        signInTabs[id] = tabID
        policy.restart(id)
    }

    func tabNavigated(_ tabID: String) {
        guard let id = signInTabs.first(where: { $0.value == tabID })?.key,
              let address = app?.store.tab(tabID)?.url, let url = URL(string: address),
              url.host != nil, !Self.isSignIn(url), eligible.contains(id) else { return }
        // One prompt account read after Google redirects, without resetting the five-minute bound.
        if policy.requestFinalProbe(id, now: Date()) { refresh() }
    }

    private var eligible: Set<String> {
        guard let app, let store = app.store else { return [] }
        let pending = Set(store.state.profiles.values.compactMap { profile -> String? in
            guard profile.signInState == .signingIn,
                  app.controllers.contains(where: { c in
                      store.spaces(usingProfile: profile.id).contains { c.showsSignInCard(spaceID: $0.id) }
                  }) else { return nil }
            return profile.id
        })
        signInTabs = signInTabs.filter { store.profile($0.key) != nil }
        // After relaunch, resume only if the pending card and an actual sign-in tab both exist.
        // A closed tracked tab must not be replaced by some other Google tab in the same session.
        for id in pending where signInTabs[id] == nil {
            signInTabs[id] = store.state.tabs.values.first {
                $0.profileID == id && URL(string: $0.url).map(Self.isSignIn) == true
            }?.id
        }
        return Set(pending.filter { id in
            signInTabs[id].flatMap { store.tab($0) }?.profileID == id
        })
    }

    static func isSignIn(_ url: URL) -> Bool {
        #if AIRC_TESTING
        if let mock = GoogleAccountProbe.testURL, url.host == mock.host, url.port == mock.port { return true }
        #endif
        return url.scheme == "https" && url.host == "accounts.google.com"
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        timer?.invalidate(); timer = nil
        let ids = eligible
        if ids != lastEligible {
            lastEligible = ids
            stopProbe() // do not let a queued probe start after its sign-in tab was closed
        }
        guard let app, GoogleAccountProbe.listAccountsURL != nil else { return stopProbe() }
        let now = Date()
        let due = policy.due(ids.subtracting(reading.keys), now: now)
        guard let next = policy.next(ids, now: now) else { return stopProbe() }
        pollingProfiles = ids
        timer = Timer.scheduledTimer(withTimeInterval: max(0.1, next.timeIntervalSince(now)), repeats: false) { [weak self] _ in self?.refresh() }
        for id in due {
            let request = UUID()
            reading[id] = request
            app.profiles.whenLoaded(id, { [weak self] profile in
                guard let self, self.reading[id] == request else { return }
                guard self.eligible.contains(id), self.policy.isActive(id, now: Date()), let app = self.app else {
                    self.reading[id] = nil
                    return
                }
                let probe = self.probe ?? GoogleAccountProbe(engine: app.engine)
                self.probe = probe
                probe.read(profile) { [weak self] accounts in
                    guard let self, self.reading[id] == request else { return }
                    self.reading[id] = nil
                    if self.eligible.contains(id), self.policy.isActive(id, now: Date()) {
                        try? self.app?.store.receiveGoogleSignIn(id, accounts: accounts)
                    }
                    self.refresh()
                }
            }, failed: { [weak self] in
                guard self?.reading[id] == request else { return }
                self?.reading[id] = nil
            })
        }
    }

    private func stopProbe() {
        pollingProfiles = []
        let old = probe; probe = nil
        reading.removeAll()
        old?.cancel()
    }
}

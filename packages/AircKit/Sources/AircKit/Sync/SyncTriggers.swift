// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

/// When the app syncs besides Sync Now (SyncCenter). With the push entitlement (`com.apple.developer.aps-environment`,
/// which release signing adds when the provisioning profile grants it), CloudKit's silent pushes for the zone's
/// subscription bring other Macs' changes within seconds. The fallbacks stay on either way, because pushes are best
/// effort: becoming active (at most every `activationInterval`), every `fallbackInterval`, and `localChangeDelay` after
/// a store change.
public struct SyncTriggers: Equatable, Sendable {
    /// Register for remote notifications (only with the entitlement: without it the request fails).
    public var registersForPushes: Bool
    public var fallbackInterval: TimeInterval = 600
    public var activationInterval: TimeInterval = 20
    public var localChangeDelay: TimeInterval = 1.5

    public static func plan(cloudKit: Bool, pushEntitlement: Bool) -> SyncTriggers {
        SyncTriggers(registersForPushes: cloudKit && pushEntitlement)
    }

    /// A CloudKit push for the sidebar zone's subscription (or one without a subscription ID, which a fetch also
    /// covers). Other apps' or other subscriptions' pushes are ignored.
    public static func isSidebarPush(_ userInfo: [AnyHashable: Any], subscription: String) -> Bool {
        guard let ck = userInfo["ck"] as? [AnyHashable: Any] else { return false }
        if let fetch = ck["fet"] as? [AnyHashable: Any], let id = fetch["sid"] as? String { return id == subscription }
        return true
    }
}

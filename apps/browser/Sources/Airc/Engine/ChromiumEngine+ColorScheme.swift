// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit

#if canImport(AircCore)
import AircCore

// PageColorScheme on Chromium: AircTab.preferredColorScheme (engine/core/airc_color_scheme.h; 0 the engine's own, 1
// light, 2 dark) overrides Chrome's choice, which follows the browser window's colour mode and is otherwise only
// recomputed after a navigation. Read and set by name, so the app also builds against an engine without it (the page
// then keeps the engine's own scheme).
extension ChromiumTab: EngineColorSchemeTab {
    static let hasPreferredColorScheme = AircTab.instancesRespond(to: NSSelectorFromString("setPreferredColorScheme:"))

    var pageColorScheme: PageColorScheme.Scheme {
        get {
            guard Self.hasPreferredColorScheme, let n = core.value(forKey: "preferredColorScheme") as? Int else { return .engine }
            return PageColorScheme.Scheme(rawValue: n) ?? .engine
        }
        set {
            guard Self.hasPreferredColorScheme else { return }
            core.setValue(newValue.rawValue, forKey: "preferredColorScheme")
        }
    }
}
#endif

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircImport
import Foundation
import ObjectiveC

// P22b: the engine's import kinds and its localStorage import (engine/PROFILE-SERVICES.md), found at run time: an
// engine framework from before them has neither, and the app still builds and runs against it, importing what that
// engine takes (website passwords and unpartitioned cookies) and saying why the rest stays in Arc.

#if canImport(AircCore)
import AircCore

enum EngineSiteStorage {
    /// `AircProfile.importKinds`, the engine's own list; empty on an engine without it.
    static var importKinds: ImportKinds {
        let selector = NSSelectorFromString("importKinds")
        guard let method = class_getClassMethod(AircProfile.self, selector) else { return [] }
        typealias Getter = @convention(c) (AnyClass, Selector) -> Unmanaged<NSArray>?
        let get = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        return ImportKinds(names: get(AircProfile.self, selector)?.takeUnretainedValue() as? [String] ?? [])
    }

    /// Hands `sites` ({origin, items: [{key, value}]}) to the profile's `importLocalStorage:completion:`. Nothing to send,
    /// or an engine without it, answers at once (the read only includes sites with an engine that takes them).
    static func importLocalStorage(_ sites: [[String: Any]], into profile: EngineProfile, completion: @escaping ([String: Any]) -> Void) {
        guard !sites.isEmpty else { return completion([:]) }
        let selector = NSSelectorFromString("importLocalStorage:completion:")
        guard let core = (profile as? ChromiumProfile)?.core, let method = class_getInstanceMethod(AircProfile.self, selector) else {
            return completion(["error": "this engine can't take sites' storage"])
        }
        typealias Call = @convention(c) (AnyObject, Selector, NSArray, @convention(block) (NSDictionary) -> Void) -> Void
        let call = unsafeBitCast(method_getImplementation(method), to: Call.self)
        // A block value (not a closure literal) so the engine may keep it until it answers.
        let done: @convention(block) (NSDictionary) -> Void = { result in completion(result as? [String: Any] ?? [:]) }
        call(core, selector, sites as NSArray, done)
    }
}
#endif

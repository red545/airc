// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

/// Optional engine capabilities. WebKit has no capture-source replacement API;
/// UI checks the capability without importing either engine framework.
protocol EngineCallSharingProfile: EngineProfile {
    func callShares() -> [[String: Any]]
    func observeCallShares(_ observer: (([[String: Any]]) -> Void)?)
}
protocol EngineCallSharingTab: EngineTab {
    func canShareInstead(of capturer: EngineTab) -> Bool
    func shareInstead(of capturer: EngineTab) -> Bool
    func stopSharing() -> Bool
}

#if canImport(AircCore)
import AircCore

extension ChromiumProfile: EngineCallSharingProfile {
    func callShares() -> [[String: Any]] { core.callShares() }
    func observeCallShares(_ observer: (([[String: Any]]) -> Void)?) { core.observeCallShares(observer) }
}
extension ChromiumTab: EngineCallSharingTab {
    func canShareInstead(of capturer: EngineTab) -> Bool {
        guard let capturer = capturer as? ChromiumTab else { return false }
        return core.canShareThisTabInstead(for: capturer.core)
    }
    func shareInstead(of capturer: EngineTab) -> Bool {
        guard let capturer = capturer as? ChromiumTab else { return false }
        return core.shareThisTabInstead(for: capturer.core)
    }
    func stopSharing() -> Bool { core.stopCapture() }
}
#endif

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation
#if canImport(AircCore)
import AircCore
extension ChromiumTab: CastEngineTab {
    var castProfileKey: String { core.profile.map { $0.path + ($0.offTheRecord ? ":private" : "") } ?? "" }
    var castAvailable: Bool { !isClosed }
    func showCastPicker() -> Bool {
        core.profile?.watchCastRoutes()
        return core.showCastDialog()
    }
    func startCast(_ dialog: Int32, sink: String, mode: Int32) {
        AircEngine.startCasting(dialog, sink: sink, mode: mode)
    }
}
#endif
enum CastEngineBridge {
    static func stop(_ route: String) {
        #if canImport(AircCore)
        AircEngine.terminateCastRoute(route)
        #endif
    }
    static func close(_ dialog: Int32) {
        #if canImport(AircCore)
        AircEngine.closeCastDialog(dialog)
        #endif
    }
}

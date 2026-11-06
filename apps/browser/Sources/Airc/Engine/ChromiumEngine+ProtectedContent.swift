// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if canImport(AircCore)
import AircCore

extension ChromiumEngine {
    var supportsProtectedContent: Bool { true }
    var protectedContentEnabled: Bool {
        get { core.protectedContentEnabled }
        set { core.protectedContentEnabled = newValue }
    }
}
#endif

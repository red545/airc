// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation
import AircCrashLog

/// Local diagnostics only, with no page data or stderr (which can contain URLs).
enum CrashLog {
    static func install() {
        #if AIRC_TESTING
        let url = AppPaths.dataDirectory.appendingPathComponent("Crash.log")
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unbundled"
        url.path.withCString { path in build.withCString { airc_crash_log_install(path, $0) } }
        #endif
    }
}

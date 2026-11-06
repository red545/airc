// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation
import AircCrashLog

/// Fatal signals of the browser process (AircCrashLog/CrashLog.c): every build writes a compact crash record to
/// `CrashRecords/` in the data folder at signal time, which the next launch sends as a crash report when sharing is on
/// (AppCrashReports). Dev and test builds also write Crash.log for people. Neither holds page data, URLs or paths.
enum CrashLog {
    /// `record` (this run's, empty unless it crashes) and the last three crashes, `record.1` … `record.3`.
    static var recordsDirectory: URL { AppPaths.dataDirectory.appendingPathComponent("CrashRecords", isDirectory: true) }

    /// main.swift, once the data folder is known, and again after Chromium starts (which installs its own handlers).
    static func install() {
        let records = recordsDirectory
        try? FileManager.default.createDirectory(at: records, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let info = Bundle.main.infoDictionary ?? [:]
        let build = info["CFBundleVersion"] as? String ?? "unbundled"
        let version = info["CFBundleShortVersionString"] as? String ?? ""
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let os = "\(v.majorVersion).\(v.minorVersion)"
        #if AIRC_TESTING
        let log: String? = AppPaths.dataDirectory.appendingPathComponent("Crash.log").path
        #else
        let log: String? = nil
        #endif
        let bundle = Bundle.main.bundlePath
        records.path.withCString { dir in
            bundle.withCString { bundle in
                version.withCString { version in
                    build.withCString { build in
                        os.withCString { os in
                            if let log {
                                log.withCString { airc_crash_install(dir, $0, bundle, version, build, os) }
                            } else {
                                airc_crash_install(dir, nil, bundle, version, build, os)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Whether our handlers are the ones installed now, and how many signals hand on to an earlier handler.
    static var handlers: (installed: Bool, chained: Int, images: Int) {
        (airc_crash_handlers_installed() != 0, Int(airc_crash_chained_handlers()), Int(airc_crash_image_count()))
    }
}

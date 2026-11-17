// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import Foundation
import Security

/// Executes a staged, validated update once so macOS's first-launch checks of the new code happen now instead of at the
/// next launch (updatewarm: the first launch after an update then starts as fast as any other; AircKit's UpdateWarmup
/// says how much that is and where Sparkle stages it).
///
/// Runs once per staged bundle, off the main thread, after Sparkle has validated the update. Before executing anything
/// it checks the staged code itself (strict, all nested code and resources) against Airc's own signing identity: the
/// same team and bundle identifier when Airc is Developer ID signed, so a bundle swapped in after Sparkle's check is
/// never run. The probe exits on the first line of `main` (no window, profile or network), its output goes nowhere, and
/// it is killed after `UpdateWarmup.probeTimeout`. Nothing waits for it: quitting and installing go ahead as before.
final class UpdateWarmupRunner {
    static let shared = UpdateWarmupRunner()
    private let queue = DispatchQueue(label: "airc.update-warmup", qos: .utility)
    private var warmed = Set<String>()
    private let lock = NSLock()

    /// A/B on signed builds (artifacts/updatewarm): AIRC_UPDATE_WARMUP=0 leaves the staged update cold, as before;
    /// `check` checks the signature but runs nothing. Both can only do less.
    static var enabled: Bool { ProcessInfo.processInfo.environment["AIRC_UPDATE_WARMUP"] != "0" }
    static var checkOnly: Bool { ProcessInfo.processInfo.environment["AIRC_UPDATE_WARMUP"] == "check" }

    /// Finds the staged bundle of `version` (CFBundleVersion) and warms it; `log` gets one line per outcome.
    func warm(version: String, log: @escaping (String) -> Void) {
        guard Self.enabled else { return log("warm-up: off") }
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        queue.async { [self] in
            guard let app = UpdateWarmup.stagedBundle(in: Self.installationDirectories(bundleID: bundleID),
                                                     bundleIdentifier: bundleID, version: version) else {
                return log("warm-up: no staged bundle for \(version)")
            }
            lock.lock()
            let fresh = warmed.insert(app.standardizedFileURL.path).inserted
            lock.unlock()
            guard fresh else { return }
            let started = Date()
            if let problem = Self.checkSignature(app) {
                return log("warm-up: skipped, staged code not accepted (\(problem))")
            }
            let checked = Date().timeIntervalSince(started)
            if Self.checkOnly { return log(String(format: "warm-up: signature checked in %.2f s, no probe (check only)", checked)) }
            guard let exe = UpdateWarmup.mainExecutable(of: app) else { return log("warm-up: skipped, no main executable") }
            let (status, seconds) = Self.runProbe(exe)
            log(String(format: "warm-up: signature checked in %.2f s, probe %@ in %.2f s", checked, status, seconds))
        }
    }

    /// Sparkle's installer and Airc can see different caches folders (a test's CFFIXED_USER_HOME applies to Airc only),
    /// so look in both.
    private static func installationDirectories(bundleID: String) -> [URL] {
        var caches: [URL] = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        if let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir {
            caches.append(URL(fileURLWithPath: String(cString: home), isDirectory: true).appendingPathComponent("Library/Caches"))
        }
        return caches.map { UpdateWarmup.installationDirectory(caches: $0, bundleIdentifier: bundleID) }
    }

    /// nil when the staged bundle is validly signed by the same identity as this app; otherwise why not.
    private static func checkSignature(_ app: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &staticCode) == errSecSuccess, let staticCode else { return "no code" }
        guard let requirement = requirement() else { return "no requirement for this build" }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        var error: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(staticCode, flags, requirement, &error)
        return status == errSecSuccess ? nil : "OSStatus \(status)"
    }

    /// Developer ID builds: Apple-anchored, this app's team and bundle identifier. Unsigned or ad-hoc dev builds have no
    /// team, and Sparkle's EdDSA check is all that vouches for their updates: accept any valid signature with the same
    /// identifier (the probe still exits at once).
    private static func requirement() -> SecRequirement? {
        var me: SecCode?
        var staticMe: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &staticMe) == errSecSuccess, let staticMe,
              SecCodeCopySigningInformation(staticMe, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let d = info as? [String: Any], let identifier = d[kSecCodeInfoIdentifier as String] as? String else { return nil }
        let quoted = identifier.replacingOccurrences(of: "\"", with: "")
        let text: String
        if let team = d[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty {
            let t = team.replacingOccurrences(of: "\"", with: "")
            text = "identifier \"\(quoted)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(t)\""
        } else {
            text = "identifier \"\(quoted)\""
        }
        var requirement: SecRequirement?
        return SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess ? requirement : nil
    }

    /// Runs the probe and waits for it (on the warm-up queue), killing it after the timeout.
    private static func runProbe(_ exe: URL) -> (String, TimeInterval) {
        let process = Process()
        process.executableURL = exe
        process.arguments = UpdateWarmup.probeArguments
        process.currentDirectoryURL = URL(fileURLWithPath: "/", isDirectory: true)
        // A minimal environment: nothing that selects a profile, a test scenario or a data folder.
        process.environment = ["PATH": "/usr/bin:/bin", "TMPDIR": NSTemporaryDirectory()]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        let started = Date()
        do { try process.run() } catch { return ("not started (\(error.localizedDescription))", 0) }
        if done.wait(timeout: .now() + UpdateWarmup.probeTimeout) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            _ = done.wait(timeout: .now() + 5)
            return ("killed after timeout", Date().timeIntervalSince(started))
        }
        return ("exit \(process.terminationStatus)", Date().timeIntervalSince(started))
    }
}

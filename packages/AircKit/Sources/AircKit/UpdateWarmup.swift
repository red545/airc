// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

/// Warm-up of a staged update (updatewarm, artifacts/updatewarm/REPORT.md).
///
/// The first exec of a newly written copy of the signed app spends ~4 s in macOS before `main` (artifacts/prelaunch,
/// §3), and those per-file results survive a rename. Sparkle 2.10 installs by renaming (swapping) the bundle it
/// extracted and validated, and its first install stage already runs `gktool scan` on it (on macOS 14.4+, same volume,
/// same team): that takes most of the ~4 s before Airc quits. What it leaves is ~0.1 s on the first launch (pre-main
/// 140–223 ms vs 54–68 ms warm, artifacts/updatewarm). Executing the staged bundle once removes that too, and the
/// whole ~4 s wherever Sparkle skips its scan. A signature check alone (SecStaticCodeCheckValidity) warms nothing.
///
/// This part only finds the staged bundle. Sparkle 2's installer extracts into
/// `<user caches>/<bundle id>/org.sparkle-project.Sparkle/Installation/<random>/<random>/<name>.app`, validates it
/// (EdDSA, code signature) and runs its first install stage there before it tells the app the update is ready
/// (`willInstallUpdateOnQuit`); old folders stay up to 10 days, so several can exist.
public enum UpdateWarmup {
    /// The probe's arguments: the blocking lists' check child (BlockingRuleCompiler) with a path that can't exist. It
    /// exits (status 1, no such list) on the first line of `main` with no window, no profile and no network. Every
    /// version since that child exists (e53a1d72, before this warm-up) has it, so any update target can be probed.
    public static let probeArguments = ["--airc-check-blocking-rules", "/dev/null/airc-update-warmup"]
    /// Seconds the probe may take before it is killed (a cold first exec takes 4–6 s on the build Mac).
    public static let probeTimeout: TimeInterval = 30

    /// Sparkle's installation folder for `bundleIdentifier` under one caches folder (SPULocalCacheDirectory).
    public static func installationDirectory(caches: URL, bundleIdentifier: String) -> URL {
        var id = bundleIdentifier
        let bad = [".app", ".service", ".xpc", ".appex", ".bundle", ".plugin", ".saver", ".kext"]
        if bad.contains(where: { id.lowercased().hasSuffix($0) }) { id += ".sparkle" }
        return caches.appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("org.sparkle-project.Sparkle", isDirectory: true)
            .appendingPathComponent("Installation", isDirectory: true)
    }

    /// The newest staged app under `installationDirectories` whose Info.plist has this bundle identifier and build
    /// version (CFBundleVersion, Sparkle's versionString). Symbolic links are never followed or returned.
    public static func stagedBundle(in installationDirectories: [URL], bundleIdentifier: String, version: String,
                                    fileManager: FileManager = .default) -> URL? {
        var best: (url: URL, date: Date)?
        var seen = Set<String>()
        for root in installationDirectories {
            for outer in children(of: root, fileManager) {
                for inner in children(of: outer, fileManager) {
                    for app in children(of: inner, fileManager) where app.pathExtension == "app" {
                        let key = app.standardizedFileURL.path
                        guard seen.insert(key).inserted, isDirectoryNotLink(app, fileManager),
                              let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
                              info["CFBundleIdentifier"] as? String == bundleIdentifier,
                              info["CFBundleVersion"] as? String == version else { continue }
                        let date = (try? fileManager.attributesOfItem(atPath: app.path)[.modificationDate] as? Date) ?? .distantPast
                        if best == nil || date > best!.date { best = (app, date) }
                    }
                }
            }
        }
        return best?.url
    }

    /// The staged bundle's main executable from its Info.plist, only when it is a regular file inside Contents/MacOS.
    public static func mainExecutable(of app: URL, fileManager: FileManager = .default) -> URL? {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let name = info["CFBundleExecutable"] as? String, !name.isEmpty, !name.contains("/"), name != "..", name != "."
        else { return nil }
        let exe = app.appendingPathComponent("Contents/MacOS", isDirectory: true).appendingPathComponent(name)
        guard let attrs = try? fileManager.attributesOfItem(atPath: exe.path),
              attrs[.type] as? FileAttributeType == .typeRegular, fileManager.isExecutableFile(atPath: exe.path) else { return nil }
        return exe
    }

    private static func children(of dir: URL, _ fm: FileManager) -> [URL] {
        guard isDirectoryNotLink(dir, fm) else { return [] }
        return (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
    }

    private static func isDirectoryNotLink(_ url: URL, _ fm: FileManager) -> Bool {
        (try? fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeDirectory
    }
}

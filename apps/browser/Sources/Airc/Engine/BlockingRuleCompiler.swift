// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation
import WebKit

/// The blocking lists' big compiles run in a short-lived child process of Airc's own executable (webkitmem,
/// artifacts/webkitmem/REPORT.md).
///
/// Converting EasyList + EasyPrivacy to WebKit rules and compiling them allocates a few hundred MB for seconds and frees
/// nearly all of it. In the main process the system allocator kept those freed blocks in its large-block cache, counted
/// in the footprint for minutes (the WebKit engine's main process measured 84–268 MB at the same moment of identical
/// launches, ~40 MB of it live). Neither `malloc_zone_pressure_relief` nor the memory-pressure handler empties that
/// cache, and turning it off for the whole app made New Space 5–10× slower. In a child the memory ends with the process.
///
/// - `--airc-compile-content-rules <store> <identifier> <list file>`: converts the list and compiles it into the
///   WKContentRuleListStore at <store> (the main process then only looks it up). Exit 0 compiled, 3 empty conversion,
///   1 failed.
/// - `--airc-check-blocking-rules <list file>`: the list check's adblock compile (exit 0 valid, 1 invalid).
///
/// Anything but a success in the child (an invalid list, a launch error, a crash, the timeout) falls back to the
/// previous in-process path, so the result is the same either way.
enum BlockingRuleCompiler {
    static let compileArgument = "--airc-compile-content-rules"
    static let checkArgument = "--airc-check-blocking-rules"
    static let timeout: TimeInterval = 300
    enum Outcome { case compiled, empty, failed, unavailable }

    static var enabled: Bool {
        #if AIRC_TESTING
        // A/B (artifacts/webkitmem): AIRC_WEBKITMEM_BASELINE=1 is the previous path, every compile in the main process;
        // AIRC_WEBKITMEM_CHILD=0 only this.
        let env = ProcessInfo.processInfo.environment
        return env["AIRC_WEBKITMEM_BASELINE"] != "1" && env["AIRC_WEBKITMEM_CHILD"] != "0"
        #else
        return true
        #endif
    }

    // MARK: Child side (main.swift calls this before anything else)

    static func runIfChild() {
        let a = CommandLine.arguments
        if a.count == 3, a[1] == checkArgument { exit(childCheck(file: a[2])) }
        if a.count == 5, a[1] == compileArgument { exit(childCompile(store: a[2], identifier: a[3], file: a[4])) }
    }
    private static func read(_ file: String) -> String? {
        FileManager.default.contents(atPath: file).flatMap { String(data: $0, encoding: .utf8) }
    }
    private static func childCheck(file: String) -> Int32 {
        guard let text = read(file) else { return 1 }
        return (try? BlockingFilter.compile(text)) != nil ? 0 : 1
    }
    private static func childCompile(store path: String, identifier: String, file: String) -> Int32 {
        guard let text = read(file), let json = try? BlockingFilter.webKitRules(text) else { return 1 }
        // Our converter serializes an empty result as this compact array; WebKit rejects it (WebKitBlocking: .empty).
        if json == Data("[]".utf8) { return 3 }
        guard let rules = String(data: json, encoding: .utf8),
              let store = WKContentRuleListStore(url: URL(fileURLWithPath: path, isDirectory: true)) else { return 1 }
        var result: Int32?
        store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: rules) { list, _ in
            result = list == nil ? 1 : 0
        }
        while result == nil { _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1)) }
        return result!
    }

    // MARK: Main process side

    /// Compiles `text` into the store at `directory` under `identifier` in a child. `.unavailable`: the child couldn't
    /// run or didn't finish; the caller compiles in process instead.
    static func compile(text: String, identifier: String, directory: URL, completion: @escaping (Outcome) -> Void) {
        guard enabled else { return completion(.unavailable) }
        run(text: text, directory: directory, arguments: { [compileArgument, directory.path, identifier, $0] }) { status in
            switch status {
            case 0: completion(.compiled)
            case 3: completion(.empty)
            case 1: completion(.failed)
            default: completion(.unavailable)
            }
        }
    }

    /// Whether adblock compiles `text` (the list check), in a child; in process if the child can't run.
    static func check(_ text: String) async -> Bool {
        let directory = AppPaths.dataDirectory.appendingPathComponent("Blocking/WebKit", isDirectory: true)
        if enabled {
            let status: Int32? = await withCheckedContinuation { resume in
                Task { @MainActor in
                    run(text: text, directory: directory, arguments: { [checkArgument, $0] }) { resume.resume(returning: $0) }
                }
            }
            if status == 0 { return true }
        }
        // Invalid in the child, or no child: the previous in-process check decides.
        return (try? await Task.detached(priority: .utility) { try BlockingFilter.compile(text) }.value) != nil
    }

    /// Writes the list to a private file next to the store, runs the child and reports its exit status on the main
    /// queue (nil: no child, a crash or the timeout). The file is removed in every case.
    private static func run(text: String, directory: URL, arguments: (String) -> [String],
                            completion: @escaping (Int32?) -> Void) {
        guard let executable = Bundle.main.executableURL else { return completion(nil) }
        let file = directory.appendingPathComponent(".compile-\(UUID().uuidString).txt")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file, options: [.atomic])
        } catch { return completion(nil) }
        final class Once { var done = false }
        let once = Once()
        let step = LaunchTimeline.begin("blocking compile child \(arguments("").first ?? "")")
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments(file.path)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.qualityOfService = .userInitiated
        func end(_ status: Int32?) {
            guard !once.done else { return }
            once.done = true
            step()
            LaunchTimeline.mark("blocking compile child exit \(status.map { "\($0)" } ?? "none")")
            try? FileManager.default.removeItem(at: file)
            completion(status)
        }
        process.terminationHandler = { p in
            let status = p.terminationReason == .exit ? p.terminationStatus : nil
            DispatchQueue.main.async { end(status) }
        }
        do { try process.run() } catch { return end(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            guard !once.done else { return }
            process.terminate()
            end(nil)
        }
    }
}

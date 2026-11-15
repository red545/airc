// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

/// One-click setup for AI apps (Settings › Agents › Set up; docs/user/agents.md).
///
/// Every config points at a path that survives app updates and moves: `<data folder>/bin/airc-mcp`, a link Airc keeps
/// pointing at the helper inside its own bundle (Contents/Helpers/airc-mcp) each time agents start. An update replaces
/// the bundle and the link still resolves; a moved app fixes the link at its next launch.
enum AgentSetup {
    static var bundledHelper: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/airc-mcp") }

    static func stableHelper(dataDir: URL = AppPaths.dataDirectory) -> URL {
        dataDir.appendingPathComponent("bin/airc-mcp")
    }

    static var defaultDataDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Airc", isDirectory: true)
    }

    /// Points the stable link at this bundle's helper (when the bundle has one).
    static func refreshStableHelper(dataDir: URL = AppPaths.dataDirectory) {
        let target = bundledHelper
        guard FileManager.default.isExecutableFile(atPath: target.path) else { return }
        let link = stableHelper(dataDir: dataDir)
        let fm = FileManager.default
        if let current = try? fm.destinationOfSymbolicLink(atPath: link.path), current == target.path { return }
        try? fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: link)
        try? fm.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
    }

    /// The helper path configs use: the stable link when it works, else the bundle's own helper.
    static var helperPath: String {
        let link = stableHelper()
        if FileManager.default.isExecutableFile(atPath: link.path) { return link.path }
        return bundledHelper.path
    }

    /// `--data-dir` only for an Airc that doesn't use the usual folder (a test or a separate agent-only Airc).
    static var dataArgs: [String] {
        AppPaths.dataDirectory.standardizedFileURL.path == defaultDataDir.standardizedFileURL.path
            ? [] : ["--data-dir", AppPaths.dataDirectory.standardizedFileURL.path]
    }

    static func args(client: String) -> [String] { dataArgs + ["--client", client] }

    static func shellQuote(_ s: String) -> String {
        s.allSatisfy { $0.isLetter || $0.isNumber || "/._-".contains($0) } ? s : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Claude Code

    static var claudeCodeCommand: String {
        (["claude", "mcp", "add", "--scope", "user", "airc", "--", helperPath] + args(client: "claude-code")).map(shellQuote).joined(separator: " ")
    }

    /// Claude Code's CLI where its installers put it.
    static func findClaudeCLI(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let candidates = [home.appendingPathComponent(".local/bin/claude"), home.appendingPathComponent(".claude/local/claude"),
                          URL(fileURLWithPath: "/opt/homebrew/bin/claude"), URL(fileURLWithPath: "/usr/local/bin/claude"),
                          home.appendingPathComponent(".npm-global/bin/claude"), home.appendingPathComponent(".bun/bin/claude")]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    enum Outcome: Equatable {
        case added(backup: String?)
        case alreadyThere
        case failed(String)

        var message: String {
            switch self {
            case .added(let backup): return backup.map { "Added. Your previous settings are saved as \(($0 as NSString).lastPathComponent)." } ?? "Added."
            case .alreadyThere: return "Airc is already set up there."
            case .failed(let why): return why
            }
        }
    }

    /// `claude mcp add --scope user airc -- <helper>`, run with the person's CLI. Answers on the main queue.
    static func addToClaudeCode(cli: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                completion: @escaping (Outcome) -> Void) {
        let p = Process()
        p.executableURL = cli
        p.arguments = ["mcp", "add", "--scope", "user", "airc", "--", helperPath] + args(client: "claude-code")
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", home.appendingPathComponent(".local/bin").path, "/usr/bin", "/bin",
                       env["PATH"] ?? ""].joined(separator: ":")
        env["HOME"] = home.path
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        DispatchQueue.global(qos: .userInitiated).async {
            do { try p.run() } catch {
                return DispatchQueue.main.async { completion(.failed("Couldn't start Claude Code's command: \(error.localizedDescription)")) }
            }
            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: killer)
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            killer.cancel()
            let outcome: Outcome
            if p.terminationStatus == 0 { outcome = .added(backup: nil) }
            else if text.lowercased().contains("already exists") { outcome = .alreadyThere }
            else { outcome = .failed("Claude Code said: " + String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))) }
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    // MARK: Claude Desktop

    #if AIRC_TESTING
    /// The demo clip (`--agent-demo=setup`): Settings' buttons write into this scratch home instead of the account's,
    /// so a recording never touches a real Claude config. Nil: the real home.
    static var homeOverride: URL?
    #endif

    /// The home Settings' setup buttons write into.
    static var home: URL {
        #if AIRC_TESTING
        if let homeOverride { return homeOverride }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static func claudeDesktopConfig(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }

    static var claudeDesktopInstalled: Bool {
        #if AIRC_TESTING
        if homeOverride != nil { return true }   // the demo's scratch home stands in for an installed Claude Desktop
        #endif
        return FileManager.default.fileExists(atPath: "/Applications/Claude.app")
            || FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Claude.app").path)
    }

    static func serverEntry(client: String) -> [String: Any] { ["command": helperPath, "args": args(client: client)] }

    /// Adds `mcpServers.airc` to Claude Desktop's config, keeping everything else in it. An existing file is copied
    /// next to itself first (`…json.airc-backup-<time>`); a file that isn't a JSON object is left alone.
    static func addToClaudeDesktop(home: URL = FileManager.default.homeDirectoryForCurrentUser, now: Date = Date()) -> Outcome {
        let file = claudeDesktopConfig(home: home)
        let fm = FileManager.default
        var root: [String: Any] = [:]
        var existing: Data?
        if fm.fileExists(atPath: file.path) {
            guard let data = try? Data(contentsOf: file) else { return .failed("Airc couldn't read Claude Desktop's settings. Nothing changed.") }
            existing = data
            if !data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return .failed("Claude Desktop's settings file isn't valid JSON, so Airc left it alone. Use “Other apps” to add Airc by hand.")
                }
                root = object
            }
        }
        if root["mcpServers"] != nil, !(root["mcpServers"] is [String: Any]) {
            return .failed("Claude Desktop's settings have an unexpected mcpServers entry, so Airc left them alone.")
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        let entry = serverEntry(client: "claude-desktop")
        if let current = servers["airc"] as? [String: Any], NSDictionary(dictionary: current).isEqual(to: entry) { return .alreadyThere }
        servers["airc"] = entry
        root["mcpServers"] = servers
        guard let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes]) else {
            return .failed("Airc couldn't write Claude Desktop's settings. Nothing changed.")
        }
        var backup: URL?
        do {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let existing {
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = "yyyyMMdd-HHmmss"
                let b = file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + ".airc-backup-" + f.string(from: now))
                try existing.write(to: b, options: .withoutOverwriting)
                backup = b
            }
            var text = out
            text.append(0x0A)
            try text.write(to: file, options: .atomic)
        } catch {
            return .failed("Airc couldn't write Claude Desktop's settings: \(error.localizedDescription)")
        }
        return .added(backup: backup?.path)
    }

    // MARK: Other apps

    /// The usual `mcpServers` shape (Cursor, Windsurf, VS Code's MCP, Codex's JSON…).
    static var otherAppsJSON: String {
        let root: [String: Any] = ["mcpServers": ["airc": serverEntry(client: "mcp-client")]]
        let data = (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

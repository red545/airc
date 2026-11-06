// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

func readData(_ url: URL, missing: ImportError) throws -> Data {
    do { return try Data(contentsOf: url) }
    catch {
        let e = error as NSError
        if e.code == NSFileReadNoPermissionError || (e.domain == NSPOSIXErrorDomain && [1, 13].contains(e.code)) { throw ImportError.permissionDenied }
        if e.code == NSFileReadNoSuchFileError { throw missing }
        throw missing
    }
}
public enum ArcImporter {
    public static func locateData(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL {
        let folder = home.appendingPathComponent("Library/Application Support/Arc")
        do { _ = try folder.resourceValues(forKeys: [.isDirectoryKey]); return folder }
        catch {
            let e = error as NSError
            if e.code == NSFileReadNoPermissionError { throw ImportError.permissionDenied }
            let installed = FileManager.default.fileExists(atPath: "/Applications/Arc.app") || FileManager.default.fileExists(atPath: home.appendingPathComponent("Applications/Arc.app").path)
            throw installed ? ImportError.noData : ImportError.arcNotInstalled
        }
    }
    /// Runs file I/O and parsing off the caller's actor. Callback executes on the worker.
    public static func plan(at directory: URL? = nil, includeToday: Bool = true, progress: ProgressHandler? = nil) async throws -> ImportPlan {
        try await Task.detached {
            progress?(.init(stage: .discovering, completed: 0, total: 3))
            let root = try directory ?? locateData()
            try Task.checkCancellation()
            progress?(.init(stage: .sidebar, completed: 1, total: 3))
            var plan = try ArcSidebarParser.parse(readData(root.appendingPathComponent("StorableSidebar.json"), missing: .noData), includeToday: includeToday)
            progress?(.init(stage: .profiles, completed: 2, total: 3))
            plan.profiles = try discoverProfiles(at: root, referenced: plan.profiles)
            for p in plan.profiles where !p.isAvailable { plan.warnings.append(.init(code: .missingProfile, message: "A referenced Chromium profile folder is missing.")) }
            try Task.checkCancellation()
            progress?(.init(stage: .complete, completed: 3, total: 3))
            return plan
        }.value
    }
    public static func discoverProfiles(at arcDirectory: URL, referenced: [ImportedProfile] = []) throws -> [ImportedProfile] {
        let userData = arcDirectory.appendingPathComponent("User Data")
        var cache: Obj = [:]
        do {
            let data = try Data(contentsOf: userData.appendingPathComponent("Local State"))
            guard let root = try? JSONSerialization.jsonObject(with: data) as? Obj else { throw ImportError.invalidLocalState }
            cache = obj(obj(root["profile"])["info_cache"])
        } catch let e as ImportError { throw e }
        catch {
            let e = error as NSError
            if e.code == NSFileReadNoPermissionError { throw ImportError.permissionDenied }
            if e.code != NSFileReadNoSuchFileError { throw ImportError.invalidLocalState }
        }
        var directories = Set(cache.keys).union(referenced.map(\.directory))
        do {
            for url in try FileManager.default.contentsOfDirectory(at: userData, includingPropertiesForKeys: [.isDirectoryKey]) {
                if (url.lastPathComponent == "Default" || url.lastPathComponent.hasPrefix("Profile ")), try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true { directories.insert(url.lastPathComponent) }
            }
        } catch {
            if (error as NSError).code == NSFileReadNoPermissionError { throw ImportError.permissionDenied }
        }
        return try directories.sorted().map { dir in
            try validateDirectory(dir)
            let info = obj(cache[dir])
            let available = (try? userData.appendingPathComponent(dir).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            return ImportedProfile(id: dir == "Default" ? "default" : dir, directory: dir, name: nonempty(info["name"]) ?? dir, avatar: info["avatar_icon"] as? String, color: jsonValue(info["profile_color"] ?? info["user_color"] ?? info["profile_highlight_color"]), isAvailable: available)
        }
    }
}
func validateDirectory(_ name: String) throws {
    guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"), !name.contains("\0") else { throw ImportError.invalidProfile }
}

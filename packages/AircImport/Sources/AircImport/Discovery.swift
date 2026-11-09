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
    public static func plan(at directory: URL? = nil, includeToday: Bool = true, tempRoot: URL = FileManager.default.temporaryDirectory, now: Date = Date(), progress: ProgressHandler? = nil) async throws -> ImportPlan {
        try await Task.detached {
            progress?(.init(stage: .discovering, completed: 0, total: 3))
            let root = try directory ?? locateData()
            try Task.checkCancellation()
            progress?(.init(stage: .sidebar, completed: 1, total: 3))
            var plan = try ArcSidebarParser.parse(readData(root.appendingPathComponent("StorableSidebar.json"), missing: .noData), includeToday: includeToday)
            progress?(.init(stage: .profiles, completed: 2, total: 3))
            // A damaged profile list doesn't stop the import (P22): the profiles come from their folders and the
            // sidebar's references, named after their folders.
            plan.profiles = try discoverProfiles(at: root, referenced: plan.profiles, warnings: &plan.warnings)
            for p in plan.profiles where !p.isAvailable { plan.warnings.append(.init(code: .missingProfile, message: "A referenced Chromium profile folder is missing.")) }
            try Task.checkCancellation()
            try readProfileData(into: &plan, at: root, tempRoot: tempRoot, now: now, progress: progress)
            progress?(.init(stage: .complete, completed: 3, total: 3))
            return plan
        }.value
    }
    /// Throws `invalidLocalState` for a damaged profile list; `plan` reads one with the variant below instead.
    public static func discoverProfiles(at arcDirectory: URL, referenced: [ImportedProfile] = []) throws -> [ImportedProfile] {
        let found = try discover(at: arcDirectory, referenced: referenced)
        if found.damagedList { throw ImportError.invalidLocalState }
        return found.profiles
    }
    /// A damaged `Local State` (not JSON, or unreadable for a reason other than permission) is a warning, not an error.
    static func discoverProfiles(at arcDirectory: URL, referenced: [ImportedProfile], warnings: inout [ImportWarning]) throws -> [ImportedProfile] {
        let found = try discover(at: arcDirectory, referenced: referenced)
        if found.damagedList {
            warnings.append(.init(code: .unreadableProfileList, message: "Arc's profile list couldn't be read, so profiles are named after their folders."))
        }
        return found.profiles
    }
    private static func discover(at arcDirectory: URL, referenced: [ImportedProfile]) throws -> (profiles: [ImportedProfile], damagedList: Bool) {
        let userData = arcDirectory.appendingPathComponent("User Data")
        var cache: Obj = [:]
        var damagedList = false
        do {
            let data = try Data(contentsOf: userData.appendingPathComponent("Local State"))
            guard let root = try? JSONSerialization.jsonObject(with: data) as? Obj else { throw ImportError.invalidLocalState }
            cache = obj(obj(root["profile"])["info_cache"])
            // A name that isn't one folder ("../x") is damage, not a profile.
            for dir in cache.keys where (try? validateDirectory(dir)) == nil { cache[dir] = nil; damagedList = true }
        } catch {
            let e = error as NSError
            if e.code == NSFileReadNoPermissionError || (e.domain == NSPOSIXErrorDomain && [1, 13].contains(e.code)) { throw ImportError.permissionDenied }
            if error as? ImportError != nil || e.code != NSFileReadNoSuchFileError { damagedList = true }
        }
        var directories = Set(cache.keys).union(referenced.map(\.directory))
        do {
            for url in try FileManager.default.contentsOfDirectory(at: userData, includingPropertiesForKeys: [.isDirectoryKey]) {
                if (url.lastPathComponent == "Default" || url.lastPathComponent.hasPrefix("Profile ")), try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true { directories.insert(url.lastPathComponent) }
            }
        } catch {
            if (error as NSError).code == NSFileReadNoPermissionError { throw ImportError.permissionDenied }
        }
        let profiles = try directories.sorted().map { dir in
            try validateDirectory(dir)
            let info = obj(cache[dir])
            // A linked folder counts as there; reading it is refused later (`profileOutsideArc`) if it leads outside.
            let available = (try? userData.appendingPathComponent(dir).resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            return ImportedProfile(id: dir == "Default" ? "default" : dir, directory: dir, name: nonempty(info["name"]) ?? dir, avatar: info["avatar_icon"] as? String, color: jsonValue(info["profile_color"] ?? info["user_color"] ?? info["profile_highlight_color"]), isAvailable: available)
        }
        return (profiles, damagedList)
    }
}
func validateDirectory(_ name: String) throws {
    guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"), !name.contains("\0") else { throw ImportError.invalidProfile }
}

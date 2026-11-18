// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircKit
import UniformTypeIdentifiers
import WebKit

/// Files for agents (docs/user/agents.md, "Uploads and downloads"):
/// - **upload_file** sets a page's file field to files the person allowed: under the folder chosen in Settings › Agents ›
///   "Files agents may upload", or in the app's own Airc folder (what it downloaded, or wrote there itself). Never an
///   arbitrary path: the path is resolved (symlinks, "..") before the check, and folders, hidden files and anything
///   over 200 MB are refused.
/// - **Downloads** an agent's page starts go to the app's own folder, `~/Downloads/Airc Agents/<app>`, not the person's
///   Downloads list. Both engines: Airc claims the engine's download row when it comes from an agent tab right after
///   an agent action, moves the finished file into the app's folder and removes the row. A risky file (an app, a disk
///   image…) is discarded and the agent told to ask the person. **list_downloads** returns the files and their paths.
extension AgentCenter {
    static let uploadLimit: Int64 = 200 << 20

    /// The app's own folder (made on first use).
    func appFolder(_ s: AgentSession) -> URL {
        let name = (s.clientName ?? s.client).components(separatedBy: CharacterSet(charactersIn: "/:\\\0\n")).joined(separator: "-")
        var folder = name.trimmingCharacters(in: .whitespaces)
        if folder.isEmpty || folder.hasPrefix(".") { folder = "App" }
        // Two apps with the same name get their own folders.
        if let key = s.clientKey?.split(separator: "#").first.map(String.init),
           settings.clients.contains(where: { $0.name == s.clientName && $0.key != key }) {
            folder += " " + String(key.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) & 0xffff } % 10000)   // stable across launches
        }
        let url = Self.agentsDownloads.appendingPathComponent(folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// `~/Downloads/Airc Agents` (test builds: under the data folder, so checks leave nothing behind).
    static var agentsDownloads: URL {
        #if AIRC_TESTING
        if let o = ProcessInfo.processInfo.environment["AIRC_AGENT_DOWNLOADS"] { return URL(fileURLWithPath: o) }
        if (NSApp.delegate as? AppDelegate)?.options.isAutomated == true {
            return AppPaths.dataDirectory.appendingPathComponent("Airc Agents", isDirectory: true)
        }
        #endif
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        return downloads.appendingPathComponent("Airc Agents", isDirectory: true)
    }

    // MARK: upload_file

    /// The file at `raw` when the app may upload it, else why not.
    func uploadable(_ raw: String, _ s: AgentSession) -> Result<URL, AgentReason> {
        let expanded = (raw as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return .failure(AgentReason("Give the file's full path.")) }
        let url = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
        var roots = [appFolder(s)]
        if let f = settings.uploadFolder { roots.append(URL(fileURLWithPath: f, isDirectory: true)) }
        let inside = roots.contains { root in
            let r = root.standardizedFileURL.resolvingSymlinksInPath().path
            return url.path.hasPrefix(r.hasSuffix("/") ? r : r + "/")
        }
        let allowed = settings.uploadFolder.map { "\(appFolder(s).path) or \($0)" } ?? appFolder(s).path
        guard inside else {
            return .failure(AgentReason("Airc only uploads files from \(allowed). The person can choose a folder in Airc › Settings › Agents › Files agents may upload."))
        }
        guard !url.pathComponents.contains(where: { $0.hasPrefix(".") }) else { return .failure(AgentReason("Hidden files aren't uploaded.")) }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return .failure(AgentReason("No file at \(url.path).")) }
        guard !isDir.boolValue else { return .failure(AgentReason("That's a folder: give a file.")) }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= Self.uploadLimit else { return .failure(AgentReason("Files over 200 MB aren't uploaded.")) }
        return .success(url)
    }

    func uploadFile(_ a: [String: Any], _ s: AgentSession, _ done: @escaping (AgentResult) -> Void) {
        let raw = (a["paths"] as? [String]) ?? (a["path"] as? String).map { [$0] } ?? []
        guard !raw.isEmpty, raw.count <= 20 else { return done(.error("path (or paths, up to 20) is required")) }
        var files: [URL] = []
        for r in raw {
            switch uploadable(r, s) {
            case .failure(let why): return done(.error(why.text))
            case .success(let u): files.append(u)
            }
        }
        withTab(a, s, done) { w, tab in
            let p = self.point(a["coordinate"])
            if let p, !(p.x >= 0 && p.y >= 0 && p.x < w.size.width && p.y < w.size.height) {
                return done(.error("coordinate \(Int(p.x)),\(Int(p.y)) is outside the \(Int(w.size.width))x\(Int(w.size.height)) screenshot"))
            }
            self.noteAgentAction(tab)
            w.driver.setFiles(tab, at: p, files: files) { error in
                if let error { return done(.error(error)) }
                let names = files.map(\.lastPathComponent).joined(separator: ", ")
                self.log(["event": "upload", "session": s.id, "files": files.count])
                done(.text("Attached \(names) to the page's file field."))
            }
        }
    }

    // MARK: Downloads

    func listDownloads(_ s: AgentSession) -> AgentResult {
        let folder = appFolder(s)
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        let files: [[String: Any]] = names.filter { !$0.hasPrefix(".") }.compactMap { n in
            let path = folder.appendingPathComponent(n).path
            guard let attrs = try? fm.attributesOfItem(atPath: path), attrs[.type] as? FileAttributeType == .typeRegular else { return nil }
            return ["path": path, "name": n, "bytes": (attrs[.size] as? NSNumber)?.intValue ?? 0,
                    "modified": ISO8601DateFormatter().string(from: attrs[.modificationDate] as? Date ?? Date())]
        }.sorted { ($0["modified"] as? String ?? "") > ($1["modified"] as? String ?? "") }
        let pending = agentDownloads.values.filter { $0.sessionID == s.id && !$0.done }.map { d -> [String: Any] in
            ["name": d.name, "state": d.note ?? "downloading", "bytes": d.received]
        }
        return .json(["folder": folder.path, "files": files, "inProgress": pending,
                      "note": "Files this app's agent pages downloaded (newest first). upload_file can use them."])
    }

    /// An agent's input reached this tab: a download starting in the next 15 s from its page is the agent's.
    func noteAgentAction(_ tab: EngineTab) {
        lastAgentAction[ObjectIdentifier(tab)] = Date()
    }

    /// DownloadCenter's question for each new row: is it an agent's? Then it's handled here and the person's list
    /// never shows it.
    func claimDownload(_ d: EngineDownload, profileID: String) -> Bool {
        if let mine = agentDownloads[profileID + "/" + d.id] {
            followDownload(mine, d)
            return true
        }
        guard d.state == .inProgress else { return false }
        let page = d.referrer.flatMap(URL.init(string:))
        let source = URL(string: d.url)
        func same(_ a: URL?, _ b: URL?) -> Bool {
            guard let a, let b else { return false }
            return a.host == b.host && a.path == b.path && a.query == b.query
        }
        let now = Date()
        let owner = windows.values.filter { $0.profileID == profileID }.first { w in
            w.tabs.contains { t in
                guard let at = lastAgentAction[ObjectIdentifier(t.tab)], now.timeIntervalSince(at) < 15 else { return false }
                return same(t.tab.url, page) || same(t.tab.url, source) || (page == nil && t.tab.url?.host == source?.host)
            }
        }
        guard let w = owner, let s = live.values.first(where: { $0.ownerKey == w.ownerKey }) else { return false }
        let mine = AgentDownload(key: profileID + "/" + d.id, id: d.id, profileID: profileID, sessionID: s.id,
                                 folder: appFolder(s), name: d.fileName)
        agentDownloads[mine.key] = mine
        log(["event": "download", "session": s.id])
        followDownload(mine, d)
        return true
    }

    private func followDownload(_ mine: AgentDownload, _ d: EngineDownload) {
        mine.received = d.received
        if !d.fileName.isEmpty { mine.name = d.fileName }
        guard !mine.done, let profile = app?.profiles.engineProfile(for: mine.profileID), let engine = app?.engine as? EngineDownloads else { return }
        if d.dangerous, d.state == .inProgress {
            // Never kept for an agent: the person decides about apps and disk images in their own browsing.
            mine.done = true
            mine.note = "discarded: \(mine.name) is a kind of file Airc doesn't keep for agents (ask the person)"
            engine.performDownloadAction(.discard, id: d.id, in: profile)
            return
        }
        switch d.state {
        case .complete:
            guard let path = d.path ?? engine.downloadedFile(d.id, in: profile)?.path, FileManager.default.fileExists(atPath: path) else { return }
            mine.done = true
            let src = URL(fileURLWithPath: path)
            var dst = mine.folder.appendingPathComponent(src.lastPathComponent)
            var n = 2
            while FileManager.default.fileExists(atPath: dst.path) {
                dst = mine.folder.appendingPathComponent("\(src.deletingPathExtension().lastPathComponent) \(n)" + (src.pathExtension.isEmpty ? "" : "." + src.pathExtension))
                n += 1
            }
            do { try FileManager.default.moveItem(at: src, to: dst); mine.note = "done" } catch { mine.note = "done (left at \(path))" }
            mine.path = dst.path
            DispatchQueue.main.async { engine.performDownloadAction(.remove, id: d.id, in: profile) }
        case .cancelled, .interrupted:
            mine.done = true
            mine.note = "failed"
        default:
            break
        }
    }
}

/// A download an agent's page started (AgentCenter.claimDownload).
final class AgentDownload {
    let key: String, id: String, profileID: String, sessionID: Int, folder: URL
    var name: String
    var received: Int64 = 0
    var done = false
    var note: String?
    var path: String?
    init(key: String, id: String, profileID: String, sessionID: Int, folder: URL, name: String) {
        self.key = key; self.id = id; self.profileID = profileID; self.sessionID = sessionID; self.folder = folder; self.name = name
    }
}

// MARK: Engines: a file field set to files

/// The page's file input at a point (or the label/button over it, or the page's only one): JS shared by both engines.
enum AgentFileScripts {
    static func find(_ p: CGPoint?) -> String {
        let at = p.map { "\(Int($0.x)),\(Int($0.y))" } ?? "null,null"
        return """
        (function(x,y){function fi(e){if(!e)return null;if(e.tagName==='INPUT'&&e.type==='file')return e;
        if(e.control&&e.control.type==='file')return e.control;var l=e.closest&&e.closest('label');
        if(l&&l.control&&l.control.type==='file')return l.control;var q=e.querySelector&&e.querySelector('input[type=file]');if(q)return q;
        var f=e.closest&&e.closest('form');if(f){var a=f.querySelectorAll('input[type=file]');if(a.length===1)return a[0];}return null;}
        var el=x===null?null:document.elementFromPoint(x,y),f=null;for(var e=el;e&&!f;e=e.parentElement)f=fi(e);
        if(!f){var all=document.querySelectorAll('input[type=file]');if(all.length===1)f=all[0];}
        return f;})(\(at))
        """
    }
}

#if canImport(AircCore)
extension ChromiumAgentDriver {
    /// The in-app DevTools client has no file access (DOM.setFileInputFiles answers "Not allowed"), so the files are
    /// built in the page: File objects in a DataTransfer set as the input's files, then input and change, as a chooser
    /// does. The page (and a form it submits) gets the real names, types and bytes. Up to 50 MB in all on this path.
    static let scriptUploadLimit = 50 << 20

    func setFiles(_ tab: EngineTab, at p: CGPoint?, files: [URL], completion: @escaping (String?) -> Void) {
        var parts: [String] = []
        var total = 0
        for f in files {
            guard let d = try? Data(contentsOf: f) else { return completion("Airc couldn't read \(f.lastPathComponent).") }
            total += d.count
            guard total <= Self.scriptUploadLimit else { return completion("Files over 50 MB in all aren't uploaded on this engine.") }
            let type = UTType(filenameExtension: f.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            parts.append("{n:\(AgentPageScripts.jsString(f.lastPathComponent)),t:\(AgentPageScripts.jsString(type)),d:'\(d.base64EncodedString())'}")
        }
        let js = """
        (function(){var f=\(AgentFileScripts.find(p));if(!f)return JSON.stringify({ok:false});var dt=new DataTransfer();
        [\(parts.joined(separator: ","))].forEach(function(o){var b=atob(o.d),a=new Uint8Array(b.length);for(var i=0;i<b.length;i++)a[i]=b.charCodeAt(i);
        dt.items.add(new File([a],o.n,{type:o.t,lastModified:Date.now()}));});
        if(!f.multiple&&dt.files.length>1)return JSON.stringify({ok:false,one:true});
        f.files=dt.files;f.dispatchEvent(new Event('input',{bubbles:true}));f.dispatchEvent(new Event('change',{bubbles:true}));
        return JSON.stringify({ok:true,n:f.files.length});})()
        """
        evaluate(tab, js) { v in
            let r = agentJSON(v)
            if r?["one"] as? Bool == true { return completion("That file field takes one file.") }
            completion(r?["ok"] as? Bool == true ? nil : "No file field there: click near the page's upload button or field, or give its coordinate.")
        }
    }
}
#endif

extension WebKitAgentDriver {
    /// WebKit has no way to set a file input from outside: the input is clicked from a script (the app's scripts count
    /// as the person's gesture) and the open panel it asks for is answered with the files (WebKitEngine's
    /// runOpenPanel → `WebKitAgentFiles`), without a panel on screen.
    func setFiles(_ tab: EngineTab, at p: CGPoint?, files: [URL], completion: @escaping (String?) -> Void) {
        guard let v = (tab as? WebKitTab)?.webView else { return completion("not a WebKit page") }
        WebKitAgentFiles.armed[ObjectIdentifier(v)] = (files, Date())
        let js = "(function(){var f=\(AgentFileScripts.find(p));if(!f)return false;f.click();return true;})()"
        v.evaluateJavaScript(js, in: nil, in: .defaultClient) { result in
            guard case .success(let value) = result, value as? Bool == true else {
                WebKitAgentFiles.armed[ObjectIdentifier(v)] = nil
                return completion("No file field there: click near the page's upload button or field, or give its coordinate.")
            }
            let deadline = Date().addingTimeInterval(3)
            func poll() {
                if WebKitAgentFiles.armed[ObjectIdentifier(v)] == nil { return completion(nil) }
                if Date() > deadline {
                    WebKitAgentFiles.armed[ObjectIdentifier(v)] = nil
                    return completion("The page's file field didn't open (it may need a click first).")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
            }
            poll()
        }
    }
}

/// Files an agent's upload_file armed for a WebKit page's next open panel (one use, 5 s).
enum WebKitAgentFiles {
    static var armed: [ObjectIdentifier: (files: [URL], at: Date)] = [:]

    /// WebKitEngine's runOpenPanel asks first: the armed files, or nil for the person's panel.
    static func take(for webView: WKWebView) -> [URL]? {
        let key = ObjectIdentifier(webView)
        guard let a = armed.removeValue(forKey: key), Date().timeIntervalSince(a.at) < 5 else { return nil }
        return a.files
    }
}

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
//
// oauthapps: a stand-in for a desktop app that signs in through the default browser (an IDE, a CLI), plus the fake
// OAuth provider it talks to. Synthetic only: no real accounts or third-party sign-ins, ever.
//
// One process, built by build-fake-app.sh into "Fake Desktop App.app" (LSUIElement, URL scheme `airc-oauthtest`):
//   - the provider and the app's web callback, on one loopback port (--port, default 47811) for two host names:
//       accounts.example  /o/oauth2/auth (PKCE S256, prompt=consent|none, access_type=offline), /o/oauth2/approve
//       app.example       /oauth-callback (pattern a: hands off to airc-oauthtest://), /web + /popup-callback
//                         (pattern c: a popup that posts to its opener and closes), /close-callback (window.close)
//     Chromium reaches them with --host-resolver-rules=MAP *.example 127.0.0.1; WebKit with the profile's CONNECT
//     proxy at the same port (the server answers CONNECT and absolute-URI requests).
//   - pattern b: a loopback listener on 127.0.0.1:<ephemeral>/callback for each loopback sign-in, as gcloud or gh do.
//   - the custom scheme: a GURL handler (Launch Services hands `airc-oauthtest:` links to this app).
// Each sign-in builds its own auth URL (state, code_verifier → S256 challenge) and opens it with
// NSWorkspace.open(_:withApplicationAt:) at the Airc test build (--airc), the way the default browser gets a link:
// a GURL Apple event from this app. The code that comes back is exchanged in-process against the verifier.
//
// Control (127.0.0.1 only): GET /__start?flow=scheme|loopback|close[&activate=1] → {"state": …}; GET /__quit.
// Launch with --start <flow> to sign in at once (the cold-start case: Airc isn't running yet; --airc-arg/--airc-env
// are passed to the Airc it launches, and this app quits when that Airc quits).
// Everything that happens is a JSON line in --log.
import AppKit
import CryptoKit
import Foundation
import Network

struct Options {
    var port: UInt16 = 47811
    var log = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("airc-oauthtest.log")
    var airc: URL?
    var aircArgs: [String] = []
    var aircEnv: [String: String] = [:]
    var start: String?
    var activate = false

    init(_ args: [String]) {
        var i = 1
        func next() -> String? { i += 1; return i < args.count ? args[i] : nil }
        while i < args.count {
            switch args[i] {
            case "--port": port = next().flatMap(UInt16.init) ?? port
            case "--log": if let v = next() { log = URL(fileURLWithPath: v) }
            case "--airc": if let v = next() { airc = URL(fileURLWithPath: v) }
            case "--airc-arg": if let v = next() { aircArgs.append(v) }
            case "--airc-env":
                if let v = next(), let eq = v.firstIndex(of: "=") { aircEnv[String(v[..<eq])] = String(v[v.index(after: eq)...]) }
            case "--start": start = next()
            case "--activate": activate = true
            default: break
            }
            i += 1
        }
    }
}

let options = Options(CommandLine.arguments)
let scheme = "airc-oauthtest"
let clientID = "fake-desktop-app.apps.example"

func log(_ fields: [String: Any]) {
    var f = fields
    f["t"] = Date().timeIntervalSince1970
    guard let data = try? JSONSerialization.data(withJSONObject: f, options: [.sortedKeys]) else { return }
    let line = data + Data("\n".utf8)
    if let h = try? FileHandle(forWritingTo: options.log) {
        h.seekToEndOfFile(); h.write(line); try? h.close()
    } else {
        try? line.write(to: options.log)
    }
}

func base64url(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func random(_ n: Int) -> String {
    var bytes = [UInt8](repeating: 0, count: n)
    _ = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
    return base64url(Data(bytes))
}

func query(_ s: Substring) -> [String: String] {
    var out: [String: String] = [:]
    for pair in s.split(separator: "&") {
        let kv = pair.split(separator: "=", maxSplits: 1).map {
            String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0)
        }
        if let k = kv.first { out[k] = kv.count > 1 ? kv[1] : "" }
    }
    return out
}

func escape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

func form(_ fields: [String: String]) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return fields.sorted { $0.key < $1.key }
        .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&")
}

// MARK: - The provider's state

/// One sign-in this app started.
final class SignIn {
    let flow: String
    let state = random(16)
    let verifier = random(48)
    var redirect = ""
    var loopback: Loopback?
    init(flow: String) { self.flow = flow }
    var challenge: String { base64url(Data(SHA256.hash(data: Data(verifier.utf8)))) }
}

final class Provider {
    var signIns: [String: SignIn] = [:]          // by state
    var codes: [String: (challenge: String, redirect: String, state: String)] = [:]
    var sessions: Set<String> = []

    /// The app's side: a code came back to it (custom scheme or loopback). Exchanged with the verifier, as an app's
    /// token request would (in-process: the provider is this process).
    func received(code: String?, state: String?, via: String) {
        guard let state, let s = signIns[state] else {
            return log(["event": "token", "ok": false, "via": via, "why": "unknown state"])
        }
        guard let code, let issued = codes.removeValue(forKey: code) else {
            return log(["event": "token", "ok": false, "via": via, "flow": s.flow, "why": "unknown or reused code"])
        }
        let pkce = issued.challenge == s.challenge
        let ok = pkce && issued.state == state && issued.redirect == s.redirect
        log(["event": "token", "ok": ok, "via": via, "flow": s.flow, "pkce": pkce, "state": state])
    }
}

let provider = Provider()

// MARK: - HTTP

struct Request {
    let method: String
    let target: String
    let headers: [String: String]
    let body: Data
    var host: String { (headers["host"] ?? "").split(separator: ":").first.map(String.init) ?? "" }
    var path: Substring { target.split(separator: "?", maxSplits: 1).first ?? "" }
    var params: [String: String] { target.split(separator: "?", maxSplits: 1).dropFirst().first.map(query) ?? [:] }
    var cookies: [String: String] {
        var out: [String: String] = [:]
        for part in (headers["cookie"] ?? "").split(separator: ";") {
            let kv = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            if kv.count == 2 { out[String(kv[0])] = String(kv[1]) }
        }
        return out
    }
}

struct Response {
    var status = "200 OK"
    var type = "text/html; charset=utf-8"
    var headers: [String] = []
    var body = Data()
    static func html(_ s: String) -> Response { Response(body: Data(s.utf8)) }
    static func redirect(_ to: String, _ extra: [String] = []) -> Response {
        Response(status: "302 Found", headers: ["Location: \(to)"] + extra)
    }
    static func text(_ status: String, _ s: String) -> Response { Response(status: status, type: "text/plain", body: Data(s.utf8)) }
    var data: Data {
        let head = (["HTTP/1.1 \(status)", "Content-Type: \(type)", "Content-Length: \(body.count)", "Cache-Control: no-store",
                     "Connection: close"] + headers).joined(separator: "\r\n") + "\r\n\r\n"
        return Data(head.utf8) + body
    }
}

/// A tiny HTTP/1.1 server (one request per connection), with CONNECT for WebKit's per-profile proxy.
final class Server {
    let listener: NWListener
    let queue = DispatchQueue(label: "fake-desktop-app.http")
    let handle: (Request, @escaping (Response) -> Void) -> Void

    init(port: UInt16?, handle: @escaping (Request, @escaping (Response) -> Void) -> Void) throws {
        let p = NWParameters.tcp
        p.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any)
        p.acceptLocalOnly = true
        p.allowLocalEndpointReuse = true
        listener = try NWListener(using: p)
        self.handle = handle
    }

    func start(_ ready: @escaping (UInt16?) -> Void) {
        var reported = false
        listener.stateUpdateHandler = { [weak self] state in
            guard !reported else { return }
            switch state {
            case .ready: reported = true; DispatchQueue.main.async { ready(self?.listener.port?.rawValue) }
            case .failed: reported = true; DispatchQueue.main.async { ready(nil) }
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] c in
            guard let self else { return }
            c.start(queue: self.queue)
            self.read(c, Data())
        }
        listener.start(queue: queue)
    }

    func stop() { listener.cancel() }

    private func read(_ c: NWConnection, _ prefix: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return c.cancel() }
            var bytes = prefix
            bytes.append(data ?? Data())
            guard let end = bytes.range(of: Data("\r\n\r\n".utf8)) else {
                if complete || error != nil || bytes.count > 262_144 { c.cancel() } else { self.read(c, bytes) }
                return
            }
            let lines = String(decoding: bytes[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let first = lines[0].split(separator: " ")
            guard first.count >= 2 else { return c.cancel() }
            var headers: [String: String] = [:]
            for l in lines.dropFirst() {
                guard let colon = l.firstIndex(of: ":") else { continue }
                headers[l[..<colon].lowercased()] = l[l.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            if first[0] == "CONNECT" {
                c.send(content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), completion: .contentProcessed { _ in
                    self.read(c, Data(bytes[end.upperBound...]))
                })
                return
            }
            let length = Int(headers["content-length"] ?? "") ?? 0
            let body = Data(bytes[end.upperBound...])
            if body.count < length, !complete, error == nil { return self.read(c, bytes) }
            // An absolute-URI request (a proxy's): its host is the URI's.
            var target = String(first[1])
            if let u = URL(string: target), let host = u.host, u.scheme != nil {
                headers["host"] = host + (u.port.map { ":\($0)" } ?? "")
                target = (u.path.isEmpty ? "/" : u.path) + (u.query.map { "?\($0)" } ?? "")
            }
            let request = Request(method: String(first[0]), target: target, headers: headers, body: body.prefix(length))
            DispatchQueue.main.async {
                self.handle(request) { response in
                    self.queue.async { c.send(content: response.data, completion: .contentProcessed { _ in c.cancel() }) }
                }
            }
        }
    }
}

/// Pattern b: the app's own loopback listener for one sign-in (random port, /callback), as CLIs do.
final class Loopback {
    var server: Server?
    var port: UInt16 = 0
}

// MARK: - Pages

let consentPage = """
<!doctype html><html><head><meta charset="utf-8"><title>Sign in – Accounts fixture</title>
<style>body{font:15px -apple-system,system-ui;margin:0;background:#f4f4f6}main{max-width:420px;margin:56px auto;background:#fff;
border-radius:14px;padding:28px 28px 24px;box-shadow:0 1px 3px #0002}h1{font-size:22px;margin:0 0 6px}p{color:#444}
button{font:inherit;padding:10px 22px;border-radius:20px;border:0;margin-top:14px;cursor:pointer}#allow{background:#1a73e8;color:#fff}
#deny{background:#eee}ul{padding-left:18px;color:#333}</style>
<script src="/gsi/client.js"></script></head><body><main>
<h1>Fake Desktop App wants to access your account</h1><p>Signed in as <b>someone@accounts.example</b> (synthetic).</p>
<ul><li>See your basic profile</li><li>Stay signed in (offline access)</li></ul>
<form id="f" method="post" action="/o/oauth2/approve">%FIELDS%
<button id="deny" type="button" onclick="document.title='denied'">Cancel</button>
<button id="allow" type="submit">Allow</button></form>
<iframe id="probe" src="/o/oauth2/iframe" style="display:none"></iframe></main>
<script>
var storage = false; try { localStorage.setItem('fixture', '1'); storage = localStorage.getItem('fixture') === '1'; } catch (e) {}
var cookie = false; try { document.cookie = 'pref=1; path=/; SameSite=Lax'; cookie = document.cookie.indexOf('pref=1') >= 0; } catch (e) {}
var fedcm = typeof IdentityCredential !== 'undefined';
window.addEventListener('load', function () {
  var frame = false; try { frame = document.getElementById('probe').contentDocument.title === 'probe ok'; } catch (e) {}
  document.title = 'Consent ready storage=' + storage + ' cookie=' + cookie + ' script=' + (window.__gsi === 1) + ' frame=' + frame + ' fedcm=' + fedcm;
});
</script></body></html>
"""

func callbackPage(code: String, state: String) -> String {
    let target = "\(scheme)://oauth?code=\(code)&state=\(state)"
    return """
    <!doctype html><html><head><meta charset="utf-8"><title>Callback fixture</title>
    <style>body{font:15px -apple-system,system-ui;margin:56px auto;max-width:440px;text-align:center}</style></head><body>
    <h1>You're signed in</h1><p>Return to Fake Desktop App. If it didn't open, <a id="open" href="\(escape(target))">open it</a>.</p>
    <script>setTimeout(function () { location.href = \(String(reflecting: target)); }, 150);</script></body></html>
    """
}

let webPage = """
<!doctype html><html><head><meta charset="utf-8"><title>Web app fixture</title>
<style>body{font:15px -apple-system,system-ui;margin:56px auto;max-width:440px;text-align:center}
button{font:inherit;padding:12px 26px;border-radius:22px;border:0;background:#1a73e8;color:#fff;cursor:pointer}</style></head><body>
<h1>Web app fixture</h1><button id="signin">Sign in with Accounts</button><p id="out"></p>
<script>
var popup = null;
document.getElementById('signin').addEventListener('click', function () {
  popup = window.open(window.AUTH_URL, 'oauth', 'popup,width=480,height=640');
  document.title = popup ? 'web opened popup' : 'web popup blocked';
});
window.addEventListener('message', function (e) {
  if (!e.data || !e.data.code) return;
  document.getElementById('out').textContent = 'code from ' + e.origin;
  document.title = 'web got code ' + e.data.state;
  setTimeout(function () { document.title += ' closed=' + (popup ? popup.closed : 'none'); }, 800);
});
</script></body></html>
"""

let popupCallbackPage = """
<!doctype html><html><head><meta charset="utf-8"><title>Popup callback</title></head><body>
<p>Signed in. This window closes itself.</p><script>
var p = new URLSearchParams(location.search);
if (window.opener) window.opener.postMessage({ code: p.get('code'), state: p.get('state') }, location.origin);
setTimeout(function () { window.close(); }, 100);
</script></body></html>
"""

let closeCallbackPage = """
<!doctype html><html><head><meta charset="utf-8"><title>Close callback</title></head><body>
<p>Signed in. You can close this tab.</p><script>
document.title = 'Close callback history=' + history.length;
setTimeout(function () { window.close(); }, 300);
</script></body></html>
"""

let loopbackPage = """
<!doctype html><html><head><meta charset="utf-8"><title>Loopback done</title></head><body>
<h1>Signed in</h1><p>You can close this tab and return to the app.</p></body></html>
"""

// MARK: - The app

final class App: NSObject, NSApplicationDelegate {
    var server: Server?
    var launched: NSRunningApplication?

    func applicationWillFinishLaunching(_ n: Notification) {
        // kInternetEventClass / kAEGetURL ('GURL'): the custom scheme's links.
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(gurl(_:reply:)),
                                                     forEventClass: 0x4755_524C, andEventID: 0x4755_524C)
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        do {
            server = try Server(port: options.port) { [weak self] r, done in self?.serve(r, done) }
        } catch {
            log(["event": "server", "ok": false, "why": "\(error)"])
            exit(3)
        }
        server?.start { port in
            log(["event": "server", "ok": port != nil, "port": Int(port ?? 0), "pid": Int(getpid())])
            guard port != nil else { exit(3) }
            if let flow = options.start { self.startSignIn(flow, activate: options.activate) { _ in } }
        }
    }

    @objc func gurl(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: 0x2D2D_2D2D)?.stringValue, let u = URLComponents(string: s) else { return }
        let items = Dictionary((u.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        // The sender: Airc (its PID), for the check.
        let sender = event.attributeDescriptor(forKeyword: 0x7370_6964)?.int32Value   // keySenderPIDAttr 'spid'
        log(["event": "scheme", "url": s, "sender": Int(sender ?? 0)])
        provider.received(code: items["code"], state: items["state"], via: "scheme")
    }

    /// Builds a sign-in's auth URL and hands it to Airc as the default browser would get it.
    func startSignIn(_ flow: String, activate: Bool, _ done: @escaping (SignIn?) -> Void) {
        let s = SignIn(flow: flow)
        let port = options.port
        func open() {
            provider.signIns[s.state] = s
            var q: [String: String] = [
                "client_id": clientID, "redirect_uri": s.redirect, "response_type": "code", "scope": "openid profile",
                "state": s.state, "code_challenge": s.challenge, "code_challenge_method": "S256", "access_type": "offline",
                "prompt": flow == "close" ? "none" : "consent",
            ]
            if flow == "close" { q["login_hint"] = "someone@accounts.example" }
            let url = URL(string: "http://accounts.example:\(port)/o/oauth2/auth?" + form(q))!
            guard let airc = options.airc else {
                log(["event": "open", "ok": false, "why": "no --airc"]); return done(nil)
            }
            let c = NSWorkspace.OpenConfiguration()
            c.activates = activate
            c.arguments = options.aircArgs
            c.environment = options.aircEnv
            c.promptsUserIfNeeded = false
            // Cold start: a new Airc (the check's own launch); otherwise the running one at that path gets the link.
            c.createsNewApplicationInstance = options.start != nil
            NSWorkspace.shared.open([url], withApplicationAt: airc, configuration: c) { running, error in
                DispatchQueue.main.async {
                    log(["event": "open", "ok": error == nil, "flow": flow, "state": s.state, "url": url.absoluteString,
                         "pid": Int(running?.processIdentifier ?? 0), "why": error.map { "\($0)" } ?? ""])
                    if options.start != nil, let running { self.watch(running) }
                    done(error == nil ? s : nil)
                }
            }
        }
        switch flow {
        case "loopback":
            let lb = Loopback()
            s.loopback = lb
            do {
                lb.server = try Server(port: nil) { r, reply in
                    guard r.path == "/callback" else { return reply(.text("404 Not Found", "not found")) }
                    log(["event": "loopback", "path": String(r.target), "host": r.headers["host"] ?? ""])
                    provider.received(code: r.params["code"], state: r.params["state"], via: "loopback")
                    reply(.html(loopbackPage))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { lb.server?.stop() }
                }
            } catch { log(["event": "loopback-listen", "ok": false]); return done(nil) }
            lb.server?.start { p in
                guard let p else { log(["event": "loopback-listen", "ok": false]); return done(nil) }
                lb.port = p
                s.redirect = "http://127.0.0.1:\(p)/callback"
                log(["event": "loopback-listen", "ok": true, "port": Int(p)])
                open()
            }
        case "close":
            s.redirect = "http://app.example:\(port)/close-callback"
            open()
        default:
            s.redirect = "http://app.example:\(port)/oauth-callback"
            open()
        }
    }

    /// Cold start: this app launched Airc; it quits when that Airc quits (the runner waits on this process).
    func watch(_ running: NSRunningApplication) {
        launched = running
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            guard running.isTerminated else { return }
            t.invalidate()
            log(["event": "airc-exited"])
            NSApp.terminate(nil)
        }
    }

    // MARK: Routes

    func serve(_ r: Request, _ done: @escaping (Response) -> Void) {
        log(["event": "request", "method": r.method, "host": r.host, "path": String(r.path)])
        switch (r.host, r.path) {
        case ("127.0.0.1", "/__start"):
            let flow = r.params["flow"] ?? "scheme"
            startSignIn(flow, activate: r.params["activate"] == "1") { s in
                done(Response(type: "application/json", body: Data("{\"state\":\"\(s?.state ?? "")\"}".utf8)))
            }
        case ("127.0.0.1", "/__quit"):
            done(.text("200 OK", "bye"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
        case ("accounts.example", "/o/oauth2/auth"): authorize(r, done)
        case ("accounts.example", "/o/oauth2/approve"): approve(r, done)
        case ("accounts.example", "/o/oauth2/iframe"): done(.html("<!doctype html><title>probe ok</title>"))
        case ("accounts.example", "/gsi/client.js"):
            done(Response(type: "application/javascript", body: Data("window.__gsi = 1;".utf8)))
        case ("app.example", "/oauth-callback"):
            done(.html(callbackPage(code: r.params["code"] ?? "", state: r.params["state"] ?? "")))
        case ("app.example", "/web"):
            // The web app's own sign-in (pattern c): its auth URL, with the popup callback.
            let s = SignIn(flow: "popup")
            s.redirect = "http://app.example:\(options.port)/popup-callback"
            provider.signIns[s.state] = s
            let auth = "http://accounts.example:\(options.port)/o/oauth2/auth?" + form([
                "client_id": "web-app.apps.example", "redirect_uri": s.redirect, "response_type": "code", "scope": "openid",
                "state": s.state, "code_challenge": s.challenge, "code_challenge_method": "S256", "prompt": "consent"])
            done(.html(webPage.replacingOccurrences(of: "<script>\nvar popup", with: "<script>\nwindow.AUTH_URL = \(String(reflecting: auth));\nvar popup")))
        case ("app.example", "/popup-callback"):
            if let code = r.params["code"], let issued = provider.codes.removeValue(forKey: code) {
                let s = provider.signIns[issued.state]
                log(["event": "token", "ok": s?.challenge == issued.challenge, "via": "popup", "flow": "popup", "state": issued.state])
            }
            done(.html(popupCallbackPage))
        case ("app.example", "/close-callback"):
            provider.received(code: r.params["code"], state: r.params["state"], via: "close")
            done(.html(closeCallbackPage))
        case (_, "/favicon.ico"): done(.text("404 Not Found", ""))
        default: done(.text("404 Not Found", "no route for \(r.host)\(r.path)"))
        }
    }

    func authorize(_ r: Request, _ done: @escaping (Response) -> Void) {
        let p = r.params
        let required = ["client_id", "redirect_uri", "response_type", "state", "code_challenge", "code_challenge_method"]
        let missing = required.filter { (p[$0] ?? "").isEmpty }
        guard missing.isEmpty, p["response_type"] == "code", p["code_challenge_method"] == "S256" else {
            log(["event": "authorize", "ok": false, "missing": missing])
            return done(.text("400 Bad Request", "invalid request: \(missing)"))
        }
        let sid = r.cookies["SID"].flatMap { provider.sessions.contains($0) ? $0 : nil }
        // prompt=none with a session: straight back to the app (no page in between).
        if p["prompt"] == "none", sid != nil {
            log(["event": "authorize", "ok": true, "prompt": "none"])
            return done(.redirect(issue(p)))
        }
        let session = sid ?? random(12)
        provider.sessions.insert(session)
        let keep = ["client_id", "redirect_uri", "state", "code_challenge", "scope"]
        let fields = keep.map { "<input type=\"hidden\" name=\"\($0)\" value=\"\(escape(p[$0] ?? ""))\">" }.joined()
        log(["event": "authorize", "ok": true, "prompt": p["prompt"] ?? "", "offline": p["access_type"] == "offline"])
        var page = Response.html(consentPage.replacingOccurrences(of: "%FIELDS%", with: fields))
        page.headers = ["Set-Cookie: SID=\(session); Path=/; HttpOnly; SameSite=Lax"]
        done(page)
    }

    func approve(_ r: Request, _ done: @escaping (Response) -> Void) {
        guard r.method == "POST" else { return done(.text("405 Method Not Allowed", "POST only")) }
        let p = query(Substring(String(decoding: r.body, as: UTF8.self)))
        // The consent page's own cookie must come back with its form (first-party, SameSite=Lax).
        guard let sid = r.cookies["SID"], provider.sessions.contains(sid) else {
            log(["event": "approve", "ok": false, "why": "no session cookie"])
            return done(.text("400 Bad Request", "Cookie missing: the session cookie didn't come back with the form"))
        }
        log(["event": "approve", "ok": true])
        done(.redirect(issue(p)))
    }

    /// A one-time code for this request, and where it goes.
    func issue(_ p: [String: String]) -> String {
        let code = random(18)
        let redirect = p["redirect_uri"] ?? ""
        provider.codes[code] = (p["code_challenge"] ?? "", redirect, p["state"] ?? "")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let state = (p["state"] ?? "").addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return redirect + (redirect.contains("?") ? "&" : "?") + "code=\(code)&state=\(state)&scope=openid"
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

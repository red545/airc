// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import Combine

/// Profile-scoped Chromium discovery and route updates. A closed picker does not stop a route.
final class CastCenter: ObservableObject {
    static let shared = CastCenter()
    struct Sink: Identifiable {
        let id: String, name: String, state: String, route: String, issue: String
        let modes: Int
        init(_ d: [String: Any]) {
            id = d["id"] as? String ?? ""; name = d["name"] as? String ?? "Device"
            state = d["state"] as? String ?? "unavailable"; route = d["routeId"] as? String ?? ""
            issue = d["issue"] as? String ?? ""; modes = (d["modes"] as? NSNumber)?.intValue ?? 0
        }
    }
    struct Session: Identifiable, Equatable {
        let id: String, profile: String, name: String
        let pageID: ObjectIdentifier
    }
    @Published private(set) var sinks: [Sink] = []
    @Published private(set) var sessions: [Session] = []
    @Published private(set) var permissionDenied = false
    @Published private(set) var message = "Looking for devices…"
    @Published private(set) var dialogID: Int32 = 0
    @Published private(set) var supported = false
    private(set) weak var page: EngineTab?
    var dismiss: (() -> Void)?
    private var closedDialogs: Set<Int32> = []
    private var timeout: DispatchWorkItem?

    func isCasting(_ page: EngineTab?) -> Bool {
        guard let page else { return false }
        return sessions.contains { $0.pageID == ObjectIdentifier(page) }
    }
    func open(_ page: EngineTab) {
        close()
        self.page = page
        sinks = []; permissionDenied = false
        supported = (page as? CastEngineTab)?.castAvailable == true
        message = supported ? "Looking for devices…" : "Cast isn’t available on Safari-engine pages. Use the video’s AirPlay button when available."
        if supported, (page as? CastEngineTab)?.showCastPicker() != true {
            message = "Cast is unavailable for this page. Try another tab."
        } else if supported {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.sinks.isEmpty, !self.permissionDenied else { return }
                self.message = "No devices found. Connect your Mac and TV to the same Wi-Fi network."
            }
            timeout = work; DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
        }
    }
    func receive(_ state: [String: Any], page: EngineTab) {
        guard let id = (state["id"] as? NSNumber)?.int32Value else { return }
        guard !closedDialogs.contains(id) else { return }
        if state["open"] as? Bool == false {
            if dialogID == id { dialogID = 0; dismiss?() }
            return
        }
        // A site-initiated Presentation/Remote Playback request uses this same controller.
        if self.page !== page || dialogID != id {
            close()
            self.page = page; supported = true; dialogID = id
            CastPicker.show(page: page)
        }
        dialogID = id
        permissionDenied = state["permissionRejected"] as? Bool ?? false
        sinks = (state["sinks"] as? [[String: Any]] ?? []).map(Sink.init)
        if permissionDenied { message = "Allow Airc in System Settings › Privacy & Security › Local Network, then try again." }
        else if sinks.isEmpty { message = "No devices found. Connect your Mac and TV to the same Wi-Fi network." }
        else { message = "Choose a device to cast this page." }
        for sink in sinks where !sink.route.isEmpty && sink.state == "connected" {
            if !sessions.contains(where: { $0.id == sink.route }) {
                sessions.append(Session(id: sink.route, profile: (page as? CastEngineTab)?.castProfileKey ?? "", name: sink.name, pageID: ObjectIdentifier(page)))
            }
        }
        changed()
    }
    func routes(_ routes: [[String: String]], profile: String) {
        let live = Set(routes.compactMap { $0["id"] })
        sessions.removeAll { $0.profile == profile && !live.contains($0.id) }
        changed()
    }
    func start(_ sink: Sink) {
        guard !permissionDenied, sink.state == "available", sink.modes & 3 != 0 else { return }
        message = "Connecting to \(sink.name)…"
        // Presentation (1) must win over tab mirroring (2) for a site's request.
        (page as? CastEngineTab)?.startCast(dialogID, sink: sink.id, mode: sink.modes & 1 != 0 ? 1 : 2)
    }
    func stop(_ session: Session) { CastEngineBridge.stop(session.id) }
    func retry() { if let page, !page.isClosed { open(page) } }
    func close() {
        timeout?.cancel(); timeout = nil
        let old = dialogID; dialogID = 0
        if old != 0 { closedDialogs.insert(old); CastEngineBridge.close(old) }
    }
    private func changed() {
        NotificationCenter.default.post(name: .castChanged, object: self)
        (NSApp.delegate as? AppDelegate)?.controllers.forEach { $0.refreshChrome() }
    }
}
extension Notification.Name { static let castChanged = Notification.Name("AircCastChanged") }
protocol CastEngineTab: EngineTab {
    var castProfileKey: String { get }
    var castAvailable: Bool { get }
    func showCastPicker() -> Bool
    func startCast(_ dialog: Int32, sink: String, mode: Int32)
}

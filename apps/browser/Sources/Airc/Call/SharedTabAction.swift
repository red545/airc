// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import Combine
import SwiftUI

/// UI state is scoped to the call page and its actual engine profile. A request
/// never moves the indicator; only a confirmed engine capture snapshot does.
final class CallTools: ObservableObject {
    static let shared = CallTools()
    @Published private(set) var chat: [String: CallChat.State] = [:]
    @Published private(set) var sharedTabs: [String: Int] = [:]
    @Published private(set) var sharingCalls: Set<String> = []
    /// S03b: the tabs whose page is in a call now (a Favorite's call badge, Sidebar/AudioBadge.swift).
    @Published private(set) var activeCalls: Set<String> = []
    private var calls: [String: EngineTab] = [:]
    private var profiles: [ObjectIdentifier: EngineProfile] = [:]
    private var timer: Timer?
    private var generation: [String: Int] = [:]
    private var revision = 0
    private var windowObservation: AnyCancellable?
    private init() {
        windowObservation = NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    func update(_ id: String, page: EngineTab?, active: Bool, sharing: Bool = false) {
        guard active, let page, !page.isClosed else {
            guard calls[id] != nil || chat[id] != nil || sharedTabs[id] != nil || sharingCalls.contains(id) else { return }
            sharingCalls.remove(id)
            if activeCalls.contains(id) { activeCalls.remove(id) }
            calls[id] = nil; chat[id] = nil; sharedTabs[id] = nil
            generation[id] = nil
            for (key, profile) in profiles where !calls.values.contains(where: { $0.profile === profile }) {
                (profile as? EngineCallSharingProfile)?.observeCallShares(nil)
                profiles[key] = nil
            }
            if calls.isEmpty { timer?.invalidate(); timer = nil }
            return
        }
        calls[id] = page
        if !activeCalls.contains(id) { activeCalls.insert(id) }
        if sharing != sharingCalls.contains(id) {
            if sharing { sharingCalls.insert(id) } else { sharingCalls.remove(id) }
        }
        if let profile = page.profile as? EngineCallSharingProfile, profiles[ObjectIdentifier(profile)] == nil {
            profiles[ObjectIdentifier(profile)] = profile
            profile.observeCallShares { [weak self, weak profile] rows in
                guard let self, let profile else { return }
                self.captureChanged(profile, rows: rows)
            }
        }
        if let profile = page.profile as? EngineCallSharingProfile { captureChanged(profile, rows: profile.callShares()) }
        refresh(id)
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self else { return }
                for id in Array(self.calls.keys) { self.refresh(id) }
            }
        }
    }

    func reset() {
        timer?.invalidate(); timer = nil
        for profile in profiles.values { (profile as? EngineCallSharingProfile)?.observeCallShares(nil) }
        profiles = [:]; calls = [:]; chat = [:]; sharedTabs = [:]; sharingCalls = []; activeCalls = []
        generation = [:]
    }

    private func refresh(_ id: String, toggle: Bool = false) {
        guard let page = calls[id], !page.isClosed else { return update(id, page: nil, active: false) }
        revision += 1
        generation[id] = revision
        let token = generation[id]
        CallChat.read(page, toggle: toggle, fixture: MediaLibrary.shared.controller?.app?.options.isAutomated == true) { [weak self, weak page] state in
            guard let self, let page, self.calls[id] === page, self.generation[id] == token else { return }
            if self.chat[id] != state { self.chat[id] = state }
        }
    }
    func toggleChat(_ id: String) { refresh(id, toggle: true) }

    func captureChanged(_ profile: EngineProfile, rows: [[String: Any]]) {
        for (id, page) in calls where page.profile === profile {
            let source = rows.first { ($0["capturerID"] as? Int) == page.tabID && ($0["capturing"] as? Bool) == true }?["sharedTabID"] as? Int
            if sharedTabs[id] != source { sharedTabs[id] = source }
        }
    }

    func canSwitch(_ id: String, to target: EngineTab?) -> Bool {
        guard let page = calls[id], let target, !page.isClosed, !target.isClosed,
              page.profile === target.profile else { return false }
        return (target as? EngineCallSharingTab)?.canShareInstead(of: page) ?? false
    }
    @discardableResult func switchTo(_ target: EngineTab?, call id: String) -> Bool {
        guard canSwitch(id, to: target) else { return false }
        guard let source = calls[id], let target = target as? EngineCallSharingTab else { return false }
        let accepted = target.shareInstead(of: source)
        if accepted { objectWillChange.send() }
        return accepted
    }
    func hasControls(_ id: String?) -> Bool {
        guard let id else { return false }
        return chat[id]?.available == true || (canStop(id) && (sharedTabs[id] != nil || sharingCalls.contains(id)))
    }
    func canStop(_ id: String) -> Bool {
        calls[id] is EngineCallSharingTab
    }
    func stop(_ id: String) {
        _ = (calls[id] as? EngineCallSharingTab)?.stopSharing()
    }
    func isShared(_ page: EngineTab?) -> Bool {
        guard let page else { return false }
        return calls.contains { id, call in call.profile === page.profile && sharedTabs[id] == page.tabID }
    }

    /// S03b: what a Favorite's corner badge says about calls: shared into a call (its page is the engine-confirmed
    /// source of a call's tab share) wins over being a call itself.
    enum Badge: Equatable { case none, inCall, sharedToCall }
    func badge(tabID: String?, page: EngineTab?) -> Badge {
        if isShared(page) { return .sharedToCall }
        if let tabID, activeCalls.contains(tabID), calls[tabID]?.isClosed == false { return .inCall }
        return .none
    }
}

struct CallToolsView: View {
    let id: String
    var compact = false
    var foreground: Color?
    var stateChanged: (() -> Void)?
    var targetPage: (() -> EngineTab?)?
    @ObservedObject private var tools = CallTools.shared
    private var target: EngineTab? {
        if let targetPage { return targetPage() }
        return (NSApp.delegate as? AppDelegate)?.controller?.promptShownPage
    }
    var body: some View {
        HStack(spacing: 8) {
            if let chat = tools.chat[id], chat.available {
                Button { tools.toggleChat(id) } label: {
                    HStack(spacing: 3) {
                        Image(systemName: chat.open ? "bubble.left.fill" : "bubble.left")
                        if chat.unread > 0 { Text("\(chat.unread)").font(.caption.bold()) }
                        if !compact { Text("Chat") }
                    }
                }.help(chat.open ? "Close Chat" : "Open Chat")
                    .accessibilityLabel("Chat, \(chat.unread) unread messages")
            }
            if tools.canSwitch(id, to: target) {
                Button { tools.switchTo(target, call: id) } label: {
                    if compact { Image(systemName: "rectangle.on.rectangle") }
                    else { Text("Share This Tab Instead") }
                }.help("Share This Tab Instead")
            }
            if tools.canStop(id) && (tools.sharedTabs[id] != nil || tools.sharingCalls.contains(id)) {
                Button { tools.stop(id) } label: {
                    if compact { Image(systemName: "stop.circle") }
                    else { Text("Stop Sharing") }
                }.help("Stop Sharing")
            }
        }.buttonStyle(.plain).font(.system(size: 11, weight: .medium))
            .foregroundColor(foreground)
            .onReceive(tools.objectWillChange) { _ in DispatchQueue.main.async { stateChanged?() } }
    }
}

/// A native status overlay keeps ordinary tab rows lightweight and never takes
/// their clicks or drags. It observes source changes, not chat polling.
final class SharedTabIndicatorView: NSImageView {
    var page: EngineTab? { didSet { refresh() } }
    private var observation: AnyCancellable?
    init() {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: "rectangle.on.rectangle.fill", accessibilityDescription: "Sharing this tab")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .regular))
        contentTintColor = .systemGreen
        toolTip = "This tab is being shared"
        isHidden = true
        observation = CallTools.shared.$sharedTabs.sink { [weak self] _ in
            // Published sends before the value changes; read the settled map.
            DispatchQueue.main.async { [weak self] in self?.refresh() }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    private func refresh() { isHidden = !CallTools.shared.isShared(page) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

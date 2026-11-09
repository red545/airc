// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import SwiftUI

final class CastPicker {
    static var shared: CastPicker?
    let host: NSHostingView<CastCard>
    weak var controller: PromptHost?
    private var monitor: Any?
    init(_ controller: PromptHost) {
        self.controller = controller
        host = NSHostingView(rootView: CastCard())
        host.appearance = NSAppearance(named: controller.promptTheme.isDark ? .darkAqua : .aqua)
        host.wantsLayer = true
        host.layer?.cornerRadius = 14
        host.layer?.shadowOpacity = 0.2
        host.layer?.shadowRadius = 18
        let anchor = controller.promptAnchor()
        let root = controller.promptRoot
        let rect = root.convert(anchor.rect, from: anchor.view)
        host.frame = NSRect(x: min(max(12, rect.minX), max(12, root.bounds.width - 332)),
                            y: min(rect.maxY + 6, max(12, root.bounds.height - 372)), width: 320, height: 360)
        root.addSubview(host)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53 { Self.hide(); return nil }
            if event.type == .leftMouseDown,
               event.window !== self.host.window || !self.host.bounds.contains(self.host.convert(event.locationInWindow, from: nil)) { Self.hide() }
            return event
        }
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    static func show(page: EngineTab) {
        guard let app = NSApp.delegate as? AppDelegate else { CastCenter.shared.close(); return }
        let hosts: [PromptHost] = app.controllers.map { $0 as PromptHost }
            + app.littleArcs.map { $0 as PromptHost }
            + PrivateBrowsing.shared.windows.map { $0 as PromptHost }
        guard let c = hosts.first(where: { $0.promptOwns(page) }) else {
            CastCenter.shared.close(); return
        }
        show(in: c)
    }
    static func show(in c: PromptHost) {
        shared?.host.removeFromSuperview()
        shared = CastPicker(c)
        CastCenter.shared.dismiss = { hide(closeRequest: false) }
    }
    static func hide(closeRequest: Bool = true) {
        shared?.host.removeFromSuperview(); shared = nil
        if closeRequest { CastCenter.shared.close() }
    }
}
extension WindowController {
    func showCast() {
        guard let page = promptShownPage else { return }
        CastPicker.show(in: self)
        CastCenter.shared.open(page)
    }
}
struct CastCard: View {
    @ObservedObject var center = CastCenter.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "airplayvideo").font(.title2)
                Text("Cast").font(.title3.weight(.semibold))
                Spacer()
                Button { CastPicker.hide() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Close")
            }
            Text(center.page?.title.isEmpty == false ? center.page!.title : "This page")
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            if center.sinks.isEmpty {
                Image(systemName: center.permissionDenied ? "network.slash" : "tv")
                    .font(.system(size: 32, weight: .light)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.top, 12)
                Text(center.permissionDenied ? "Local Network access is off" : center.supported ? "No devices found" : "Use AirPlay on this page")
                    .font(.headline).frame(maxWidth: .infinity)
            }
            Text(center.message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(center.sinks) { sink in
                        Button { center.start(sink) } label: {
                            HStack {
                                Image(systemName: "tv")
                                VStack(alignment: .leading) {
                                    Text(sink.name)
                                    Text(sink.issue.isEmpty ? sink.state.capitalized : sink.issue).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).disabled(sink.state != "available" || sink.modes & 3 == 0 || center.permissionDenied)
                    }
                    ForEach(center.sessions.filter { $0.pageID == center.page.map(ObjectIdentifier.init) }) { s in
                        Button("Stop casting to \(s.name)") { center.stop(s) }
                    }
                }
            }
            if center.supported {
                HStack {
                    if center.permissionDenied {
                        Button("Open System Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!)
                        }
                    }
                    Spacer()
                    Button("Try Again") { center.retry() }
                }
            }
        }.padding(20).frame(width: 320, height: 360)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .accessibilityIdentifier("cast.picker")
    }
}
struct CastSiteRow: View {
    @ObservedObject var center = CastCenter.shared
    let page: EngineTab?
    weak var controller: WindowController?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { controller?.showCast() } label: {
                Label(center.isCasting(page) ? "Casting…" : "Cast…", systemImage: "airplayvideo")
            }
            ForEach(center.sessions.filter { $0.pageID == page.map(ObjectIdentifier.init) }) { session in
                Button("Stop casting to \(session.name)") { center.stop(session) }
            }
        }.buttonStyle(.plain).padding(.horizontal, 16).padding(.vertical, 10)
    }
}

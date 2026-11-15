// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Help › Send Feedback… (Arc's Help › Contact the Team, in the same place; the Command Bar's "Send Feedback"; the
/// sidebar footer's speech bubble): a small sheet on the window in front. A message (required), a reply address
/// (optional), up to five pictures, and the app's details if ticked. Pictures come from ⌘V, a drop, "Add Screenshot…"'s
/// file picker, or Airc's own picture of this window (never the screen; not offered in a private window); each is
/// redrawn without its metadata (AircKit's FeedbackImage). "What will be sent" lists exactly what Send sends. Offline,
/// it's kept and sent later.
final class FeedbackSheet: ObservableObject {
    static var active: FeedbackSheet?

    enum Phase: Equatable {
        case editing
        case sending
        case sent
        /// Offline (or the service busy): saved in the outbox, sent later.
        case queued
    }

    /// One picture to send, as it will go, with its thumbnail.
    struct Attachment: Identifiable {
        enum Source: String { case window, pasted, dropped, chosen }
        let id = UUID()
        let source: Source
        let picture: FeedbackImage.Prepared
        let thumbnail: NSImage
        var label: String {
            switch source {
            case .window: "This window"
            case .pasted: "Pasted picture"
            case .dropped: "Dropped picture"
            case .chosen: "Chosen picture"
            }
        }
    }

    let sheet: NSWindow
    /// The window it's attached to; nil: a window of its own (no browser window in front).
    weak var parent: NSWindow?
    /// The browser window whose picture may be added. nil in a private window and when no browser window is in front.
    weak var controller: WindowController?
    let isPrivate: Bool
    let appInfo: FeedbackReport.AppInfo

    @Published var message = ""
    @Published var email = ""
    @Published var includeAppInfo = false
    @Published private(set) var attachments: [Attachment] = []
    /// Pictures being taken or prepared.
    @Published private(set) var preparing = 0
    @Published private(set) var phase = Phase.editing
    @Published private(set) var problem: String?
    private var keyMonitor: Any?

    init(parent: NSWindow?, controller: WindowController?, isPrivate: Bool, app: AppDelegate?) {
        self.parent = parent
        self.controller = isPrivate ? nil : controller
        self.isPrivate = isPrivate
        appInfo = FeedbackCenter.appInfo(app: app)
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                         styleMask: parent == nil ? [.titled, .closable] : [.titled], backing: .buffered, defer: false)
        sheet.title = "Send Feedback"
        sheet.isReleasedWhenClosed = false
        sheet.contentViewController = NSHostingController(rootView: FeedbackView(sheet: self))
    }

    /// Help › Send Feedback…, the Command Bar and the sidebar's button: on the window in front (a browser window, a
    /// private window), else on its own. One at a time: asking again brings it forward.
    static func show(from window: NSWindow?, app: AppDelegate) {
        if let open = active {
            (open.parent ?? open.sheet).makeKeyAndOrderFront(nil)
            return
        }
        let s: FeedbackSheet
        if let p = PrivateBrowsing.shared.window(for: window) {
            s = FeedbackSheet(parent: p.window, controller: nil, isPrivate: true, app: app)
        } else if let c = app.controller(for: window) ?? (window == nil ? app.controller : nil) {
            s = FeedbackSheet(parent: c.window, controller: c, isPrivate: false, app: app)
        } else {
            s = FeedbackSheet(parent: nil, controller: nil, isPrivate: false, app: app)
        }
        s.present()
    }

    func present() {
        Self.active = self
        // ⌘V with a picture on the pasteboard adds it, whichever field has the keys (text pastes as text).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.window === self.sheet, self.phase == .editing,
                  e.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function]) == .command,
                  e.charactersIgnoringModifiers?.lowercased() == "v", Self.hasPictures(NSPasteboard.general) else { return e }
            self.paste(from: NSPasteboard.general)
            return nil
        }
        if let parent, parent.attachedSheet == nil {
            parent.beginSheet(sheet)
        } else {
            parent = nil
            sheet.center()
            sheet.makeKeyAndOrderFront(nil)
        }
    }

    func close() {
        keyMonitor.map(NSEvent.removeMonitor)
        keyMonitor = nil
        if let parent { parent.endSheet(sheet) }
        sheet.orderOut(nil)
        if Self.active === self { Self.active = nil }
    }

    /// Whether this window's picture can be offered: a browser window, never a private one.
    var offersScreenshot: Bool { controller != nil && !isPrivate }
    var canAddPictures: Bool { phase == .editing && attachments.count + preparing < FeedbackReport.maximumImages }

    private func refuseMore() -> Bool {
        guard canAddPictures else {
            problem = "At most \(FeedbackReport.maximumImages) pictures go with one message."
            NSSound.beep()
            return true
        }
        return false
    }

    /// "Add Screenshot…" › This Window: Airc's own picture of this window, taken now.
    func addWindowPicture() {
        guard let c = controller, !isPrivate, !refuseMore() else { return }
        preparing += 1
        problem = nil
        FeedbackCenter.picture(of: c) { [weak self] image in
            guard let self else { return }
            self.preparing -= 1
            guard self.phase == .editing else { return }
            guard let image, let jpeg = FeedbackCenter.jpeg(image), let rep = NSBitmapImageRep(data: jpeg), let thumb = NSImage(data: jpeg) else {
                self.problem = "Airc couldn’t take a picture of this window."
                return
            }
            let p = FeedbackImage.Prepared(type: "image/jpeg", data: jpeg, width: rep.pixelsWide, height: rep.pixelsHigh)
            self.attachments.append(Attachment(source: .window, picture: p, thumbnail: thumb))
        }
    }

    /// Pictures from a file, the pasteboard or a drop: prepared off the main thread (a 5 MB HEIC takes a moment).
    func add(_ files: [Data], source: Attachment.Source) {
        for data in files {
            guard !refuseMore() else { return }
            preparing += 1
            problem = nil
            DispatchQueue.global(qos: .userInitiated).async {
                let r = FeedbackImage.prepare(data)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.preparing -= 1
                    guard self.phase == .editing else { return }
                    switch r {
                    case .success(let p):
                        guard self.attachments.count < FeedbackReport.maximumImages, let thumb = NSImage(data: p.data) else { return }
                        self.attachments.append(Attachment(source: source, picture: p, thumbnail: thumb))
                    case .failure(let why):
                        self.problem = why.sentence
                    }
                }
            }
        }
    }

    func add(fileURLs urls: [URL], source: Attachment.Source) {
        var files: [Data] = []
        for u in urls {
            let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > FeedbackImage.maximumFile { problem = FeedbackImage.Refusal.tooLarge.sentence; continue }
            if let d = try? Data(contentsOf: u) { files.append(d) }
        }
        add(files, source: source)
    }

    func remove(_ id: UUID) {
        attachments.removeAll { $0.id == id }
        problem = nil
    }

    /// "Add Screenshot…" › Choose File…: PNG, JPEG or HEIC.
    func chooseFiles() {
        guard !refuseMore() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = FeedbackImage.accepted
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose up to \(FeedbackReport.maximumImages - attachments.count) pictures (PNG, JPEG or HEIC, 5 MB each)."
        panel.prompt = "Add"
        panel.beginSheetModal(for: sheet) { [weak self] r in
            guard r == .OK, let self else { return }
            self.add(fileURLs: panel.urls, source: .chosen)
        }
    }

    // MARK: Pasteboard and drops

    static let pictureTypes: [NSPasteboard.PasteboardType] = [.png, .init(UTType.jpeg.identifier), .init(UTType.heic.identifier), .tiff]

    /// Picture files, or a picture with no text beside it but its own address (a screenshot, a copied image).
    static func hasPictures(_ pb: NSPasteboard) -> Bool {
        if !pictureFiles(pb).isEmpty { return true }
        guard pb.availableType(from: pictureTypes) != nil else { return false }
        guard let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return true }
        return text.contains("://") && !text.contains(where: \.isWhitespace)
    }

    static func pictureFiles(_ pb: NSPasteboard) -> [URL] {
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { u in
            guard let t = UTType(filenameExtension: u.pathExtension) else { return false }
            return t.conforms(to: .image)
        }
    }

    /// The picture's bytes on `pb`: PNG, JPEG or HEIC as they are; TIFF (what some apps copy) as PNG.
    static func pictureData(_ pb: NSPasteboard) -> Data? {
        for t in pictureTypes.dropLast() { if let d = pb.data(forType: t) { return d } }
        if let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) { return rep.representation(using: .png, properties: [:]) }
        return nil
    }

    func paste(from pb: NSPasteboard) {
        let files = Self.pictureFiles(pb)
        if !files.isEmpty { return add(fileURLs: files, source: .pasted) }
        if let d = Self.pictureData(pb) { add([d], source: .pasted) }
    }

    /// A drop on the sheet: picture files, or a picture's bytes.
    func drop(_ providers: [NSItemProvider]) -> Bool {
        guard phase == .editing else { return false }
        var any = false
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                any = true
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { [weak self] in self?.add(fileURLs: [url], source: .dropped) }
                }
            } else if let t = [UTType.png, .jpeg, .heic, .tiff].first(where: { p.hasItemConformingToTypeIdentifier($0.identifier) }) {
                any = true
                p.loadDataRepresentation(forTypeIdentifier: t.identifier) { data, _ in
                    guard var data else { return }
                    if t == .tiff, let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) { data = png }
                    DispatchQueue.main.async { [weak self] in self?.add([data], source: .dropped) }
                }
            }
        }
        return any
    }

    /// Exactly what Send sends.
    var report: FeedbackReport {
        FeedbackReport(message: message, email: email, app: includeAppInfo ? appInfo : nil, images: attachments.map(\.picture.image))
    }

    var canSend: Bool {
        phase == .editing && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && preparing == 0
    }

    func send() {
        let r = report
        if let p = r.problem { problem = p; return NSSound.beep() }
        guard canSend else { return NSSound.beep() }
        phase = .sending
        problem = nil
        Task { @MainActor in
            switch await FeedbackCenter.shared.send(r) {
            case .sent: phase = .sent
            case .kept: phase = .queued
            case .refused(let why):
                phase = .editing
                problem = why
            }
        }
    }
}

// MARK: - The view

struct FeedbackView: View {
    @ObservedObject var sheet: FeedbackSheet
    @State private var messageFocused = false
    @State private var dropping = false

    var body: some View {
        Group {
            switch sheet.phase {
            case .sent: done(symbol: "checkmark.circle.fill", tint: .green, title: "Thanks, it’s sent",
                             text: sheet.report.email == nil ? "Every message is read. You didn’t give a reply address, so no one will write back."
                                                            : "Every message is read. A reply, if there is one, goes to \(sheet.report.email ?? "").")
            case .queued: done(symbol: "tray.and.arrow.up.fill", tint: .orange, title: "Saved to send later",
                               text: "Airc can’t reach aircbrowser.com right now, so your feedback is saved on this Mac. It’s sent by itself as soon as Airc is back online; you don’t need to do anything.")
            case .editing, .sending: form
            }
        }
        .padding(24).frame(width: 520).background(.background).testAnchorRoot()
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "bubble.left.and.text.bubble.right").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 40, height: 40).background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Send Feedback").font(.system(size: 20, weight: .semibold))
                    Text("Tell the Airc team what’s working and what isn’t.").foregroundStyle(.secondary)
                }
            }
            ZStack(alignment: .topLeading) {
                FeedbackMessageEditor(sheet: sheet, focused: $messageFocused).testAnchor("feedback.message")
                if sheet.message.isEmpty {
                    Text("What happened, or what would you like to see?").font(.system(size: 13)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 11).padding(.vertical, 6).allowsHitTesting(false)
                }
            }
            .frame(height: 120)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(messageFocused ? 0.25 : 0.08), lineWidth: 1))
            TextField("Reply email (optional)", text: $sheet.email).textFieldStyle(.roundedBorder).testAnchor("feedback.email")

            pictures
            Toggle("Include app info", isOn: $sheet.includeAppInfo).toggleStyle(.checkbox).testAnchor("feedback.appInfo")

            sent.testAnchor("feedback.summary")
            if let p = sheet.problem { Text(p).font(.callout).foregroundStyle(.red).testAnchor("feedback.problem") }
            HStack {
                Spacer()
                Button("Cancel", action: sheet.close).keyboardShortcut(.cancelAction).testAnchor("feedback.cancel")
                if sheet.phase == .sending { ProgressView().controlSize(.small) }
                Button("Send", action: sheet.send).buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                    .disabled(!sheet.canSend).testAnchor("feedback.send")
            }
        }
        .onDrop(of: [.fileURL, .png, .jpeg, .heic, .tiff], isTargeted: $dropping) { sheet.drop($0) }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(-10).allowsHitTesting(false)
            }
        }
    }

    /// Pictures: thumbnails with a remove button each, and "Add Screenshot…" (this window, or a file).
    private var pictures: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Pictures").font(.callout.weight(.semibold))
                Text("\(sheet.attachments.count) of \(FeedbackReport.maximumImages)").font(.caption).foregroundStyle(.secondary)
                    .opacity(sheet.attachments.isEmpty ? 0 : 1)
                Spacer()
                Menu {
                    Button("Screenshot of This Window", action: sheet.addWindowPicture).disabled(!sheet.offersScreenshot)
                    Button("Choose File…", action: sheet.chooseFiles)
                } label: {
                    Text("Add Screenshot…")
                }
                .menuStyle(.button).controlSize(.small).fixedSize().disabled(!sheet.canAddPictures)
                .help("Add a picture of this window, or choose a PNG, JPEG or HEIC file. You can also paste (⌘V) or drop pictures here.")
                .testAnchor("feedback.addScreenshot")
            }
            if sheet.attachments.isEmpty && sheet.preparing == 0 {
                Text(sheet.isPrivate ? "Paste (⌘V) or drop pictures here. A picture of a private window isn’t offered."
                                     : "Paste (⌘V) or drop pictures here: up to 5, PNG, JPEG or HEIC, 5 MB each.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .testAnchor(sheet.isPrivate ? "feedback.privateNote" : "feedback.dropHint")
            } else {
                HStack(spacing: 8) {
                    ForEach(Array(sheet.attachments.enumerated()), id: \.element.id) { i, a in thumbnail(a, index: i) }
                    if sheet.preparing > 0 {
                        ProgressView().controlSize(.small).frame(width: 84, height: 60)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.04)))
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func thumbnail(_ a: FeedbackSheet.Attachment, index: Int) -> some View {
        Image(nsImage: a.thumbnail).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            .frame(width: 84, height: 60).clipped()
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.primary.opacity(0.12), lineWidth: 1))
            .help("\(a.label), \(a.picture.width)×\(a.picture.height)")
            .testAnchor("feedback.thumb.\(index)")
            .overlay(alignment: .topTrailing) {
                Button { sheet.remove(a.id) } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 15)).symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.black.opacity(0.6))
                }
                .buttonStyle(.plain).padding(3).help("Remove").accessibilityLabel("Remove \(a.label)")
                .testAnchor("feedback.remove.\(index)")
            }
    }

    /// "What will be sent": every part, as it will go.
    private var sent: some View {
        let r = sheet.report
        return VStack(alignment: .leading, spacing: 5) {
            Text("What will be sent").font(.callout.weight(.semibold))
            row("Message", r.message.isEmpty ? "—" : (r.message.count == 1 ? "1 character" : "\(r.message.count) characters"))
            row("Reply to", r.email ?? "No address")
            if sheet.attachments.isEmpty {
                row("Pictures", "None")
            } else {
                ForEach(Array(sheet.attachments.enumerated()), id: \.element.id) { i, a in
                    row(i == 0 ? "Pictures" : "", "\(a.label), \(a.picture.width)×\(a.picture.height) \(a.picture.type == "image/png" ? "PNG" : "JPEG"), \(ByteCountFormatter.string(fromByteCount: Int64(a.picture.data.count), countStyle: .file))")
                }
            }
            if let a = r.app {
                ForEach(Array(a.rows.enumerated()), id: \.offset) { _, x in row(x.label, x.value) }
            } else {
                row("App info", "Not included")
            }
            Text((sheet.attachments.isEmpty ? "Nothing else: "
                  : "Pictures go as you see them, without their location, camera or other details. A picture of a window shows its tabs and page. Beyond that, nothing: ")
                 + "no web addresses, tabs, history or profiles. It goes to aircbrowser.com only when you click Send.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 2)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
            Text(value).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }.font(.system(size: 12))
    }

    private func done(symbol: String, tint: Color, title: String, text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 40)).foregroundStyle(tint).padding(.top, 8)
            Text(title).font(.system(size: 20, weight: .semibold)).testAnchor("feedback.doneTitle")
            Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Done", action: sheet.close).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).padding(.top, 6)
                .testAnchor("feedback.done")
        }.frame(maxWidth: .infinity)
    }
}

/// The message field: a plain NSTextView, so a picture pasted (Edit › Paste) or dropped on it joins the pictures
/// instead of going in as a file's path. Text pastes and drops as text.
struct FeedbackMessageEditor: NSViewRepresentable {
    let sheet: FeedbackSheet
    @Binding var focused: Bool

    final class TextView: NSTextView {
        weak var feedback: FeedbackSheet?
        var onFocus: ((Bool) -> Void)?
        private var focusedOnce = false

        override func paste(_ sender: Any?) {
            if let feedback, FeedbackSheet.hasPictures(.general) { return feedback.paste(from: .general) }
            super.paste(sender)
        }
        override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
            super.acceptableDragTypes + FeedbackSheet.pictureTypes + [.fileURL]
        }
        private func pictures(_ info: NSDraggingInfo) -> Bool { feedback?.phase == .editing && FeedbackSheet.hasPictures(info.draggingPasteboard) }
        override func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation { pictures(info) ? .copy : super.draggingEntered(info) }
        override func draggingUpdated(_ info: NSDraggingInfo) -> NSDragOperation { pictures(info) ? .copy : super.draggingUpdated(info) }
        override func prepareForDragOperation(_ info: NSDraggingInfo) -> Bool { pictures(info) || super.prepareForDragOperation(info) }
        override func performDragOperation(_ info: NSDraggingInfo) -> Bool {
            guard pictures(info), let feedback else { return super.performDragOperation(info) }
            let pb = info.draggingPasteboard
            let files = FeedbackSheet.pictureFiles(pb)
            if !files.isEmpty { feedback.add(fileURLs: files, source: .dropped) }
            else if let d = FeedbackSheet.pictureData(pb) { feedback.add([d], source: .dropped) }
            return true
        }
        override func concludeDragOperation(_ info: NSDraggingInfo?) {
            if let info, pictures(info) { return }
            super.concludeDragOperation(info)
        }
        override func becomeFirstResponder() -> Bool {
            let ok = super.becomeFirstResponder()
            if ok { onFocus?(true) }
            return ok
        }
        override func resignFirstResponder() -> Bool {
            let ok = super.resignFirstResponder()
            if ok { onFocus?(false) }
            return ok
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, !focusedOnce else { return }
            focusedOnce = true
            DispatchQueue.main.async { [weak self] in
                guard let self, let w = self.window else { return }
                w.makeFirstResponder(self)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var sheet: FeedbackSheet
        init(sheet: FeedbackSheet) { self.sheet = sheet }
        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView, sheet.message != tv.string else { return }
            sheet.message = tv.string
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(sheet: sheet) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let tv = TextView(frame: NSRect(x: 0, y: 0, width: 460, height: 120))
        tv.feedback = sheet
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.font = .systemFont(ofSize: 13)
        tv.textColor = .labelColor
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 6, height: 6)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.setAccessibilityLabel("Message")
        tv.delegate = context.coordinator
        tv.string = sheet.message
        tv.updateDragTypeRegistration()
        let binding = $focused
        tv.onFocus = { on in DispatchQueue.main.async { binding.wrappedValue = on } }
        scroll.documentView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.sheet = sheet
        guard let tv = scroll.documentView as? NSTextView, tv.string != sheet.message else { return }
        tv.string = sheet.message
    }
}

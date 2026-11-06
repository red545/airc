// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit
import SwiftUI

// App-only helpers next to AircDesign's controls: AppKit images of profile avatars (menus), remote favicons and the
// app icon. The controls themselves (segmented, slider, checkbox, chips, theme discs, avatars, keycaps) are AircDesign's.

/// The same avatar as an image, for AppKit (menus, the Space header's profile indicator). Cached per look.
enum ProfileAvatarImage {
    private static var cache: [String: NSImage] = [:]

    static func image(_ p: Profile, size: CGFloat) -> NSImage { image(emoji: p.emoji, name: p.name, color: p.color.aircColor, size: size) }

    static func image(emoji: String, name: String, color: AircColor, size: CGFloat) -> NSImage {
        let key = "\(emoji)|\(emoji.isEmpty ? name.prefix(1) : "")|\(color.hexString)|\(size)"
        if let hit = cache[key] { return hit }
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            AircProfileColor.pastel(color).nsColor.setFill()
            NSBezierPath(ovalIn: r).fill()
            NSColor.black.withAlphaComponent(0.08).setStroke()
            let ring = NSBezierPath(ovalIn: r.insetBy(dx: 0.25, dy: 0.25))
            ring.lineWidth = 0.5
            ring.stroke()
            let text = emoji.isEmpty ? String(name.prefix(1)).uppercased() : emoji
            let font = emoji.isEmpty ? NSFont.systemFont(ofSize: size * 0.44, weight: .semibold) : NSFont.systemFont(ofSize: size * 0.56)
            let ink = emoji.isEmpty ? AircColor.mix(color.alpha(1), .black(), 0.35).nsColor : NSColor.black
            let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: ink])
            let b = s.size()
            s.draw(at: NSPoint(x: (r.width - b.width) / 2, y: (r.height - b.height) / 2))
            return true
        }
        cache[key] = img
        return img
    }
}

/// A favicon for SwiftUI, from FaviconCache (memory, disk, then network).
struct RemoteFavicon: View {
    let pageURL: String
    var size: CGFloat = 18
    @State private var image: NSImage?
    @Environment(\.aircTheme) private var theme

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(theme.tileHoverFill.color).padding(1)
            }
        }
        .frame(width: size, height: size)
        .onAppear(perform: load)
        .onChange(of: pageURL) { _, _ in load() }
    }

    private func load() {
        guard let key = FaviconCache.guess(for: pageURL) else { return }
        if let c = FaviconCache.shared.cached(key) { image = c; return }
        // Waits through FaviconCache's retries of a failed fetch, and only for the page it was asked for.
        FaviconCache.shared.load(key, retrying: true) { img in
            if let img, FaviconCache.guess(for: pageURL) == key { image = img }
        }
    }
}

/// The app icon (AppIcon.icns in the bundle) for SwiftUI.
enum AppIconImage {
    static let image: NSImage = Bundle.main.image(forResource: "AppIcon") ?? NSApp.applicationIconImage ?? NSImage()
}

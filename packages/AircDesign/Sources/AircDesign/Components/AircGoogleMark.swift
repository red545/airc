// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

// The Google "G" for "Sign in to Google" (SP-12; docs/design.md §7). Drawn in code from the four-colour geometry of
// Google's sign-in branding (48 × 48 artboard); never fetched. Google's branding rules: keep the four colours, never
// recolour, rotate or crop it, and give it room. It stands on white or on a light card; in dark themes it sits on its
// own white disc (`onDisc`).

/// The four-colour Google "G".
public struct AircGoogleMark: View {
    private let size: CGFloat
    private let onDisc: Bool

    /// `onDisc` puts the mark on a white disc (dark themes, where the G's blue and red would sink into the card).
    public init(size: CGFloat = 16, onDisc: Bool = false) {
        self.size = size
        self.onDisc = onDisc
    }

    public var body: some View {
        let mark = Canvas { ctx, s in
            let k = s.width / 48
            for part in AircGoogleMarkGeometry.parts {
                ctx.fill(part.path.applying(CGAffineTransform(scaleX: k, y: k)), with: .color(part.color.color))
            }
        }
        Group {
            if onDisc {
                mark.frame(width: size * 0.72, height: size * 0.72)
                    .frame(width: size, height: size)
                    .background(Circle().fill(Color.white))
            } else {
                mark.frame(width: size, height: size)
            }
        }
        .accessibilityLabel("Google")
    }

    /// The mark as an image (menus, AppKit rows).
    @MainActor
    public static func image(size: CGFloat = 16, onDisc: Bool = false, scale: CGFloat = 2) -> NSImage {
        let r = ImageRenderer(content: AircGoogleMark(size: size, onDisc: onDisc))
        r.scale = scale
        let img = r.nsImage ?? NSImage(size: NSSize(width: size, height: size))
        img.size = NSSize(width: size, height: size)
        img.accessibilityDescription = "Google"
        return img
    }
}

/// The G's four paths on a 48 × 48 artboard (y down).
public enum AircGoogleMarkGeometry {
    public struct Part: Sendable {
        public let color: AircColor
        public let path: Path
    }

    /// Google blue, red, yellow and green.
    public static let blue = AircColor(0x4285F4)
    public static let red = AircColor(0xEA4335)
    public static let yellow = AircColor(0xFBBC05)
    public static let green = AircColor(0x34A853)

    public static let parts: [Part] = [
        Part(color: red, path: svgPath("M24 9.5c3.54 0 6.71 1.22 9.21 3.6l6.85-6.85C35.9 2.38 30.47 0 24 0 14.62 0 6.51 5.38 2.56 13.22l7.98 6.19C12.43 13.72 17.74 9.5 24 9.5z")),
        Part(color: blue, path: svgPath("M46.98 24.55c0-1.57-.15-3.09-.38-4.55H24v9.02h12.94c-.58 2.96-2.26 5.48-4.78 7.18l7.73 6c4.51-4.18 7.09-10.36 7.09-17.65z")),
        Part(color: yellow, path: svgPath("M10.53 28.59c-.48-1.45-.76-2.99-.76-4.59s.27-3.14.76-4.59l-7.98-6.19C.92 16.46 0 20.12 0 24c0 3.88.92 7.54 2.56 10.78l7.97-6.19z")),
        Part(color: green, path: svgPath("M24 48c6.48 0 11.93-2.13 15.89-5.81l-7.73-6c-2.15 1.45-4.92 2.3-8.16 2.3-6.26 0-11.57-4.22-13.47-9.91l-7.98 6.19C6.51 42.62 14.62 48 24 48z")),
    ]

    /// A minimal SVG path reader (M L H V C S Z, absolute and relative): enough for the mark, no dependencies.
    static func svgPath(_ d: String) -> Path {
        var tokens: [String] = []
        var num = ""
        func flush() { if !num.isEmpty { tokens.append(num); num = "" } }
        for ch in d {
            if ch.isLetter && ch != "e" {
                flush(); tokens.append(String(ch))
            } else if ch == "-" {
                if num.last == "e" { num.append(ch) } else { flush(); num = "-" }
            } else if ch == "." {
                if num.contains(".") { flush() }
                num.append(ch)
            } else if ch == " " || ch == "," {
                flush()
            } else {
                num.append(ch)
            }
        }
        flush()

        var p = Path()
        var i = 0
        var cmd: Character = "M"
        var cur = CGPoint.zero, start = CGPoint.zero, lastCtrl: CGPoint?
        func n() -> CGFloat { defer { i += 1 }; return CGFloat(Double(tokens[i]) ?? 0) }
        while i < tokens.count {
            if let c = tokens[i].first, c.isLetter { cmd = c; i += 1 }
            let rel = cmd.isLowercase
            let o = rel ? cur : .zero
            switch cmd.uppercased().first! {
            case "M":
                cur = CGPoint(x: o.x + n(), y: o.y + n()); start = cur; p.move(to: cur); lastCtrl = nil
                cmd = rel ? "l" : "L"
            case "L":
                cur = CGPoint(x: o.x + n(), y: o.y + n()); p.addLine(to: cur); lastCtrl = nil
            case "H":
                cur = CGPoint(x: (rel ? cur.x : 0) + n(), y: cur.y); p.addLine(to: cur); lastCtrl = nil
            case "V":
                cur = CGPoint(x: cur.x, y: (rel ? cur.y : 0) + n()); p.addLine(to: cur); lastCtrl = nil
            case "C":
                let c1 = CGPoint(x: o.x + n(), y: o.y + n()), c2 = CGPoint(x: o.x + n(), y: o.y + n())
                cur = CGPoint(x: o.x + n(), y: o.y + n())
                p.addCurve(to: cur, control1: c1, control2: c2); lastCtrl = c2
            case "S":
                let c1 = lastCtrl.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                let c2 = CGPoint(x: o.x + n(), y: o.y + n())
                cur = CGPoint(x: o.x + n(), y: o.y + n())
                p.addCurve(to: cur, control1: c1, control2: c2); lastCtrl = c2
            case "Z":
                p.closeSubpath(); cur = start; lastCtrl = nil
            default:
                i += 1
            }
        }
        return p
    }
}

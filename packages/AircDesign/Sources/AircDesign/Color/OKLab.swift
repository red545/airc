// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

/// A colour in Björn Ottosson's OKLab space. `l` is perceived lightness, 0 (black) to 1 (white).
public struct OKLab: Hashable, Sendable {
    public var l: Double
    public var a: Double
    public var b: Double

    public init(l: Double, a: Double, b: Double) {
        self.l = l
        self.a = a
        self.b = b
    }

    /// Chroma, the distance from the grey axis.
    public var chroma: Double { (a * a + b * b).squareRoot() }
    /// Hue angle in degrees, 0..<360.
    public var hue: Double {
        let h = atan2(b, a) * 180 / .pi
        return h < 0 ? h + 360 : h
    }

    /// Builds a colour from lightness, chroma and hue (degrees), i.e. OKLCH.
    public static func lch(_ l: Double, _ c: Double, _ h: Double) -> OKLab {
        let r = h * .pi / 180
        return OKLab(l: l, a: c * cos(r), b: c * sin(r))
    }
}

extension AircColor {
    /// The colour in OKLab (alpha dropped).
    public var oklab: OKLab {
        let r = red.linearized, g = green.linearized, b = blue.linearized
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return OKLab(
            l: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            a: 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            b: 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        )
    }

    /// Converts from OKLab. Out-of-gamut colours keep their lightness and hue and lose chroma until they fit.
    public init(oklab: OKLab, alpha: Double = 1) {
        var lab = oklab
        var rgb = AircColor.linearRGB(lab)
        if !AircColor.inGamut(rgb) {
            var lo = 0.0, hi = 1.0
            for _ in 0..<24 {
                let mid = (lo + hi) / 2
                lab = OKLab(l: oklab.l, a: oklab.a * mid, b: oklab.b * mid)
                if AircColor.inGamut(AircColor.linearRGB(lab)) { lo = mid } else { hi = mid }
            }
            lab = OKLab(l: oklab.l, a: oklab.a * lo, b: oklab.b * lo)
            rgb = AircColor.linearRGB(lab)
        }
        self.init(red: rgb.0.clamped01.gammaEncoded, green: rgb.1.clamped01.gammaEncoded, blue: rgb.2.clamped01.gammaEncoded, alpha: alpha)
    }

    /// Perceptual blend in OKLab: `t` = 0 gives `a`, 1 gives `b`. Alpha blends linearly.
    public static func mix(_ a: AircColor, _ b: AircColor, _ t: Double) -> AircColor {
        let p = a.oklab, q = b.oklab
        return AircColor(
            oklab: OKLab(l: p.l + (q.l - p.l) * t, a: p.a + (q.a - p.a) * t, b: p.b + (q.b - p.b) * t),
            alpha: a.alpha + (b.alpha - a.alpha) * t
        )
    }

    private static func linearRGB(_ lab: OKLab) -> (Double, Double, Double) {
        let l_ = lab.l + 0.3963377774 * lab.a + 0.2158037573 * lab.b
        let m_ = lab.l - 0.1055613458 * lab.a - 0.0638541728 * lab.b
        let s_ = lab.l - 0.0894841775 * lab.a - 1.2914855480 * lab.b
        let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
        return (
            4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        )
    }

    private static func inGamut(_ rgb: (Double, Double, Double)) -> Bool {
        let e = 1e-4
        return rgb.0 >= -e && rgb.0 <= 1 + e && rgb.1 >= -e && rgb.1 <= 1 + e && rgb.2 >= -e && rgb.2 <= 1 + e
    }
}

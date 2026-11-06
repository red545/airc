// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

/// Reads Arc's stored `windowTheme` (TH-4) into a SpaceTheme, so imported Spaces look as they did in Arc.
///
/// Arc stores `windowTheme.background.single._0.style.color._0` as either `blendedSingleColor{color, modifiers}`
/// or `blendedGradient{baseColors[], overlayColors[], modifiers}`, with `modifiers.intensityFactor`,
/// `modifiers.noiseFactor` and `modifiers.overlay` (Arc ref §4.2). Older files only have
/// `primaryColorPalette.midTone`. Colours are `{red, green, blue, alpha}` in 0…1. The input is JSON as
/// `JSONSerialization` returns it.
public enum ArcTheme {
    public static func theme(from raw: Any?, fallbackColors: [String] = []) -> SpaceTheme {
        let root = raw as? [String: Any] ?? [:]
        if let style = find(["blendedGradient", "blendedSingleColor"], in: root["background"] ?? root) {
            let node = unwrap(style.value)
            var colors: [RGBA] = []
            if style.key == "blendedGradient" {
                colors += colorList(node["baseColors"])
                colors += colorList(node["overlayColors"])
            } else if let c = color(node["color"]) ?? color(node) {
                colors.append(c)
            }
            let m = unwrap(node["modifiers"])
            let intensity = number(m["intensityFactor"]) ?? SpaceTheme.defaultIntensity
            let grain = number(m["noiseFactor"]) ?? 0
            if !colors.isEmpty {
                return SpaceTheme(colors: Array(colors.prefix(3)), intensity: intensity, grain: grain, appearance: appearance(root))
            }
        }
        if let mid = color(unwrap(root["primaryColorPalette"])["midTone"]) {
            return SpaceTheme(colors: [mid], appearance: appearance(root))
        }
        let hex = fallbackColors.compactMap(RGBA.init(hex:))
        return hex.isEmpty ? .neutral : SpaceTheme(colors: Array(hex.prefix(3)))
    }

    /// Arc's per-theme light/dark choice, when present.
    static func appearance(_ root: [String: Any]) -> Appearance {
        for key in ["colorScheme", "appearance", "translucencyStyle"] {
            if let s = label(root[key])?.lowercased() {
                if s.contains("dark") { return .dark }
                if s.contains("light") { return .light }
            }
        }
        return .auto
    }

    /// `{"_0": x}` → x (Swift enum payloads in Arc's JSON).
    static func unwrap(_ v: Any?) -> [String: Any] {
        var o = v as? [String: Any] ?? [:]
        while o.count == 1, let inner = o["_0"] as? [String: Any] { o = inner }
        return o
    }

    static func label(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let o = v as? [String: Any], o.count == 1 { return o.keys.first }
        return nil
    }

    static func number(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let n = v as? NSNumber { return n.doubleValue }
        if let i = v as? Int { return Double(i) }
        return nil
    }

    static func color(_ v: Any?) -> RGBA? {
        let o = unwrap(v)
        if let inner = o["color"] { return color(inner) }
        guard let r = number(o["red"]), let g = number(o["green"]), let b = number(o["blue"]) else { return nil }
        func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
        return RGBA(clamp(r), clamp(g), clamp(b))
    }

    static func colorList(_ v: Any?) -> [RGBA] {
        (v as? [Any] ?? []).compactMap(color)
    }

    /// Depth-first search for the first key in `keys`.
    static func find(_ keys: [String], in v: Any?, depth: Int = 0) -> (key: String, value: Any)? {
        guard depth < 12 else { return nil }
        if let o = v as? [String: Any] {
            for k in keys { if let x = o[k] { return (k, x) } }
            for k in o.keys.sorted() { if let f = find(keys, in: o[k], depth: depth + 1) { return f } }
        } else if let a = v as? [Any] {
            for x in a { if let f = find(keys, in: x, depth: depth + 1) { return f } }
        }
        return nil
    }

    /// A Chromium profile colour (`profile_color`, a signed 32-bit ARGB integer) as RGBA.
    public static func chromiumColor(_ v: Any?) -> RGBA? {
        guard let n = number(v) else { return nil }
        let u = UInt32(truncatingIfNeeded: Int64(n))
        return RGBA(Double((u >> 16) & 0xFF) / 255, Double((u >> 8) & 0xFF) / 255, Double(u & 0xFF) / 255)
    }
}

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

/// SB-61: what has to hold when the hidden sidebar's reveal dwell (about 100 ms) ends. The pointer moved into the edge
/// strip of the key window when the dwell started; any of these can change before it ends.
public enum SidebarRevealGate {
    public struct Conditions: Equatable, Sendable {
        public var windowIsKey: Bool
        public var sidebarHidden: Bool
        public var alreadyRevealed: Bool
        public var pointerInStrip: Bool
        public var sheetOrModal: Bool
        public var menuOpen: Bool
        public var mouseButtonDown: Bool

        public init(windowIsKey: Bool, sidebarHidden: Bool, alreadyRevealed: Bool, pointerInStrip: Bool,
                    sheetOrModal: Bool, menuOpen: Bool, mouseButtonDown: Bool) {
            self.windowIsKey = windowIsKey
            self.sidebarHidden = sidebarHidden
            self.alreadyRevealed = alreadyRevealed
            self.pointerInStrip = pointerInStrip
            self.sheetOrModal = sheetOrModal
            self.menuOpen = menuOpen
            self.mouseButtonDown = mouseButtonDown
        }
    }

    /// Why a dwell that ended doesn't reveal.
    public enum Refusal: String, Sendable {
        case notKey = "the window isn't key"
        case notHidden = "the sidebar isn't hidden"
        case revealed = "the sidebar is already out"
        case pointerLeft = "the pointer left the edge strip"
        case sheet = "a sheet or modal window is up"
        case menu = "a menu is open"
        case drag = "a mouse button is down (a press or a drag)"
    }

    /// Nil when the sidebar may reveal; the first condition that fails otherwise.
    public static func refusal(_ c: Conditions) -> Refusal? {
        if !c.windowIsKey { return .notKey }
        if !c.sidebarHidden { return .notHidden }
        if c.alreadyRevealed { return .revealed }
        if c.sheetOrModal { return .sheet }
        if c.menuOpen { return .menu }
        if c.mouseButtonDown { return .drag }
        if !c.pointerInStrip { return .pointerLeft }
        return nil
    }
}

/// WIN-4: dragging the sidebar's inner edge.
public enum SidebarResize {
    /// Dragging past the minimum hides the sidebar (Arc ref §1: "Dragging past the minimum hides the sidebar, keeping
    /// its last width"). The research gives no extra distance, so any width below the minimum hides it.
    public static func hides(proposedWidth: Double, minWidth: Double) -> Bool {
        proposedWidth < minWidth
    }
}

/// SP-21 / SP-25: the pulls past either end of the Spaces.
public enum SwipeOverscroll {
    /// The pull shown past the last Space that readies New Space (Arc: "readies at 22.7 pt"), and past the first that
    /// readies the Library (Arc measured no separate distance; the same one, mirrored). Points of the pull on screen,
    /// after the rubber band.
    public static let detent: Double = 22.7
    /// Once ready, the pull has to come back this far below the detent to disarm, so a finger resting on it doesn't
    /// tick the haptic on and off.
    public static let hysteresis: Double = 3

    public enum End: Equatable, Sendable { case first, last }

    /// The rubber-banded pull past an end, in points (0 inside the pages). `position` is the raw fractional page.
    public static func pull(position: Double, pageCount: Int, pageWidth: Double) -> (end: End, points: Double)? {
        let last = Double(max(pageCount - 1, 0))
        let limit = pageWidth * 0.5
        if position < 0 { return (.first, SwipePaging.rubberBand(-position * pageWidth, limit: limit)) }
        if position > last { return (.last, SwipePaging.rubberBand((position - last) * pageWidth, limit: limit)) }
        return nil
    }

    /// Whether a pull of `points` is ready, given whether it was ready a moment ago.
    public static func isReady(points: Double, wasReady: Bool) -> Bool {
        wasReady ? points >= detent - hysteresis : points >= detent
    }

    /// The finger travel (in points of scroll delta) that shows `points` of pull: the rubber band's inverse.
    public static func fingerTravel(forPull points: Double, pageWidth: Double, coefficient: Double = 0.55) -> Double {
        let limit = pageWidth * 0.5
        guard points > 0, points < limit else { return points <= 0 ? 0 : .infinity }
        return (1 / (1 - points / limit) - 1) * limit / coefficient / SwipePaging.trackingRatio
    }
}

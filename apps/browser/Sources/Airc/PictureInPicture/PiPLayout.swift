// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit

/// Every position, size, colour and timing of Airc's picture-in-picture controls, in one place, so the owner's hover
/// screenshots of Arc's PiP can tune them quickly. Used by the video PiP, the Little Arc mini player (the same engine
/// window) and the call window (`PiPControlsView`), and by the Document PiP top bar (`PiPTopBarView`).
///
/// Where a value comes from:
/// - **measured**: read from Arc 1.171's bundle (ARC_PictureInPicture.bundle's asset catalog, its UI strings);
/// - **structure**: Arc's view types say the control exists and roughly where (`CloseButton` with `CornerButtonStyle`,
///   `BackToTabButton` as a pill, `PlayControls` with `AnimatedSkipButton` and `BackForwardButton`, `BasicScrubber`,
///   `MeetingControls`, `PIPSizeClass`), not the exact point;
/// - **inferred**: chosen by eye to look like Arc, waiting for the owner's screenshot. Most positions are inferred.
enum PiPLayout {
    // MARK: Size classes (Arc's `PIPSizeClass`: tiny, small, normal, large; Airc uses two)

    enum SizeClass: String { case compact, regular }

    /// Below this width or height the controls are compact: fewer of them, and smaller (inferred). Chromium's smallest
    /// video PiP is 284 × 160.
    static let compactBelow = NSSize(width: 340, height: 196)

    static func sizeClass(for size: NSSize) -> SizeClass {
        size.width < compactBelow.width || size.height < compactBelow.height ? .compact : .regular
    }

    // MARK: Corners: ✕ at the top left, Back to Tab at the top right (structure; positions inferred)

    /// From the window's top and side edges to the corner buttons (inferred). The engine leaves the outer 8 pt to
    /// resizing, so nothing sits closer than that.
    static func cornerInset(_ c: SizeClass) -> CGFloat { c == .compact ? 8 : 10 }
    /// The round corner button (✕, mute) and its glyph (inferred).
    static func cornerButton(_ c: SizeClass) -> CGFloat { c == .compact ? 24 : 28 }
    static func cornerGlyph(_ c: SizeClass) -> CGFloat { c == .compact ? 10 : 11 }
    /// The Back to Tab pill (`PIPPillActionButtonStyle`: height, horizontal padding; inferred). Compact shows the glyph
    /// only, in a round button.
    static func pillHeight(_ c: SizeClass) -> CGFloat { cornerButton(c) }
    static let pillPadding: CGFloat = 10
    static let pillGap: CGFloat = 5
    static let pillFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    /// The mute button sits left of Back to Tab, this far from it (inferred).
    static let cornerGap: CGFloat = 6

    // MARK: Centre: skip back, play/pause, skip ahead; previous/next track outside them (structure; sizes inferred)

    static func playButton(_ c: SizeClass) -> CGFloat { c == .compact ? 40 : 52 }
    static func playGlyph(_ c: SizeClass) -> CGFloat { c == .compact ? 22 : 28 }
    static func skipButton(_ c: SizeClass) -> CGFloat { c == .compact ? 0 : 40 }
    static func skipGlyph(_ c: SizeClass) -> CGFloat { 21 }
    static func trackButton(_ c: SizeClass) -> CGFloat { c == .compact ? 30 : 34 }
    static func trackGlyph(_ c: SizeClass) -> CGFloat { c == .compact ? 13 : 15 }
    /// Between the centre buttons (inferred).
    static func centreGap(_ c: SizeClass) -> CGFloat { c == .compact ? 14 : 20 }
    /// Arc skips 15 s each way (measured: "Skip back 15 seconds", "Skip ahead 15 seconds").
    static let skipSeconds: Double = 15
    /// The skip arrow turns this far on a press, then springs back (`AnimatedSkipButton`; inferred).
    static let skipTurn: CGFloat = .pi / 7

    // MARK: Bottom: the scrubber with elapsed and remaining time (structure; sizes inferred)

    static func scrubberInset(_ c: SizeClass) -> CGFloat { c == .compact ? 10 : 14 }
    /// From the bottom edge to the bar's centre.
    static func scrubberBottom(_ c: SizeClass) -> CGFloat { c == .compact ? 14 : 18 }
    /// `BasicScrubber.barHeight` at rest and under the pointer, and its `draggableHeight` (inferred).
    static let barHeight: CGFloat = 4
    static let barHoverHeight: CGFloat = 6
    static let draggableHeight: CGFloat = 22
    static let knob: CGFloat = 12
    /// The time labels sit above the bar's ends, this far up (regular only; inferred).
    static let timeRise: CGFloat = 15
    static let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    /// "Drag upwards to seek precisely" (measured string): every `precisionStep` points up halves the speed, down to ⅛.
    static let precisionStep: CGFloat = 32

    // MARK: Calls: microphone, camera and leave in a pill at the bottom centre (structure; sizes inferred)

    static func meetingButton(_ c: SizeClass) -> CGFloat { c == .compact ? 30 : 36 }
    static func meetingGlyph(_ c: SizeClass) -> CGFloat { c == .compact ? 13 : 15 }
    static func meetingGap(_ c: SizeClass) -> CGFloat { c == .compact ? 8 : 10 }
    static func meetingBottom(_ c: SizeClass) -> CGFloat { c == .compact ? 10 : 14 }

    // MARK: Look

    static let glyph = NSColor.white
    /// Round button plates (✕, mute, the pill, track buttons): a light glass over the scrim (inferred).
    static let plate = NSColor.white.withAlphaComponent(0.16)
    static let plateHover = NSColor.white.withAlphaComponent(0.26)
    static let platePressed = NSColor.white.withAlphaComponent(0.34)
    /// Buttons grow a little under the pointer (Arc's `GrowOnHover`; scale inferred).
    static let hoverScale: CGFloat = 1.08
    /// The microphone or camera off: a red glyph on a white plate (inferred); leave: white on red.
    static let off = NSColor(red: 0.98, green: 0.30, blue: 0.27, alpha: 1)
    static let leave = NSColor(red: 0.92, green: 0.23, blue: 0.21, alpha: 1)
    /// The scrim over the video while the controls show: a soft dim plus darker top and bottom bands (inferred).
    static let scrimDim: CGFloat = 0.16
    static let scrimEdge: CGFloat = 0.42
    static let scrimTopShare: CGFloat = 0.38
    static let scrimBottomShare: CGFloat = 0.45
    static let barTrack = NSColor.white.withAlphaComponent(0.30)
    static let barFill = NSColor.white
    static let timeColor = NSColor.white.withAlphaComponent(0.92)

    // MARK: Motion

    /// The controls fade in on hover and out this long after the pointer stops (brief: about 2 s).
    static let hideAfter: TimeInterval = 2.0
    /// When the pointer leaves the window (inferred).
    static let hideAfterExit: TimeInterval = 0.35
    /// On arrival they show for a moment, so you see what's there.
    static let introHold: TimeInterval = 1.6
    /// Fades and the press/hover scale ride springs (design.md §5).
    static let fadeIn = (response: 0.20, damping: 1.0)
    static let fadeOut = (response: 0.32, damping: 1.0)

    // MARK: Document PiP top bar (Meet's own window)

    /// Arc's `DocumentPiPTopBarBackgroundColor`, the same in light and dark (measured: 0.129, 0.129, 0.137).
    static let topBarColor = NSColor(srgbRed: 0.129, green: 0.129, blue: 0.137, alpha: 1)
    /// Arc's `DocumentPiPHairlineColor` under the bar, the same in light and dark (measured: white at 0.2).
    static let topBarHairline = NSColor.white.withAlphaComponent(0.2)
    /// The bar covers Chromium's own top bar exactly (the engine reports its height, 34 pt in Chromium 156); this is
    /// the fallback.
    static let topBarHeight: CGFloat = 34
    static let topBarButton: CGFloat = 24
    static let topBarInset: CGFloat = 8
    static let topBarFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let topBarText = NSColor.white.withAlphaComponent(0.62)
}

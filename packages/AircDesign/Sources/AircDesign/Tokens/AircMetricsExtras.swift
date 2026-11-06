// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import CoreGraphics

// Geometry added in design pass 3: the values the app kept in `DesignGaps`, the profile flow (spec SP-10…15),
// the theme picker, the Library and folder preview, and loading rows. Arc's measurements are marked "Arc";
// everything else is a design decision recorded in docs/design.md.

extension AircMetrics.Sidebar {
    /// Reload's plate ends this far from the sidebar edge (Arc ref §2.1).
    public static let headerButtonEndInset: CGFloat = 6
    /// In full screen the toggle moves left: glyph at x 20–38.5 (Arc ref §1).
    public static let toggleXFullscreen: CGFloat = 13
    /// Favorites start one URL-field height plus the side inset below the URL field's top.
    public static var favoritesTop: CGFloat { urlFieldHeight + inset }
    /// Width of the window-edge strip that reveals a hidden sidebar.
    public static let revealEdge: CGFloat = 6
    /// Pointer dwell before the hidden sidebar slides in (Arc ref §2.10).
    public static let revealDelay: Double = 0.100
}

extension AircMetrics.Divider {
    /// Height the divider takes in the list; its line sits 7 pt down.
    public static let block: CGFloat = 14
    /// "Clear" sits this far from the trailing edge; the line stops 8 pt before it.
    public static let clearGap: CGFloat = 8
}

extension AircMetrics.Row {
    /// Titles end in a fade over this width, never a hard clip or "…" (owner feedback P2).
    public static let titleFade: CGFloat = 24
    /// While a trailing control shows (close, audio, Clear), the title's fade ends this far before it.
    public static let titleFadeGap: CGFloat = 4
    /// Selected row under the pointer, dark themes (Arc 0.36).
    public static let selectedHoverAlphaDark: Double = 0.36
    /// The drop line while dragging rows (Arc: 2 pt, 8 pt ring at its start).
    public static let dropLineWidth: CGFloat = 2
    public static let dropLineRing: CGFloat = 8
}

extension AircMetrics {
    /// The loading ring in a row's favicon slot (SB-44, owner feedback P2).
    public enum Loading {
        /// Ring diameter, centred in the 18 pt favicon box.
        public static let ring: CGFloat = 14
        public static let stroke: CGFloat = 1.75
        /// The visible arc, as a fraction of the circle.
        public static let arc: CGFloat = 0.28
        /// One turn.
        public static let period: Double = 0.9
        /// Fast loads never show a ring: it appears only after this long.
        public static let showDelay: Double = 0.150
        /// Fade in and out, and the favicon's fade back in.
        public static let fade: Double = 0.120
        /// The URL field's progress line (2 pt, accent).
        public static let progressLine: CGFloat = 2
    }

    /// The Create a Space card inside the sidebar (SP-10, Arc ref §3.2).
    public enum CreateSpace {
        /// Rows and the button are 200 pt wide (Arc), centred in the 228 pt sidebar.
        public static let width: CGFloat = 200
        public static let rowHeight: CGFloat = 36
        public static let rowRadius: CGFloat = 10
        public static let rowGap: CGFloat = 8
        public static let illustration = CGSize(width: 96, height: 64)
        public static let iconButton: CGFloat = 28
        /// Create Space (Arc: 36 pt, radius 8, 0.4 until a name is typed).
        public static let buttonHeight: CGFloat = 36
        public static let buttonRadius: CGFloat = 8
        public static let disabledOpacity: Double = 0.4
        /// The card leaves bottom-up: each part fades and sinks over 150 ms, staggered 0 / 80 / 130 ms.
        public static let exitDuration: Double = 0.150
        public static let exitStagger: [Double] = [0, 0.080, 0.130]
        public static let exitSink: CGFloat = 8
        /// Arc's icon picker popover (Arc ref §2.4).
        public static let iconPicker = CGSize(width: 273, height: 273)
    }

    /// Profiles as identities (SP-11, SP-15).
    public enum Profile {
        /// The pill in the Create a Space card and the hovered indicator: 22 pt, avatar 16.
        public static let pillHeight: CGFloat = 22
        public static let pillAvatar: CGFloat = 16
        /// Footer cells: a 6 pt dot in the profile colour, 6 pt in from the cell's bottom-right, with a 1.5 pt
        /// cut-out ring in the window colour.
        public static let footerDot: CGFloat = 6
        public static let footerDotInset: CGFloat = 6
        public static let footerDotRing: CGFloat = 1.5
        /// Avatar in the profile menu, Create Profile preview, Settings.
        public static let menuAvatar: CGFloat = 22
        public static let previewAvatar: CGFloat = 64
        public static let settingsAvatar: CGFloat = 28
        /// An emoji avatar's disc: the profile colour mixed with white in OKLab at this share of colour.
        public static let pastelShare: Double = 0.28
        /// The two-step Create Profile card, centred over the page card (slightly above centre).
        public static let dialogWidth: CGFloat = 520
        public static let dialogPadding: CGFloat = 28
        /// Space tiles in step 2.
        public static let spaceTile = CGSize(width: 84, height: 64)
        public static let spaceTileRadius: CGFloat = 12
        public static let spaceTileGap: CGFloat = 10
        /// "Sign in to Google" in a new profile's Space (SP-12): 212 × 112 at the top of Today.
        public static let signInCardHeight: CGFloat = 112
        public static let signInCardRadius: CGFloat = 12
        /// Profile names (Arc's `ProfileNameInputState.limit` isn't recorded; this keeps the pill readable).
        public static let nameLimit = 32
    }

    /// Arc's theme picker (Arc ref §4.1, 1.171 measurements).
    public enum ThemePicker {
        public static let size = CGSize(width: 357, height: 509)
        public static let radius: CGFloat = 20
        public static let field: CGFloat = 340
        /// Popover offset from the sidebar edge and the window top (Space menu → Edit Theme Color…).
        public static let edgeOffset: CGFloat = 14
        public static let mainHandle: CGFloat = 44
        public static let handle: CGFloat = 26
        public static let handlePressed: (main: CGFloat, other: CGFloat) = (48, 28)
        public static let handleRing: CGFloat = 3
        public static let swatch: CGFloat = 24
        public static let grainDots = 24
        /// Sine periods on the intensity track.
        public static let wavePeriods = 7
        /// Second colour: complement; third: ±150° / 210° from the first.
        public static let secondHueOffset: Double = 180
        public static let thirdHueOffsets: (Double, Double) = (150, 210)
    }

    /// Hovering a closed folder (SB-34).
    public enum FolderPreview {
        public static let delay: Double = 0.45
        public static let width: CGFloat = 240
        /// Gap between the sidebar edge and the preview.
        public static let offset: CGFloat = 4
        public static let rowPitch: CGFloat = 45
        public static let maxRows = 8
        public static let searchHeight: CGFloat = 36
        public static let padding: CGFloat = 6
        public static let radius: CGFloat = 14
    }
}

extension AircMetrics.Library {
    /// The title (`title2`) sits below the traffic lights; it slides in from the left on `AircSpring.push`.
    public static let titleTop: CGFloat = 48
    /// Kept for source compatibility with early drafts: the header row's height.
    public static let headerHeight: CGFloat = 52
    /// Section tabs (Archive · Downloads · Spaces): 26 pt capsules, the current one on `selectedFill`.
    public static let tabHeight: CGFloat = 26
    /// The search field, `fieldFill`, radius 12 like the URL field.
    public static let searchHeight: CGFloat = 34
    /// Archived tab rows: favicon 18, title `row`, host + time `caption` tertiary.
    public static let rowHeight: CGFloat = 44
    /// Space rows: icon 20, name `row`, "Profile · 3 pinned · 5 today" `caption`.
    public static let spaceRowHeight: CGFloat = 48
    /// Day headers ("Today", "Yesterday", "Mon 2 Nov") in `caption` tertiary, 22 pt in.
    public static let dayHeaderInset: CGFloat = 22
    public static let sectionGap: CGFloat = 16
    public static let padding: CGFloat = 14
}

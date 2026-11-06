// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import CoreGraphics

/// The spacing scale, in points. A 4 pt grid with an 8 pt rhythm; Arc's 10 pt card inset is the one exception
/// and lives in `AircMetrics`.
public enum AircSpacing {
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
    public static let xxxl: CGFloat = 48
    public static let huge: CGFloat = 64
}

/// Arc's measured geometry (Arc 1.170/1.171, see docs/research/arc_behavior_spec.md). Match these exactly.
public enum AircMetrics {
    public enum Window {
        /// The page card's inset from the window edge and from the sidebar, on every side.
        public static let cardInset: CGFloat = 10
        /// Corner radius of the page card (circular, the page is clipped to it).
        public static let cardRadius: CGFloat = 6
        /// Traffic light centres; 23 pt pitch.
        public static let trafficLightCenters: [CGPoint] = [CGPoint(x: 20, y: 24), CGPoint(x: 43, y: 24), CGPoint(x: 66, y: 24)]
    }

    public enum Sidebar {
        public static let defaultWidth: CGFloat = 228
        public static let minWidth: CGFloat = 164
        public static let maxWidth: CGFloat = 500
        /// Side inset of rows, the URL field and Favorites.
        public static let inset: CGFloat = 8
        /// Centre of the header row (traffic lights at 24).
        public static let headerCenterY: CGFloat = 23.5
        /// Sidebar toggle, back, forward, reload hover plates.
        public static let headerButton: CGFloat = 32
        public static let headerButtonPitch: CGFloat = 34
        public static let headerButtonRadius: CGFloat = 6
        /// Sidebar toggle x (3 pt right of the zoom light).
        public static let toggleX: CGFloat = 77
        public static let urlFieldTop: CGFloat = 46
        public static let urlFieldHeight: CGFloat = 36
        public static let urlFieldButton: CGFloat = 30
        /// Hidden sidebar revealed over the page: inset from the window edge.
        public static let floatingInset: CGFloat = 5
        public static let floatingRadius: CGFloat = 12
        /// Pointer must stay within this many points of the floating sidebar's edge.
        public static let floatingKeepAlive: CGFloat = 22
    }

    public enum Favorites {
        public static let tileHeight: CGFloat = 47
        public static let gap: CGFloat = 8
        public static let radius: CGFloat = 10
        public static let maxColumns = 4
        public static let maxCount = 12
        public static let minTileWidth: CGFloat = 47
        public static let favicon: CGFloat = 20
        public static let unreadDot: CGFloat = 6
        /// Dot centre from the tile's bottom-right corner.
        public static let unreadDotOffset = CGPoint(x: 11, y: 10)

        /// Arc's column rule: the most columns (≤ 4) that keep tiles ≥ 47 pt wide, then the fewest columns
        /// that need no more rows. 5 → 3, 6 → 3, 7 → 4, 9 → 3.
        public static func columns(count: Int, width: CGFloat) -> Int {
            guard count > 0 else { return 0 }
            var maxCols = maxColumns
            while maxCols > 1, (width - gap * CGFloat(maxCols - 1)) / CGFloat(maxCols) < minTileWidth { maxCols -= 1 }
            maxCols = min(maxCols, count)
            let rows = Int((Double(count) / Double(maxCols)).rounded(.up))
            var cols = maxCols
            while cols > 1, Int((Double(count) / Double(cols - 1)).rounded(.up)) <= rows { cols -= 1 }
            return cols
        }
    }

    public enum Row {
        public static let pitch: CGFloat = 41
        public static let height: CGFloat = 40
        public static let plateHeight: CGFloat = 36
        public static let plateRadius: CGFloat = 12
        public static let faviconX: CGFloat = 17
        public static let favicon: CGFloat = 18
        public static let titleX: CGFloat = 43
        public static let titleTrailing: CGFloat = 17
        public static let closeButton: CGFloat = 26
        public static let closeButtonInset: CGFloat = 5
        public static let folderIndent: CGFloat = 16
        public static let spinner: CGFloat = 12
        /// Press feedback: the plate shrinks to this scale.
        public static let pressScale: CGFloat = 0.99
    }

    public enum SpaceHeader {
        public static let plateHeight: CGFloat = 36
        public static let iconFrame: CGFloat = 26
        public static let iconCenterX: CGFloat = 26
        public static let nameX: CGFloat = 41
        public static let nameXWithoutIcon: CGFloat = 18
        public static let moreButton: CGFloat = 24
        public static let moreButtonInset: CGFloat = 6
    }

    public enum Divider {
        public static let inset: CGFloat = 18
        /// The divider's centre sits this far above the first Today row's centre.
        public static let aboveFirstRow: CGFloat = 25
    }

    public enum Footer {
        public static let height: CGFloat = 50
        public static let button: CGFloat = 32
        public static let buttonInset: CGFloat = 8
        public static let spaceCell = CGSize(width: 36, height: 34)
        public static let spaceCellPitch: CGFloat = 34
        /// When squeezed, the current Space keeps at least this width.
        public static let spaceCellMinCurrent: CGFloat = 22
        public static let spaceEmoji: CGFloat = 16
        public static let spaceDot: CGFloat = 6
    }

    public enum CommandBar {
        public static let width: CGFloat = 765
        /// The bar's top sits this far above the window's vertical middle.
        public static let topAboveMiddle: CGFloat = 169
        public static let inputHeight: CGFloat = 64
        public static let rowHeight: CGFloat = 40
        public static let maxRows = 8
        public static let radius: CGFloat = 16
    }

    public enum Toast {
        public static let height: CGFloat = 36
        public static let topInset: CGFloat = 14
        /// Arc's "To exit full screen" toast stays up this long.
        public static let fullScreenDuration: Double = 4.8
        public static let defaultDuration: Double = 2.4
    }

    public enum Library {
        public static let width: CGFloat = 417
    }
}

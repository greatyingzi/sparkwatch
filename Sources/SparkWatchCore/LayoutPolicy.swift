import Foundation

/// How much of a fleet fits on each surface, computed rather than eyeballed.
///
/// Two machines is the case we run, but the app ships to people who may watch
/// five or fifty, so every layer needs an explicit capacity rule instead of a
/// layout tuned to a pair:
///
/// * the popover shows what fits **without squeezing** (that is the whole point
///   of the compact tier — a squeezed popover is what made text overlap);
/// * anything that does not fit is summarised in one overflow row and reachable
///   in the detail window;
/// * the detail window never hides a machine — it scrolls.
public enum LayoutPolicy {
    /// Cards side by side. A 400 pt popover holds two comfortably; a single
    /// machine gets the full width rather than a lonely half-empty card.
    public static func columns(nodeCount: Int, popoverWidth: Double) -> Int {
        guard nodeCount > 1 else { return 1 }
        if popoverWidth >= 560, nodeCount > 4 { return 3 }
        if popoverWidth >= 380 { return 2 }
        return 1
    }

    /// Rows of cards that fit in the height left over after the chrome.
    public static func rows(heightBudget: Double, cardHeight: Double, spacing: Double) -> Int {
        guard cardHeight > 0, heightBudget > 0 else { return 0 }
        let usable = heightBudget + spacing
        let stride = cardHeight + spacing
        return max(0, Int(usable / stride))
    }

    /// Cards the popover can show in full. Never more than exist, never fewer
    /// than one column's worth when there is any room at all.
    public static func visibleCards(
        nodeCount: Int,
        popoverWidth: Double,
        heightBudget: Double,
        cardHeight: Double,
        spacing: Double
    ) -> Int {
        guard nodeCount > 0 else { return 0 }
        let columns = columns(nodeCount: nodeCount, popoverWidth: popoverWidth)
        let rows = max(1, rows(heightBudget: heightBudget, cardHeight: cardHeight, spacing: spacing))
        return min(nodeCount, columns * rows)
    }

    // MARK: - Detail window (full tier)

    /// How the detail window arranges its columns.
    ///
    /// The rules, in the order people notice them:
    ///
    /// 1. **Equal widths.** Comparing two machines only works if the columns are
    ///    the same width, so every column gets one shared value.
    /// 2. **Centred as a group.** A left-hugging group with dead space on the
    ///    right reads as broken — that is what "off centre" was. One machine is
    ///    centred, a pair fills the width, a fleet that overflows scrolls as a
    ///    centred group.
    /// 3. **Bounded.** Columns have a minimum (below it the rich card's inner
    ///    grid gets cramped) and a maximum (a 1000 pt-wide card is a stretched
    ///    line of text, not a dashboard). A lone machine may be wider than one
    ///    column of several, since there is no comparison to keep fair.
    public struct DetailLayout: Equatable {
        public var columns: Int
        public var columnWidth: Double
        /// Everything drawn plus the gaps between columns.
        public var groupWidth: Double
        /// Machines that exist but do not fit side by side (they scroll).
        public var overflow: Int

        public init(columns: Int, columnWidth: Double, groupWidth: Double, overflow: Int) {
            self.columns = columns
            self.columnWidth = columnWidth
            self.groupWidth = groupWidth
            self.overflow = overflow
        }
    }

    public static func detailLayout(
        nodeCount: Int,
        contentWidth: Double,
        spacing: Double = 12,
        columnMin: Double = 380,
        columnMax: Double = 560,
        singleColumnMax: Double = 760
    ) -> DetailLayout {
        guard nodeCount > 0, contentWidth > 0 else {
            return DetailLayout(columns: 0, columnWidth: 0, groupWidth: 0, overflow: 0)
        }

        // How many equal columns fit at the minimum comfortable width.
        let fit = Int((contentWidth + spacing) / (columnMin + spacing))
        let columns = max(1, min(nodeCount, fit))

        // Fill the width, then clamp: never below the minimum (cramped, and the
        // card's grid starts wrapping) and never above the maximum (stretched).
        let filled = (contentWidth - spacing * Double(columns - 1)) / Double(columns)
        let ceiling = columns == 1 ? singleColumnMax : columnMax
        let width = min(ceiling, max(columnMin, filled))

        return DetailLayout(
            columns: columns,
            columnWidth: width,
            groupWidth: width * Double(columns) + spacing * Double(columns - 1),
            overflow: max(0, nodeCount - columns)
        )
    }
}

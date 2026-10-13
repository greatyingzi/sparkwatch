import Foundation
import Testing
@testable import SparkWatchCore

@Suite("布局容量策略 (N 台设备)")
struct LayoutPolicyTests {
    @Test func pairsGetTwoColumns() {
        #expect(LayoutPolicy.columns(nodeCount: 2, popoverWidth: 400) == 2)
        #expect(LayoutPolicy.columns(nodeCount: 3, popoverWidth: 400) == 2)
        #expect(LayoutPolicy.columns(nodeCount: 1, popoverWidth: 400) == 1)
    }

    /// A narrow surface falls back to one column rather than two unusable ones.
    @Test func narrowPopoverFallsBackToOneColumn() {
        #expect(LayoutPolicy.columns(nodeCount: 6, popoverWidth: 320) == 1)
    }

    @Test func widePopoverWithManyNodesGetsThreeColumns() {
        #expect(LayoutPolicy.columns(nodeCount: 6, popoverWidth: 640) == 3)
        // …but not for a pair, where a third column would be empty space.
        #expect(LayoutPolicy.columns(nodeCount: 2, popoverWidth: 640) == 2)
    }

    @Test func rowsFitWithoutSqueezing() {
        // 150 pt cards, 9 pt gaps, 470 pt of room: three rows.
        #expect(LayoutPolicy.rows(heightBudget: 470, cardHeight: 150, spacing: 9) == 3)
        // Not enough for even one row.
        #expect(LayoutPolicy.rows(heightBudget: 0, cardHeight: 150, spacing: 9) == 0)
        // Exactly one row.
        #expect(LayoutPolicy.rows(heightBudget: 150, cardHeight: 150, spacing: 9) == 1)
    }

    /// The rule that matters when someone points this at a fleet: show what fits,
    /// never squeeze, never claim to show more than exists.
    @Test func visibleCardsCapsAtWhatFits() {
        // Two machines always fit: one row, two columns.
        #expect(LayoutPolicy.visibleCards(
            nodeCount: 2, popoverWidth: 400, heightBudget: 310, cardHeight: 150, spacing: 9
        ) == 2)
        // Eight machines, room for two rows of two: four shown, four overflow.
        let shown = LayoutPolicy.visibleCards(
            nodeCount: 8, popoverWidth: 400, heightBudget: 310, cardHeight: 150, spacing: 9
        )
        #expect(shown == 4)
        // Twelve machines with lots of room: all of them.
        #expect(LayoutPolicy.visibleCards(
            nodeCount: 12, popoverWidth: 700, heightBudget: 700, cardHeight: 150, spacing: 9
        ) == 12)
        // No machines, nothing to show.
        #expect(LayoutPolicy.visibleCards(
            nodeCount: 0, popoverWidth: 400, heightBudget: 310, cardHeight: 150, spacing: 9
        ) == 0)
        // A tiny budget still shows one row rather than nothing (the user must
        // never be left staring at an empty popover).
        #expect(LayoutPolicy.visibleCards(
            nodeCount: 5, popoverWidth: 400, heightBudget: 20, cardHeight: 150, spacing: 9
        ) == 2)
    }

    // MARK: - Detail window

    /// Two machines fill the window: equal widths, gaps kept, no dead space.
    @Test func aPairFillsTheWindow() {
        let layout = LayoutPolicy.detailLayout(nodeCount: 2, contentWidth: 1152)
        #expect(layout.columns == 2)
        // (1152 - 12) / 2 = 570, clamped to the 560 maximum.
        #expect(layout.columnWidth == 560)
        #expect(layout.groupWidth == 1132)          // 2 x 560 + 12
        #expect(layout.overflow == 0)
    }

    /// One machine gets a wider column than a pair's, because nothing has to
    /// line up next to it — but still bounded, so it does not stretch.
    @Test func aSingleMachineIsWiderButBounded() {
        let wide = LayoutPolicy.detailLayout(nodeCount: 1, contentWidth: 1152)
        #expect(wide.columns == 1)
        #expect(wide.columnWidth == 760)            // the single-column ceiling
        #expect(wide.groupWidth == 760)

        // A narrow window is the floor, not a squeezed card.
        let narrow = LayoutPolicy.detailLayout(nodeCount: 1, contentWidth: 300)
        #expect(narrow.columnWidth == 380)          // the minimum comfortable width
    }

    /// A fleet shows as many equal columns as fit comfortably, and reports the
    /// rest as overflow (which scrolls) instead of shrinking them.
    @Test func aFleetOverflowsInsteadOfShrinking() {
        let layout = LayoutPolicy.detailLayout(nodeCount: 8, contentWidth: 1152)
        #expect(layout.columns == 2)                // floor((1152+12) / 392)
        #expect(layout.columnWidth == 560)
        #expect(layout.overflow == 6)

        // A very wide window fits more of them side by side.
        let wide = LayoutPolicy.detailLayout(nodeCount: 8, contentWidth: 2400)
        #expect(wide.columns == 6)
        #expect(wide.overflow == 2)
    }

    /// The group is centred, so the window's leftover space is split evenly.
    @Test func theGroupLeavesSymmetricMargins() {
        let layout = LayoutPolicy.detailLayout(nodeCount: 2, contentWidth: 1152)
        let slack = 1152 - layout.groupWidth
        #expect(slack == 20)
        #expect(slack / 2 == 10)                    // 10 pt on each side, not 168 on one
    }

    @Test func detailLayoutHandlesDegenerateInput() {
        #expect(LayoutPolicy.detailLayout(nodeCount: 0, contentWidth: 900).columns == 0)
        #expect(LayoutPolicy.detailLayout(nodeCount: 3, contentWidth: 0).columns == 0)
        // Never zero columns while machines exist.
        #expect(LayoutPolicy.detailLayout(nodeCount: 3, contentWidth: 200).columns == 1)
    }
}

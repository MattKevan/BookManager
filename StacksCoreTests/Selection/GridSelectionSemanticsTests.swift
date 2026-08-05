import Foundation
import Testing
@testable import StacksCore

@Suite
struct GridSelectionSemanticsTests {
    private let a = UUID()
    private let b = UUID()
    private let c = UUID()
    private let d = UUID()
    private var visible: [UUID] { [a, b, c, d] }

    @Test
    func plainClickReplacesSelectionAndSetsAnchor() {
        let result = GridSelectionSemantics.applying(
            click: b, modifier: .none, anchor: a, visible: visible, selection: [a, c]
        )
        #expect(result.selection == [b])
        #expect(result.anchor == b)
    }

    @Test
    func commandClickTogglesAndKeepsAnchor() {
        let added = GridSelectionSemantics.applying(
            click: c, modifier: .command, anchor: a, visible: visible, selection: [a]
        )
        #expect(added.selection == [a, c])
        #expect(added.anchor == nil) // unchanged

        let removed = GridSelectionSemantics.applying(
            click: c, modifier: .command, anchor: a, visible: visible, selection: [a, c]
        )
        #expect(removed.selection == [a])
        #expect(removed.anchor == nil)
    }

    @Test
    func shiftClickSelectsRangeForwardAndBackward() {
        let forward = GridSelectionSemantics.applying(
            click: d, modifier: .shift, anchor: b, visible: visible, selection: [a]
        )
        #expect(forward.selection == [b, c, d])
        #expect(forward.anchor == nil)

        let backward = GridSelectionSemantics.applying(
            click: a, modifier: .shift, anchor: c, visible: visible, selection: [d]
        )
        #expect(backward.selection == [a, b, c])
        #expect(backward.anchor == nil)
    }

    @Test
    func shiftClickWithoutAnchorFallsBackToPlainClick() {
        let result = GridSelectionSemantics.applying(
            click: c, modifier: .shift, anchor: nil, visible: visible, selection: [a]
        )
        #expect(result.selection == [c])
        #expect(result.anchor == c)
    }

    @Test
    func shiftClickWithClickMissingFromVisibleFallsBack() {
        let ghost = UUID()
        let result = GridSelectionSemantics.applying(
            click: ghost, modifier: .shift, anchor: a, visible: visible, selection: []
        )
        #expect(result.selection == [ghost])
        #expect(result.anchor == ghost)
    }

    @Test
    func intersectingMatchesEnclosedFrames() {
        let frames: [UUID: CGRect] = [
            a: CGRect(x: 0, y: 0, width: 100, height: 100),
            b: CGRect(x: 200, y: 0, width: 100, height: 100),
            c: CGRect(x: 0, y: 200, width: 100, height: 100),
        ]
        #expect(GridSelectionSemantics.intersecting(
            frames, rect: CGRect(x: 50, y: 50, width: 200, height: 100)
        ) == [a, b])
        #expect(GridSelectionSemantics.intersecting(
            frames, rect: CGRect(x: 0, y: 0, width: 0, height: 0)
        ).isEmpty)
        #expect(GridSelectionSemantics.intersecting(
            [:], rect: CGRect(x: 0, y: 0, width: 10, height: 10)
        ).isEmpty)
    }
}

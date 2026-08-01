# Grid Multi-Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the cover-grid selection bug (plain click accumulates instead of replacing) and adopt macOS-native multi-select semantics: click replaces, ⌘-click toggles, ⇧-click selects the anchor→clicked range, empty-space click clears, and drag-marquee selects enclosed tiles (⌘-drag adds). The table view keeps its native `Table(selection:)` behavior.

**Architecture:** Selection rules live in a pure, Core-tested helper `GridSelectionSemantics` (precedent: `CalibreRawPresenter`). The session owns the selection *anchor* (it already owns `selection`; `CoverTile` is a child view, so a session method keeps the anchor reachable — deviation from the spec's "grid-local @State", noted in Self-Review; the table ignores the anchor). The grid view stays thin: tile taps call a session method that reads `NSEvent.modifierFlags` and applies the semantics; the marquee uses a `DragGesture` + a `PreferenceKey` frame map + a `named` coordinate space + a non-interactive rect overlay.

**Tech Stack:** Swift 6.0 (strict concurrency), SwiftUI, AppKit (`NSEvent.modifierFlags`), Swift Testing, XcodeGen.

## Global Constraints

- macOS 26 deployment target; Swift 6.0 with `SWIFT_STRICT_CONCURRENCY: complete`; `LibrarySession` is `@MainActor @Observable` (imports AppKit already).
- **No Automerge/catalog changes.** Selection is view-interaction state only.
- Existing tests keep passing: core suite is 98 tests in 16 suites (Plans 1–2 merged). The table view and its native selection are untouched.
- The grid has no drag-and-drop; the marquee may start anywhere (including over tiles).
- UI-test automation is environmental in this session (headless); grid behavior is verified by build + manual run (residual for the human).
- Tests: Swift Testing; xcodebuild with `-derivedDataPath .build/DerivedData`; run `xcodegen generate --spec project.yml` before building new files; suite-level `-only-testing` (single-test identifiers are unreliable).

---

### Task 1: Core `GridSelectionSemantics` (pure, tested)

**Files:**
- Create: `BookManagerCore/Selection/GridSelectionSemantics.swift`
- Create: `BookManagerCoreTests/Selection/GridSelectionSemanticsTests.swift`

**Interfaces:**
- Consumes: Foundation only.
- Produces: `GridSelectionModifier` (`.none/.command/.shift`, `Sendable`), `GridSelectionSemantics.applying(click:modifier:anchor:visible:selection:) -> (selection: Set<UUID>, anchor: UUID?)` (nil anchor return = "leave unchanged"), `GridSelectionSemantics.intersecting(_ frames: [UUID: CGRect], rect: CGRect) -> Set<UUID>`.

- [ ] **Step 1: Write the failing tests**

Create `BookManagerCoreTests/Selection/GridSelectionSemanticsTests.swift`:

```swift
import Foundation
import Testing
@testable import BookManagerCore

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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -derivedDataPath .build/DerivedData test -only-testing:BookManagerCoreTests/GridSelectionSemanticsTests` (run `xcodegen generate --spec project.yml` first — new files).
Expected: FAIL — `GridSelectionSemantics` has no member.

- [ ] **Step 3: Implement the helper**

Create `BookManagerCore/Selection/GridSelectionSemantics.swift`:

```swift
import Foundation

public enum GridSelectionModifier: Sendable {
    case none, command, shift
}

/// Pure selection-set semantics matching macOS conventions (HIG: click
/// replaces, ⌘-click toggles, ⇧-click selects the anchor→clicked range,
/// marquee replaces or unions). Tested in isolation; the grid view stays thin.
public enum GridSelectionSemantics {
    /// Applies a click to `selection`. Returns the new selection and the new
    /// anchor; a returned anchor of `nil` means "leave the anchor unchanged".
    public static func applying(
        click: UUID,
        modifier: GridSelectionModifier,
        anchor: UUID?,
        visible: [UUID],
        selection: Set<UUID>
    ) -> (selection: Set<UUID>, anchor: UUID?) {
        switch modifier {
        case .none:
            return ([click], click)
        case .command:
            var next = selection
            if next.contains(click) {
                next.remove(click)
            } else {
                next.insert(click)
            }
            return (next, nil)
        case .shift:
            guard let anchor,
                  let anchorIndex = visible.firstIndex(of: anchor),
                  let clickIndex = visible.firstIndex(of: click) else {
                return ([click], click)
            }
            let lower = min(anchorIndex, clickIndex)
            let upper = max(anchorIndex, clickIndex)
            return (Set(visible[lower...upper]), nil)
        }
    }

    /// The tile ids whose frames intersect `rect` (marquee selection).
    public static func intersecting(_ frames: [UUID: CGRect], rect: CGRect) -> Set<UUID> {
        Set(frames.compactMap { id, frame in
            frame.intersects(rect) ? id : nil
        })
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass, then the full core suite**

Run the focused suite, then `-only-testing:BookManagerCoreTests`. Expected: focused passes; full suite 98 + 6 = 104 tests, 16 suites, green.

- [ ] **Step 5: Commit**

```bash
git add BookManagerCore/Selection/GridSelectionSemantics.swift BookManagerCoreTests/Selection/GridSelectionSemanticsTests.swift
git commit -m "feat: add pure GridSelectionSemantics (replace/toggle/range/marquee)"
```

---

### Task 2: Grid selection wiring + marquee

**Files:**
- Modify: `BookManager/Stores/LibrarySession.swift` (`selectionAnchor`, `selectInGrid(_:)`, `clearGridSelection()`, `closeLibrary` reset)
- Modify: `BookManager/Views/CoverGridView.swift` (marquee: preference key, drag gesture, overlay, background clear; tile tap handler)
- (No test-file changes — app-layer UI; verification is build + manual.)

**Interfaces:**
- Consumes: `GridSelectionSemantics` (Task 1), `session.selection`, `session.books`, `NSEvent.modifierFlags` (AppKit, macOS).
- Produces: `LibrarySession.selectionAnchor: UUID?` (private(set)), `func selectInGrid(_ book: IndexedBook)`, `func clearGridSelection()`, and the marquee state inside `CoverGridView`.

- [ ] **Step 1: Session selection API**

In `BookManager/Stores/LibrarySession.swift` add next to `var selection = Set<UUID>()`:

```swift
    /// The anchor for ⇧-click range selection in the grid. Ignored by the
    /// table view (which manages its own selection semantics natively).
    private(set) var selectionAnchor: UUID?
```

Add (near the selection helpers):

```swift
    /// macOS grid-click semantics: plain click replaces, ⌘ toggles, ⇧ selects
    /// the anchor→clicked range. Reads the modifier flags at gesture time.
    func selectInGrid(_ book: IndexedBook) {
        let flags = NSEvent.modifierFlags
        let modifier: GridSelectionModifier = flags.contains(.command)
            ? .command
            : (flags.contains(.shift) ? .shift : .none)
        let result = GridSelectionSemantics.applying(
            click: book.id,
            modifier: modifier,
            anchor: selectionAnchor,
            visible: books.map(\.id),
            selection: selection
        )
        selection = result.selection
        if let anchor = result.anchor {
            selectionAnchor = anchor
        }
    }

    /// Empty-space click: clear the selection and the range anchor.
    func clearGridSelection() {
        selection = []
        selectionAnchor = nil
    }
```

In `closeLibrary()`, add `selectionAnchor = nil` next to `selection = []`.

- [ ] **Step 2: Tile tap + marquee in the grid**

In `BookManager/Views/CoverGridView.swift`:
- Replace the `CoverTile` tap handler: `onTapGesture { toggleSelection() }` becomes `onTapGesture { session?.selectInGrid(book) }` (remove `toggleSelection()`; keep the double-tap open and hover).
- Add the frame preference key at file scope:

```swift
private struct CoverTileFrameKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
```
- In `CoverGridView`, add state: `@State private var marqueeStart: CGPoint?`, `@State private var marqueeCurrent: CGPoint?`, `@State private var tileFrames: [UUID: CGRect] = [:]`.
- Each `CoverTile` gets a frame reporter (attach after the `.environment` line):

```swift
.background {
    GeometryReader { geo in
        Color.clear.preference(
            key: CoverTileFrameKey.self,
            value: [book.id: geo.frame(in: .named("coverGrid"))]
        )
    }
}
```
- On the `ScrollView`:

```swift
.coordinateSpace(name: "coverGrid")
.background {
    Color.clear
        .contentShape(Rectangle())
        .onTapGesture { session.clearGridSelection() }
}
.simultaneousGesture(marqueeDrag)
.onPreferenceChange(CoverTileFrameKey.self) { tileFrames = $0 }
.overlay { marqueeOverlay }
```
(Keep the existing empty-library `ContentUnavailableView` overlay — combine into one `overlay` block with a `Group` if needed.)

- Add the gesture and overlay helpers:

```swift
private var marqueeDrag: some Gesture {
    DragGesture(minimumDistance: 3, coordinateSpace: .named("coverGrid"))
        .onChanged { value in
            if marqueeStart == nil { marqueeStart = value.startLocation }
            marqueeCurrent = value.location
            let rect = marqueeRect(start: value.startLocation, current: value.location)
            let hit = GridSelectionSemantics.intersecting(tileFrames, rect: rect)
            let add = NSEvent.modifierFlags.contains(.command)
            session.selection = add ? session.selection.union(hit) : hit
        }
        .onEnded { _ in
            marqueeStart = nil
            marqueeCurrent = nil
        }
}

private func marqueeRect(start: CGPoint, current: CGPoint) -> CGRect {
    CGRect(
        x: min(start.x, current.x), y: min(start.y, current.y),
        width: abs(current.x - start.x), height: abs(current.y - start.y)
    )
}

@ViewBuilder
private var marqueeOverlay: some View {
    if let start = marqueeStart, let current = marqueeCurrent {
        Rectangle()
            .fill(Color.accentColor.opacity(0.15))
            .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1))
            .frame(width: abs(current.x - start.x), height: abs(current.y - start.y))
            .position(x: (start.x + current.x) / 2, y: (start.y + current.y) / 2)
            .allowsHitTesting(false)
    }
}
```

- [ ] **Step 3: Build and verify wiring**

Run: `xcodegen generate --spec project.yml` (no new files — skip if unchanged), then `xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -derivedDataPath .build/DerivedData build`.
Expected: BUILD SUCCEEDED.
Then run the full core suite: `... test -only-testing:BookManagerCoreTests` → 104 tests green (no app-target change regressed Core).
Manual GUI verification (click replaces, ⌘ toggles, ⇧ ranges, empty-space clears, marquee selects, ⌘-marquee adds, double-click opens, table selection unchanged) is a residual for the human — note it in the report.

- [ ] **Step 4: Commit**

```bash
git add BookManager/Stores/LibrarySession.swift BookManager/Views/CoverGridView.swift
git commit -m "feat: macOS grid multi-selection — replace, toggle, range, marquee"
```

---

## Self-Review

- **Spec coverage:** Req 1 (click replaces + anchor) → Task 1 `.none` + Task 2 `selectInGrid`. Req 2 (⌘ toggle, anchor unchanged) → Task 1 `.command` + Task 2. Req 3 (⇧ range, no-anchor fallback) → Task 1 `.shift` + Task 2. Req 4 (empty-space clears) → Task 2 `clearGridSelection`. Req 5 (marquee, ⌘-drag adds) → Task 2 gesture + `intersecting`. Req 6 (table untouched) → no `BookTableView` change. Req 7 (pure tested helper) → Task 1.
- **Placeholder scan:** no TBDs; every step has concrete code or an exact command.
- **Type consistency:** `GridSelectionModifier`/`GridSelectionSemantics.applying`/`intersecting` defined in Task 1, consumed in Task 2 with matching names; `selectionAnchor`/`selectInGrid`/`clearGridSelection` defined in Task 2 Step 1, used in Step 2. No name drift.
- **Deviation (spec → plan):** the spec placed the anchor as grid-local `@State`; the plan puts `selectionAnchor` on the session because `CoverTile` is a child view (the tap handler lives there) and the session already owns `selection`. The table ignores the anchor. Rationale documented in the session property's doc comment.
- **Risk noted:** `NSEvent.modifierFlags` read inside gesture/tap closures is the standard macOS SwiftUI approach; the marquee overlay uses `.allowsHitTesting(false)` so it never blocks tile taps; the background clear-tap sits below the tiles so tile taps never reach it.

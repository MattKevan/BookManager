# Grid Multi-Selection — Design

> **Status:** Approved 2026-08-01. Fixes the cover-grid selection bug and adopts macOS-native multi-select semantics (research basis: Apple HIG "Selection Methods" and current "Selection and input" guidance; SwiftUI community marquee patterns for `LazyVGrid`, which has no built-in selection).
> **Goal:** in the cover grid, a plain click **replaces** the selection (today it toggles/accumulates); ⌘-click toggles; ⇧-click selects the contiguous range from the anchor; clicking empty space clears; and drag-marquee selects the tiles the rectangle encloses (⌘-drag adds).

## Requirements

1. Plain click on a tile: `selection = [book.id]`; the anchor becomes that book.
2. ⌘-click: toggle `book.id` in/out of the selection; the anchor is unchanged.
3. ⇧-click: select the contiguous range in display order (`session.books`) between the anchor and the clicked book, replacing the selection; the anchor is unchanged. No anchor → behaves like a plain click.
4. Click on empty space: clear the selection and the anchor.
5. Drag-marquee: a drag (≥ 3 pt) draws a live rectangle; on the way, the selection shows the tiles whose frames intersect the rectangle; on release the selection is the intersecting set (plain drag replaces; ⌘-drag unions with the existing selection). The marquee may start anywhere — Book Manager has no drag-and-drop of books.
6. The table view is untouched — SwiftUI `Table(selection:)` already implements these semantics natively.
7. Selection rules live in a pure, Core-tested helper (precedent: `CalibreRawPresenter`); the view stays thin.

## Architecture

### Core (BookManagerCore, pure + tested)

New `BookManagerCore/Selection/GridSelectionSemantics.swift`:

```swift
public enum GridSelectionModifier: Sendable {
    case none, command, shift
}

public enum GridSelectionSemantics {
    /// Applies a click to the current selection per macOS semantics.
    /// Returns the new selection and the new anchor (nil means "unchanged").
    public static func applying(
        click: UUID,
        modifier: GridSelectionModifier,
        anchor: UUID?,
        visible: [UUID],
        selection: Set<UUID>
    ) -> (selection: Set<UUID>, anchor: UUID?)
}
```

Rules:

- `.none`: `([click], click)`.
- `.command`: `(toggle(click, in: selection), nil)`.
- `.shift`: if `anchor` exists and both `anchor` and `click` appear in `visible`, `(Set(visible[minIndex...maxIndex]), nil)`; otherwise `([click], click)`.
- `nil` anchor return means "leave the current anchor as-is".

Also a small `intersecting(_ frames: [UUID: CGRect], rect: CGRect) -> Set<UUID>` helper for the marquee (pure rect math, tested).

### Grid (BookManager app)

`CoverGridView.swift` / `CoverTile`:

- **Tile tap:** replace `toggleSelection()` with `handleTap(book)` reading `NSEvent.modifierFlags` (⌘/⇧), calling `GridSelectionSemantics.applying(...)` with the grid's `@State selectionAnchor: UUID?`, then applying the result to `session.selection` + anchor. Double-tap still opens the book.
- **Marquee:**
  - `@State marqueeStart: CGPoint?`, `@State marqueeCurrent: CGPoint?`, `@State frames: [UUID: CGRect]`.
  - `.coordinateSpace(name: "coverGrid")` on the `ScrollView`; each tile reports its frame via a `PreferenceKey` (`CoverTileFrameKey: PreferenceKey`, `Value = [UUID: CGRect]`, collected with `.onPreferenceChange`).
  - `DragGesture(minimumDistance: 3)` via `.simultaneousGesture` on the `ScrollView`; `startLocation`/`location` in the named space update the rect; on `onChanged`, live-compute `GridSelectionSemantics.intersecting(frames, rect)` and set `session.selection` (replace, or union when ⌘ was held at drag start); `onEnded` clears the marquee state.
  - Marquee rect overlay: `Rectangle().stroke(...)` + translucent fill, `.allowsHitTesting(false)`, positioned from `min(start, current)` with `abs` size.
  - Background layer (`Color.clear.contentShape(Rectangle())`) with `.onTapGesture` clearing the selection + anchor.
- `closeLibrary`/state resets: the grid's `@State` dies with the view; no session change needed (selection already resets in `closeLibrary`).

## Data flow

`NSEvent.modifierFlags` at gesture time → `GridSelectionSemantics.applying` (pure) → `session.selection` mutation → existing browser/selection observers (inspector auto-show, toolbar buttons, tile highlight) react as today. Marquee: tile frames (PreferenceKey) + drag rect → `intersecting` → same `session.selection` mutation.

## Testing

- **Core** (`GridSelectionSemanticsTests`): replace, toggle, shift-range both directions, shift with no anchor, anchor preservation on ⌘/⇧, anchor update on plain click, empty-`visible` edge, `intersecting` rect math (overlap, partial overlap, disjoint, zero-size rect).
- **App**: build + manual GUI verification (plain click replaces, ⌘ toggles, ⇧ ranges, empty-space clears, marquee selects, ⌘-marquee adds, double-click still opens, table selection unchanged). Headless-session caveat as before.

## Out of scope

- Drag-and-drop of books (no such feature).
- Context-menu-on-right-click selection in the grid (the grid has no context menu; noted as a future HIG-consistency item).
- Any change to `Table` selection behavior.

## Acceptance criteria

- [ ] Plain-clicking book B after book A selects only B (bug fixed).
- [ ] ⌘-click toggles; ⇧-click selects the anchor→clicked range; clicking empty space clears.
- [ ] Drag-marquee selects the enclosed tiles; ⌘-drag adds to the selection.
- [ ] Double-click still opens; the table's native selection is unchanged.
- [ ] Core suite green (98 + new semantics tests); no Automerge/catalog changes.

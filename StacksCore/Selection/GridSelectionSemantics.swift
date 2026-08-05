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

    /// The tile ids whose frames intersect `rect` (marquee selection). A
    /// degenerate (zero-area) rect selects nothing — a click without a drag
    /// must not select via the marquee.
    public static func intersecting(_ frames: [UUID: CGRect], rect: CGRect) -> Set<UUID> {
        guard rect.width > 0, rect.height > 0 else { return [] }
        return Set(frames.compactMap { id, frame in
            frame.intersects(rect) ? id : nil
        })
    }
}

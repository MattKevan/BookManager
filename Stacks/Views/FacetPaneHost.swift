import StacksCore
import SwiftUI

/// The resizable facet pane: the facet values list + a drag divider + the book
/// browser content. Owns the pane width locally so a drag tick re-renders only
/// this subtree, and defers the UserDefaults write to the END of the drag.
///
/// Reflow policy (Photos-style): while dragging, the facet list resizes live
/// (cheap — lists don't reflow) but the grid content HOLDS its pre-drag layout
/// at the trailing edge (via the Spacer). SwiftUI's `LazyVGrid` cannot animate
/// a continuous reflow, so re-flowing every tick is what read as popping/flicker
/// between rows. On release the content fills the new width in ONE reflow, which
/// `CoverGridView`'s `.animation(value: geo.size.width)` glides like Photos.
/// Width is clamped to 180...420 so the pane never exceeds half the window.
struct FacetPaneHost<Content: View>: View {
    let library: LibraryConnection
    @ViewBuilder let content: () -> Content

    private static var defaultWidth: Double { 240 }
    private static var minWidth: Double { 180 }
    private static var maxWidth: Double { 420 }

    /// The live pane width (facet list) while dragging; equal to the committed
    /// width otherwise.
    @State private var paneWidth: Double
    /// The pane width when the current drag started — the grid keeps the layout
    /// for this width for the whole drag.
    @State private var dragStart: Double?

    init(library: LibraryConnection, @ViewBuilder content: @escaping () -> Content) {
        self.library = library
        self.content = content
        let stored = UserDefaults.standard.object(forKey: "facetPaneWidth") as? Double
            ?? Self.defaultWidth
        _paneWidth = State(initialValue: min(max(stored, Self.minWidth), Self.maxWidth))
    }

    var body: some View {
        GeometryReader { outer in
            HStack(spacing: 0) {
                FacetListView(browser: library)
                    .frame(width: paneWidth)
                // Draggable divider: HSplitView's native divider was unreliable
                // inside the split view's detail column (not draggable, 50/50
                // default), so the pane width is state driven by a drag gesture
                // on this handle. `dragStart` captures the width at the gesture's
                // start (translation is measured from the start, not incrementally).
                Rectangle()
                    .fill(.separator)
                    .frame(width: 6)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                if dragStart == nil { dragStart = paneWidth }
                                let start = dragStart ?? paneWidth
                                paneWidth = min(
                                    max(start + Double(value.translation.width), Self.minWidth),
                                    Self.maxWidth
                                )
                            }
                            .onEnded { _ in
                                dragStart = nil
                                UserDefaults.standard.set(paneWidth, forKey: "facetPaneWidth")
                            }
                    )
                if let start = dragStart {
                    // Dragging: the grid keeps its pre-drag layout (fixed
                    // width, right-aligned; the Spacer absorbs the divider
                    // travel) so it never re-flows mid-drag. It snaps to the
                    // new width once on release.
                    Spacer(minLength: 0)
                    content()
                        .frame(width: outer.size.width - start - 6)
                } else {
                    content()
                }
            }
        }
    }
}

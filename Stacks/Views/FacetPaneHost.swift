import StacksCore
import SwiftUI

/// The resizable facet pane: the facet values list + a drag divider + the book
/// browser content. Owns the pane width locally so a drag tick re-renders only
/// this subtree (not the whole detail column — which also recomputed the window
/// title and toolbar builders every tick), and defers the UserDefaults write to
/// the END of the drag (per-tick persistence was disk I/O per frame and caused
/// visible flicker). Width is clamped to 180...420 so the pane never exceeds
/// half the window.
struct FacetPaneHost<Content: View>: View {
    let library: LibraryConnection
    @ViewBuilder let content: () -> Content

    private static var defaultWidth: Double { 240 }
    private static var minWidth: Double { 180 }
    private static var maxWidth: Double { 420 }

    @State private var paneWidth: Double
    @State private var dragStart: Double?

    init(library: LibraryConnection, @ViewBuilder content: @escaping () -> Content) {
        self.library = library
        self.content = content
        let stored = UserDefaults.standard.object(forKey: "facetPaneWidth") as? Double
            ?? Self.defaultWidth
        _paneWidth = State(initialValue: min(max(stored, Self.minWidth), Self.maxWidth))
    }

    var body: some View {
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
                            let start = dragStart ?? paneWidth
                            dragStart = start
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
            content()
        }
    }
}

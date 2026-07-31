import SwiftUI

/// Placeholder — real cover grid arrives in Task 7.
struct CoverGridView: View {
    let session: LibrarySession

    var body: some View {
        ContentUnavailableView(
            "Cover Grid",
            systemImage: "square.grid.2x2",
            description: Text("Cover browsing arrives in the next delivery slice.")
        )
    }
}

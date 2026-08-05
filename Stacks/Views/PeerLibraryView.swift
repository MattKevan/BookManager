import StacksCore
import SwiftUI

/// Browser for an open peer library: the shared grid/table views driven by
/// the peer's connection. The per-book context menus (Reveal / Delete) live
/// in the shared views; this wrapper adds the peer-only Copy-to-Home
/// affordance on empty-space right-click (the toolbar button in ContentView
/// is the primary path). Task 6 wires the copy to the real transfer.
struct PeerLibraryView: View {
    let peer: LibraryConnection
    var copyToHome: () -> Void = {}

    var body: some View {
        Group {
            switch peer.viewMode {
            case .table:
                BookTableView(browser: peer)
            case .grid:
                CoverGridView(browser: peer)
            }
        }
        .contextMenu {
            Button("Copy to Home Library") { copyToHome() }
                .disabled(peer.selection.isEmpty)
        }
    }
}

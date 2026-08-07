import AppKit
import StacksCore
import SwiftUI

extension LibraryConnection: Identifiable {}

/// The sidebar's Libraries section: every open peer library as a disclosure
/// group expanding to its All Books + facet sub-sections. Home keeps its own
/// always-expanded Library section (SidebarView); peers are grouped here so
/// the home/peer split stays visible. The header row carries per-peer status,
/// a Close button, a Make Home / Show in Finder / Close context menu, and
/// file drag-drop (raw book files import into that peer — wired in Task 6).
struct LibraryPeersSection: View {
    @Bindable var session: LibrarySession
    @State private var expandedPeers: Set<UUID> = []

    /// The facet categories offered in each peer's sub-section, in order.
    private var libraryCategories: [FacetType] { [.author, .series, .tag, .format] }

    var body: some View {
        Section("Libraries") {
            // The home library never appears here — it owns the Library
            // section. Filter by id as a hard guarantee: a duplicate
            // connection for the home library would otherwise render a second
            // row for it.
            ForEach(session.peers.filter { $0.id != session.home?.id }) { peer in
                DisclosureGroup(isExpanded: expandedBinding(for: peer)) {
                    // The header itself opens All Books; the group expands to
                    // just the facet categories.
                    ForEach(libraryCategories, id: \.self) { category in
                        Label(category.displayName, systemImage: category.sidebarSymbol)
                            .tag(SidebarItem.library(peer.id, .category(category)))
                    }
                } label: {
                    // Selectable like the Devices rows: the DisclosureGroup is
                    // tagged with the peer's All Books value, so the native
                    // List selection highlights the row and opens All Books on
                    // click; the chevron still toggles, and the Close button
                    // works independently.
                    HStack(spacing: 6) {
                        Label(peer.name, systemImage: "books.vertical")
                        statusIcon(peer)
                        Spacer()
                        Button {
                            Task { await session.closePeer(peer) }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .help("Close \(peer.name)")
                    }
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button("Make Home Library") { session.changeHome(to: peer.id) }
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([peer.repository.root])
                        }
                        Button("Close") { Task { await session.closePeer(peer) } }
                    }
                    .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                        // Raw book files dropped on a peer row import into that
                        // peer; the real import lands in Task 6.
                        Task { await session.importDroppedFiles(providers: providers, into: peer) }
                        return true
                    }
                    // The header is a real selection item: native highlight
                    // when this peer's All Books view is active.
                    .tag(SidebarItem.library(peer.id, .allBooks))
                }
            }
            if !session.offlinePeers.isEmpty {
                ForEach(session.offlinePeers) { offline in
                    HStack(spacing: 6) {
                        Label(offline.name, systemImage: "externaldrive.badge.exclamationmark")
                            .foregroundStyle(.secondary)
                        if offline.isHome {
                            Image(systemName: "star.fill")
                                .font(.caption)
                                .foregroundStyle(.yellow)
                                .help("Was the home library")
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .contextMenu {
                        if offline.url != nil {
                            Button("Retry") {
                                Task { await session.retryOffline(offline) }
                            }
                        }
                        Button("Remove") {
                            session.removeOffline(offline)
                        }
                    }
                }
            }
        }
        .onChange(of: session.activeLibraryID) { _, newID in
            // Selecting a library expands it; switching away never collapses
            // it — expansion is user-controlled via the disclosure chevron.
            if let newID { expandedPeers.insert(newID) }
        }
    }

    /// Per-peer in-memory expansion state, user-controlled: selecting a peer
    /// adds it (onChange), collapsing/expanding edits it; nothing derives
    /// from the active selection, so switching libraries keeps groups open.
    private func expandedBinding(for peer: LibraryConnection) -> Binding<Bool> {
        Binding(
            get: { expandedPeers.contains(peer.id) },
            set: { expanded in
                if expanded {
                    expandedPeers.insert(peer.id)
                } else {
                    expandedPeers.remove(peer.id)
                }
            }
        )
    }

    /// Per-peer status: offline marker, syncing spinner, or pending count.
    @ViewBuilder
    private func statusIcon(_ peer: LibraryConnection) -> some View {
        // The shared-FS sync status is gone with the sync layer; the network
        // slice re-adds live connection status here.
        EmptyView()
    }
}

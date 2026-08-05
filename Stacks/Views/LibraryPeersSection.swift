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
                    HStack(spacing: 6) {
                        // Clicking the heading selects the library and opens
                        // its All Books view (the expandedBinding auto-expands
                        // the group because the selection makes it active).
                        Label(peer.name, systemImage: "books.vertical")
                            .contentShape(Rectangle())
                            .onTapGesture {
                                session.selectLibrarySubsection((peer.id, .allBooks))
                            }
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
    }

    /// Per-peer in-memory expansion state; the active peer's group
    /// auto-expands so a sidebar selection is always visible.
    private func expandedBinding(for peer: LibraryConnection) -> Binding<Bool> {
        Binding(
            get: { expandedPeers.contains(peer.id) || session.activeLibraryID == peer.id },
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
        if peer.isLibraryUnavailable {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .help("Library unavailable")
        } else if peer.isSyncing {
            ProgressView()
                .controlSize(.small)
        } else if peer.pendingSyncCount > 0 {
            Text("\(peer.pendingSyncCount) pending")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

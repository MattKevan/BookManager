import AppKit
import BookManagerCore
import SwiftUI

/// Tile frames in the grid's named coordinate space, collected for marquee
/// selection. LazyVGrid virtualizes — only visible tiles report frames.
private struct CoverTileFrameKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct CoverGridView: View {
    @Bindable var session: LibrarySession

    private let columns = [
        GridItem(.adaptive(minimum: 120, maximum: 180), spacing: 16)
    ]

    @State private var marqueeStart: CGPoint?
    @State private var marqueeCurrent: CGPoint?
    @State private var tileFrames: [UUID: CGRect] = [:]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(session.books) { book in
                    CoverTile(book: book)
                        .environment(\.librarySession, session)
                        .background {
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: CoverTileFrameKey.self,
                                    value: [book.id: geo.frame(in: .named("coverGrid"))]
                                )
                            }
                        }
                }
            }
            .padding(16)
        }
        .coordinateSpace(name: "coverGrid")
        .background {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { session.clearGridSelection() }
        }
        .simultaneousGesture(marqueeDrag)
        .onPreferenceChange(CoverTileFrameKey.self) { tileFrames = $0 }
        .overlay {
            Group {
                marqueeOverlay
                if session.books.isEmpty {
                    ContentUnavailableView(
                        "No Books",
                        systemImage: "books.vertical",
                        description: Text("Drag ebook files here or use Add Books to import.")
                    )
                }
            }
        }
    }

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
}

private struct CoverTile: View {
    let book: IndexedBook
    @Environment(\.librarySession) private var session
    @State private var image: NSImage?
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            cover
                .frame(height: 160)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.quaternary.opacity(0.4))
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            session?.selection.contains(book.id) ?? false ? Color.accentColor : .clear,
                            lineWidth: 3
                        )
                )
                .onTapGesture(count: 2) {
                    Task { await session?.open(id: book.id) }
                }
                .onTapGesture {
                    session?.selectInGrid(book)
                }
                .onHover { hovering in
                    isHovering = hovering
                }
            Text(book.title)
                .font(.caption)
                .lineLimit(2)
                .foregroundStyle(.primary)
            Text(book.authors.joined(separator: ", "))
                .font(.caption2)
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isHovering ? Color.accentColor.opacity(0.08) : .clear)
        )
        .task {
            image = await ThumbnailCache.shared.thumbnail(for: book, repository: session?.repository)
        }
    }

    @ViewBuilder
    private var cover: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "book.closed")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
        }
    }
}

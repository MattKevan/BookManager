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
    @State private var gridWidth: CGFloat = 0
    @FocusState private var focusedID: UUID?

    /// Estimated grid columns for Up/Down navigation (adaptive minimum item
    /// width ≈ 120pt + 16pt spacing + padding).
    private var estimatedColumns: Int {
        Int(max(1, (gridWidth / 140).rounded(.down)))
    }

    var body: some View {
        grid
            .coordinateSpace(name: "coverGrid")
            .background {
                GeometryReader { geo in
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { session.clearGridSelection() }
                        .onAppear { gridWidth = geo.size.width }
                        .onChange(of: geo.size.width) { _, newValue in gridWidth = newValue }
                }
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
            .onChange(of: session.selection) { _, newValue in
                // Keyboard focus follows a single selection (any mouse click), so
                // arrow keys work immediately after interaction. Marquee drags are
                // excluded: their selection is transient and mouse-driven.
                if !session.isMarqueeSelecting, newValue.count == 1, let id = newValue.first {
                    focusedID = id
                }
            }
            .onChange(of: focusedID) { _, newValue in
                // Single selection follows keyboard focus (Tab into the grid).
                if let newValue, !session.isMarqueeSelecting {
                    session.selection = [newValue]
                }
            }
            .onKeyPress(.leftArrow) { moveFocus(by: -1); return .handled }
            .onKeyPress(.rightArrow) { moveFocus(by: 1); return .handled }
            .onKeyPress(.upArrow) { moveFocus(by: -estimatedColumns); return .handled }
            .onKeyPress(.downArrow) { moveFocus(by: estimatedColumns); return .handled }
            .onKeyPress(.return) { openFocused(); return .handled }
            .onKeyPress(.delete) { trashFocused(); return .handled }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(session.books) { book in
                    tile(book)
                }
            }
            .padding(16)
        }
    }

    private func tile(_ book: IndexedBook) -> some View {
        CoverTile(book: book)
            .environment(\.librarySession, session)
            .focusable()
            .focused($focusedID, equals: book.id)
            .background {
                GeometryReader { geo in
                    Color.clear.preference(
                        key: CoverTileFrameKey.self,
                        value: [book.id: geo.frame(in: .named("coverGrid"))]
                    )
                }
            }
    }

    private var marqueeDrag: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("coverGrid"))
            .onChanged { value in
                if marqueeStart == nil {
                    marqueeStart = value.startLocation
                    session.isMarqueeSelecting = true
                }
                marqueeCurrent = value.location
                let rect = marqueeRect(start: value.startLocation, current: value.location)
                let hit = GridSelectionSemantics.intersecting(tileFrames, rect: rect)
                let add = NSEvent.modifierFlags.contains(.command)
                session.selection = add ? session.selection.union(hit) : hit
            }
            .onEnded { _ in
                session.isMarqueeSelecting = false
                marqueeStart = nil
                marqueeCurrent = nil
            }
    }

    // MARK: - Keyboard navigation

    /// Moves keyboard focus (and the single selection) by `delta` positions in
    /// `session.books` order; Left/Right ±1, Up/Down ±columns. Starting from
    /// nothing, the first keypress picks the first (or last) tile.
    private func moveFocus(by delta: Int) {
        let books = session.books
        guard !books.isEmpty else { return }
        let targetIndex: Int
        if let focusedID, let index = books.firstIndex(where: { $0.id == focusedID }) {
            targetIndex = min(max(index + delta, 0), books.count - 1)
        } else if let selected = session.selection.first,
                  let index = books.firstIndex(where: { $0.id == selected }) {
            targetIndex = min(max(index + delta, 0), books.count - 1)
        } else {
            targetIndex = delta > 0 ? 0 : books.count - 1
        }
        let book = books[targetIndex]
        focusedID = book.id
        session.selection = [book.id]
    }

    private func openFocused() {
        // Selection-first: a mouse/marquee selection must win over a possibly
        // stale keyboard focus (Finder semantics). The arrow-key flow keeps
        // selection == [focusedID] in lockstep, so this never changes it.
        if let selected = session.selection.first {
            Task { await session.open(id: selected) }
        } else if let focusedID {
            Task { await session.open(id: focusedID) }
        }
    }

    private func trashFocused() {
        // Selection-first: trash what the user sees selected, not a stale
        // focused book (a click + marquee leaves focus on the clicked book
        // while the visible selection is the marquee set).
        let ids: Set<UUID>
        if !session.selection.isEmpty {
            ids = session.selection
        } else if let focusedID {
            ids = [focusedID]
        } else {
            return
        }
        Task { await session.delete(ids: ids) }
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
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            Task { await session?.open(id: book.id) }
        }
        .onTapGesture {
            session?.selectInGrid(book)
        }
        .accessibilityLabel(book.title)
        .accessibilityHint("Double-click to open")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            Task { await session?.open(id: book.id) }
        }
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

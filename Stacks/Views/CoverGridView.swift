import AppKit
import StacksCore
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
    let browser: any LibraryBrowser
    /// Home-only chrome: the Edit Metadata context-menu item is available only
    /// for the home library (peers are browse + transfer in this slice).
    let isHome: Bool
    /// Session for the server-transfer context-menu items (nil disables them).
    let session: LibrarySession?

    init(browser: any LibraryBrowser, isHome: Bool = true, session: LibrarySession? = nil) {
        self.browser = browser
        self.isHome = isHome
        self.session = session
    }

    private let columns = [
        // `.bottom` alignment = the "invisible shelf": every cover's bottom
        // edge sits on the row's bottom line, and the row height expands to
        // the tallest cover in it (shorter covers don't float).
        GridItem(.adaptive(minimum: 120, maximum: 180), spacing: 16, alignment: .bottom)
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
                        .onAppear { gridWidth = geo.size.width }
                        .onChange(of: geo.size.width) { _, newValue in gridWidth = newValue }
                }
            }
            // Clicking empty grid background clears the selection. The tap
            // lives on the grid (ScrollView) itself, not in a background
            // view: on macOS the ScrollView captures hits across its whole
            // frame, so a background-attached gesture never fires. Tile
            // clicks still win via child-gesture precedence.
            .onTapGesture { browser.clearGridSelection() }
            .simultaneousGesture(marqueeDrag)
            .onPreferenceChange(CoverTileFrameKey.self) { tileFrames = $0 }
            .overlay {
                Group {
                    marqueeOverlay
                    if browser.books.isEmpty {
                        ContentUnavailableView(
                            "No Books",
                            systemImage: "books.vertical",
                            description: Text("Drag ebook files here or use Add Books to import.")
                        )
                    }
                }
            }
            .onChange(of: browser.selection) { _, newValue in
                // Keyboard focus follows a single selection (any mouse click), so
                // arrow keys work immediately after interaction. Marquee drags are
                // excluded: their selection is transient and mouse-driven.
                if !browser.isMarqueeSelecting, newValue.count == 1, let id = newValue.first {
                    focusedID = id
                }
            }
            .onChange(of: focusedID) { _, newValue in
                // Single selection follows keyboard focus (Tab into the grid).
                if let newValue, !browser.isMarqueeSelecting {
                    browser.selection = [newValue]
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
                ForEach(browser.books) { book in
                    tile(book)
                }
            }
            .padding(16)
        }
    }

    private func tile(_ book: IndexedBook) -> some View {
        CoverTile(book: book, browser: browser, isHome: isHome, session: session)
            .focusable()
            .focused($focusedID, equals: book.id)
            // No focus ring around the whole item: selection is shown only by
            // the accent border hugging the cover, not by an outer ring.
            .focusEffectDisabled()
            .background {
                GeometryReader { geo in
                    Color.clear.preference(
                        key: CoverTileFrameKey.self,
                        value: [book.id: geo.frame(in: .named("coverGrid"))]
                    )
                }
            }
            .onDrag { dragProvider(for: book) }
    }

    /// Makes a tile draggable onto a sidebar device row (sends that book's
    /// primary format file to the device).
    private func dragProvider(for book: IndexedBook) -> NSItemProvider {
        guard let url = browser.formatFileURL(for: book) else { return NSItemProvider() }
        return NSItemProvider(object: url as NSURL)
    }

    private var marqueeDrag: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("coverGrid"))
            .onChanged { value in
                if marqueeStart == nil {
                    marqueeStart = value.startLocation
                    browser.isMarqueeSelecting = true
                }
                marqueeCurrent = value.location
                let rect = marqueeRect(start: value.startLocation, current: value.location)
                let hit = GridSelectionSemantics.intersecting(tileFrames, rect: rect)
                let add = NSEvent.modifierFlags.contains(.command)
                browser.selection = add ? browser.selection.union(hit) : hit
            }
            .onEnded { _ in
                browser.isMarqueeSelecting = false
                marqueeStart = nil
                marqueeCurrent = nil
            }
    }

    // MARK: - Keyboard navigation

    /// Moves keyboard focus (and the single selection) by `delta` positions in
    /// `browser.books` order; Left/Right ±1, Up/Down ±columns. Starting from
    /// nothing, the first keypress picks the first (or last) tile.
    private func moveFocus(by delta: Int) {
        let books = browser.books
        guard !books.isEmpty else { return }
        let targetIndex: Int
        if let focusedID, let index = books.firstIndex(where: { $0.id == focusedID }) {
            targetIndex = min(max(index + delta, 0), books.count - 1)
        } else if let selected = browser.selection.first,
                  let index = books.firstIndex(where: { $0.id == selected }) {
            targetIndex = min(max(index + delta, 0), books.count - 1)
        } else {
            targetIndex = delta > 0 ? 0 : books.count - 1
        }
        let book = books[targetIndex]
        focusedID = book.id
        browser.selection = [book.id]
    }

    private func openFocused() {
        // Selection-first: a mouse/marquee selection must win over a possibly
        // stale keyboard focus (Finder semantics). The arrow-key flow keeps
        // selection == [focusedID] in lockstep, so this never changes it.
        if let selected = browser.selection.first {
            Task { await browser.open(id: selected) }
        } else if let focusedID {
            Task { await browser.open(id: focusedID) }
        }
    }

    private func trashFocused() {
        // Selection-first: trash what the user sees selected, not a stale
        // focused book (a click + marquee leaves focus on the clicked book
        // while the visible selection is the marquee set).
        let ids: Set<UUID>
        if !browser.selection.isEmpty {
            ids = browser.selection
        } else if let focusedID {
            ids = [focusedID]
        } else {
            return
        }
        browser.requestDelete(ids: ids)
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
    let browser: any LibraryBrowser
    let isHome: Bool
    let session: LibrarySession?

    init(book: IndexedBook, browser: any LibraryBrowser, isHome: Bool = true, session: LibrarySession? = nil) {
        self.book = book
        self.browser = browser
        self.isHome = isHome
        self.session = session
    }

    @State private var image: NSImage?
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            coverArea
            // Fixed text heights: the title wraps 1-2 lines and authors 1
            // line, so without reserved heights the cover's offset from the
            // tile bottom varies per book (covers land on different baselines
            // "seemingly at random"). Reserving the space keeps every cover's
            // bottom at a constant offset from the tile bottom, so the grid's
            // `.bottom` alignment puts them all on the shelf line.
            Text(book.title)
                .font(.caption)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(height: 30, alignment: .top)
                .foregroundStyle(.primary)
            Text(book.authors.joined(separator: ", "))
                .font(.caption2)
                .lineLimit(1)
                .frame(height: 14, alignment: .top)
                .foregroundStyle(.secondary)
        }
        .padding(6)
        .contentShape(Rectangle())
        .contextMenu {
            if isHome {
                Button("Edit Metadata") {
                    selectForContextMenu()
                    if !browser.selection.isEmpty {
                        browser.metadataEditQueue = browser.selectionBooks
                    }
                }
                .disabled(browser.isLibraryUnavailable)
            }
            Button("Show in Finder") {
                selectForContextMenu()
                if let id = browser.selection.first {
                    Task { await browser.reveal(id: id) }
                }
            }
            .disabled(browser.isLibraryUnavailable)
            if let session {
                if let remote = browser as? RemoteLibraryBrowser {
                    Button("Import to Home Library") {
                        selectForContextMenu()
                        Task { await session.importSelectionFromRemote(remote) }
                    }
                    .disabled(session.home == nil || browser.selection.isEmpty)
                } else if !session.remotes.isEmpty {
                    Menu("Send to Server…") {
                        ForEach(session.remotes) { remote in
                            Button(remote.name) {
                                selectForContextMenu()
                                Task { await session.sendSelectionToServer(remote) }
                            }
                        }
                    }
                    .disabled(browser.selection.isEmpty)
                }
                Divider()
            }
            Button("Delete Book", role: .destructive) {
                selectForContextMenu()
                if !browser.selection.isEmpty {
                    browser.requestDelete(ids: browser.selection)
                }
            }
        }
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture(count: 2) {
            Task { await browser.open(id: book.id) }
        }
        .onTapGesture {
            browser.selectInGrid(book)
        }
        .accessibilityLabel(book.title)
        .accessibilityHint("Double-click to open")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            Task { await browser.open(id: book.id) }
        }
        // Keyed on the cover hash: a metadata edit that replaces the cover
        // changes coverHash but keeps book.id, so a plain `.task` would never
        // re-run and the tile would show the old cover until scrolled away.
        .task(id: book.coverHash) {
            image = await browser.coverImage(for: book)
        }
    }

    /// Right-click on a tile: Finder semantics — the menu acts on the clicked
    /// book. A clicked tile that isn't already selected replaces the selection;
    /// a clicked member of a multi-selection keeps the multi-selection.
    private func selectForContextMenu() {
        guard !browser.selection.contains(book.id) else { return }
        browser.selection = [book.id]
    }

    /// The cover: selection border hugs the image itself (no gap when the
    /// cover doesn't fill the area), subtle corner radius, and hover
    /// feedback — the cover lifts slightly (anchored to the shelf) while the
    /// drop shadow deepens. No hover background tint.
    @ViewBuilder
    private var coverArea: some View {
        cover
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(
                        browser.selection.contains(book.id) ? Color.accentColor : .clear,
                        lineWidth: 3
                    )
            )
            // Natural height: the cover scales to the column width with its
            // own aspect ratio, so taller covers expand the row (the shelf
            // effect) instead of being capped at a fixed height.
            .frame(maxWidth: .infinity)
            .scaleEffect(isHovering ? 1.04 : 1, anchor: .bottom)
            .shadow(
                color: .black.opacity(isHovering ? 0.45 : 0.25),
                radius: isHovering ? 10 : 5,
                x: 0,
                y: isHovering ? 5 : 2
            )
            .animation(.easeOut(duration: 0.15), value: isHovering)
    }

    @ViewBuilder
    private var cover: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
        } else {
            // A real cover fills the column width at its own aspect ratio;
            // the missing-cover placeholder mirrors that footprint — a muted
            // portrait tile (deterministic per-book hue) with the title and
            // author overlaid, so cover-less books don't read as tiny
            // floating icons.
            placeholderCover
        }
    }

    /// The portrait placeholder for a book without a cover.
    private var placeholderCover: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(placeholderGradient)
            VStack(spacing: 6) {
                Image(systemName: "book.closed")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.secondary)
                Text(book.title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 8)
                if let firstAuthor = book.authors.first {
                    Text(firstAuthor)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                }
            }
        }
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
    }

    /// A muted, deterministic per-book tint (from the id's first byte — not
    /// `hashValue`, which is per-launch seeded) so the grid reads varied but
    /// calm, and the tint doesn't shuffle between launches.
    private var placeholderGradient: LinearGradient {
        let hue = withUnsafeBytes(of: book.id.uuid) { bytes in
            Double(bytes[0]) / 256.0
        }
        let light = NSColor(calibratedHue: hue, saturation: 0.10, brightness: 0.93, alpha: 1)
        let dark = NSColor(calibratedHue: hue, saturation: 0.28, brightness: 0.45, alpha: 1)
        return LinearGradient(
            colors: [Color(light), Color(dark)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

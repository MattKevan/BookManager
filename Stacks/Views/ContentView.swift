import AppKit
import StacksCore
import SwiftUI
import UniformTypeIdentifiers

/// Menu-command bridge to the search field's focus (Cmd-F). The browser view
/// publishes its `@FocusState` binding here; the Find command in
/// `StacksApp` sets it via the focused value.
private struct SearchFocusKey: FocusedValueKey {
    typealias Value = FocusState<Bool>.Binding
}

extension FocusedValues {
    var searchFocus: FocusState<Bool>.Binding? {
        get { self[SearchFocusKey.self] }
        set { self[SearchFocusKey.self] = newValue }
    }
}

struct ContentView: View {
    @Bindable var session: LibrarySession
    @State private var importURLs: [URL] = []
    @State private var showSendReport = false
    @State private var showCalibreImport = false
    @State private var showActivityPopover = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn
    @FocusState private var searchFocused: Bool

    var body: some View {
        Group {
            switch session.state {
            case .welcome:
                LibraryWelcomeView(
                    createLibrary: { session.createNewLibrary() },
                    openLibrary: { session.present(.open) }
                )
            case .loading:
                ProgressView("Opening Library…").controlSize(.large)
            case .loaded:
                loadedBody
            case let .failed(message):
                ContentUnavailableView {
                    Label("Couldn’t Open Library", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Choose Another Library") { Task { await session.closeLibrary() } }
                }
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Reconnection hook (slice 4a): on app activation, refresh
            // availability and sync (drain the outbox, ingest changes made by
            // other Macs). The always-on monitor is 4b.
            Task { await session.reconnectIfNeeded() }
            // Device support: rescan the USB bus on activation so a device
            // plugged in while the app was inactive appears in the sidebar.
            Task { await session.devices.scanForDevices() }
        }
        .onChange(of: session.selection) { _, newValue in
            if newValue.count == 1 && !session.isMarqueeSelecting && isHomeContext {
                session.inspectorPresented = true
            }
        }
        // Send-to-device completion: post a system notification instead of a
        // modal sheet (the sheet is the fallback when notifications are not
        // authorized). The DeviceManager flag is reset so a later send
        // re-triggers this observation.
        .onChange(of: session.devices.sendReportPresented) { _, presented in
            guard presented, let report = session.devices.sendReport else { return }
            Task {
                if await !SystemNotifier.postSendCompletion(report: report) { showSendReport = true }
                session.devices.sendReportPresented = false
            }
        }
        .fileImporter(
            isPresented: $session.isPickerPresented,
            allowedContentTypes: session.pickerAction == .addBooks
                ? [.epub, .pdf, .data,
                   UTType(filenameExtension: "mobi") ?? .data,
                   UTType(filenameExtension: "azw") ?? .data,
                   UTType(filenameExtension: "azw3") ?? .data]
                : [.folder],
            allowsMultipleSelection: true,
            onCompletion: { result in
                // NOTE: SwiftUI flips `isPresented` to false (firing the binding's
                // set) BEFORE onCompletion runs, so the action must be read from
                // `session.pickerAction`, which is only cleared here — never by the
                // binding.
                let purpose = session.pickerAction
                session.pickerAction = nil
                guard case let .success(urls) = result else { return }
                switch purpose {
                case .open:
                    Task { await session.openLibraryAsPeer(at: urls[0]) }
                case .addBooks:
                    Task {
                        await session.importFiles(urls: urls)
                        session.presentImportReport()
                    }
                case .calibre:
                    Task {
                        await session.selectCalibreLibrary(at: urls[0])
                        showCalibreImport = session.calibreSummary != nil
                    }
                case .changeHome:
                    Task { await session.openLibraryAsHome(at: urls[0]) }
                case nil:
                    break
                }
            },
            onCancellation: { session.pickerAction = nil }
        )
        .sheet(isPresented: Binding(
            get: { session.importReportPresented },
            set: { session.importReportPresented = $0 }
        )) {
            if let report = session.importReport {
                ImportReportView(report: report) { session.importReportPresented = false }
            }
        }
        .sheet(isPresented: $showSendReport) {
            if let report = session.devices.sendReport {
                SendReportView(report: report) { showSendReport = false }
            }
        }
        .sheet(isPresented: metadataEditorPresented) {
            if let books = session.metadataEditQueue {
                MetadataEditorView(books: books, session: session, onSave: { results in
                    Task {
                        for result in results {
                            await session.saveEdit(result.edit, coverData: result.coverData, for: result.book.id)
                        }
                        session.metadataEditQueue = nil
                    }
                }, onCancel: {
                    session.metadataEditQueue = nil
                })
            }
        }
        .sheet(isPresented: $showCalibreImport) {
            CalibreImportView(session: session)
        }
        .sheet(isPresented: $session.metadataReviewPresented) {
            MetadataReviewSheet(
                candidates: session.metadataCandidates,
                onPick: { candidate in
                    Task {
                        if let id = session.metadataBookID {
                            await session.applyMetadataCandidate(candidate, for: id)
                        }
                    }
                },
                onSkip: { session.metadataReviewPresented = false }
            )
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { session.lastError != nil },
                set: { if !$0 { session.lastError = nil } }
            )
        ) {
        } message: {
            Text(session.lastError ?? "")
        }
        .environment(\.librarySession, session)
    }

    private var loadedBody: some View {
        // macOS NavigationSplitView cannot hide only the middle column:
        // `NavigationSplitViewVisibility.doubleColumn` on a three-column view
        // means "content + detail" (the sidebar collapses), and `detailOnly`
        // hides both leading columns. So the 2-column and 3-column layouts are
        // structurally distinct split views, swapped on category selection.
        // `.doubleColumn` below keeps the sidebar visible in the 2-column
        // layout (where it is equivalent to `.all`).
        Group {
            if session.activeLibrary?.facetNavigation.category != nil {
                threeColumnBrowser
            } else {
                twoColumnBrowser
            }
        }
        .onChange(of: session.activeLibrary?.facetNavigation.category) { _, category in
            columnVisibility = (category == nil) ? .doubleColumn : .all
        }
        // The search field is a real `NSSearchField` in its own toolbar item
        // (not `.searchable`): the system search item always sits at the
        // toolbar's trailing edge with nothing allowed after it (and expands
        // to fill the toolbar on macOS 26), but the Inspector toggle must ride
        // to the RIGHT of the search bar. Keeping each control in its own
        // toolbar item makes the item order deterministic and prevents one
        // item's state change from re-laying-out the others.
        .focusedValue(\.searchFocus, $searchFocused)
        // The inspector shows HOME library book metadata (peers are browse +
        // transfer only in this slice): suppress it for devices and peers.
        .inspector(isPresented: Binding(
            get: { session.inspectorPresented && session.selectedDeviceID == nil && isHomeContext },
            set: { session.inspectorPresented = $0 }
        )) {
            BookInspectorView(session: session)
        }
        // Delete confirmation: all delete paths (menu, Delete key, context
        // menu) route through `requestDelete`, which sets `pendingDelete` on
        // the ACTIVE library (home or peer — peers trash into their own
        // trash); the destructive action here runs the actual `delete(ids:)`.
        .alert(
            (session.activeLibrary?.pendingDelete).map { "Move \($0.count) book\($0.count == 1 ? "" : "s") to Trash?" } ?? "Move to Trash?",
            isPresented: Binding(
                get: { session.activeLibrary?.pendingDelete != nil },
                set: { if !$0 { session.activeLibrary?.pendingDelete = nil } }
            )
        ) {
            Button("Move to Trash", role: .destructive) {
                if let ids = session.activeLibrary?.pendingDelete {
                    session.activeLibrary?.pendingDelete = nil
                    if let library = session.activeLibrary {
                        Task { await library.delete(ids: ids) }
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                session.activeLibrary?.pendingDelete = nil
            }
        } message: {
            Text("The selected book\((session.activeLibrary?.pendingDelete?.count ?? 1) == 1 ? "" : "s") stays in the library Trash and can be restored later.")
        }
    }

}

extension ContentView {
    /// Device management cluster: send-to-device (single button or device
    /// menu) plus the device-activity button. Present only while a device is
    /// connected ("when available"). Own group so it reads as a distinct
    /// cluster, leading of the library actions. Attached to the detail
    /// column — not the split view — so the toolbar chrome stays over the
    /// detail pane and the middle-column divider runs the full window height.
    private var deviceToolbarGroup: some ToolbarContent {
        ToolbarItemGroup {
            if session.devices.devices.isEmpty {
                EmptyView()
            } else if let device = session.devices.devices.first, session.devices.devices.count == 1 {
                Button {
                    Task {
                        // Mirror the multi-device path: select the sole device
                        // first so send-to-device works without a prior
                        // sidebar click (select is same-id guarded).
                        await session.devices.select(device.id)
                        await session.sendSelectionToDevice()
                    }
                } label: {
                    Label("Send to Device", systemImage: "arrow.up.doc")
                }
                .disabled(session.selection.isEmpty)
            } else {
                Menu {
                    ForEach(session.devices.devices) { device in
                        Button(device.name) {
                            Task {
                                await session.devices.select(device.id)
                                await session.sendSelectionToDevice()
                            }
                        }
                    }
                } label: {
                    Label("Send to Device", systemImage: "arrow.up.doc")
                }
                .disabled(session.selection.isEmpty)
            }
            if !session.devices.devices.isEmpty {
                Button {
                    showActivityPopover.toggle()
                } label: {
                    activityToolbarLabel
                        .frame(width: 22, height: 22)
                }
                .help("Device activity")
                .popover(isPresented: $showActivityPopover, arrowEdge: .bottom) {
                    DeviceActivityPopover(session: session)
                }
            }
        }
    }

    /// Library selection actions: Add Books, Open, Edit Metadata. The
    /// selection actions act on the library book selection, which is stale in
    /// device mode — they are hidden while a device is selected. Add Books is
    /// available in both modes.
    private var libraryActionsToolbarGroup: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                session.present(.addBooks)
            } label: {
                Label("Add Books", systemImage: "plus")
            }
            if session.selectedDeviceID == nil {
                Button {
                    openSelection()
                } label: {
                    Label("Open", systemImage: "book")
                }
                .disabled(session.selection.isEmpty)
                Button {
                    editSelection()
                } label: {
                    Label("Edit Metadata", systemImage: "pencil")
                }
                .disabled(session.isLibraryUnavailable || session.selection.isEmpty)
                if !session.peers.isEmpty {
                    Menu {
                        ForEach(session.peers) { peer in
                            Button(peer.name) {
                                Task { await session.copyHomeSelection(to: peer) }
                            }
                        }
                    } label: {
                        Label("Copy to Library…", systemImage: "arrow.up.doc")
                    }
                    .disabled(session.selection.isEmpty)
                    .help("Copy the selected books into another open library")
                }
            }
        }
    }

    /// The Table/Grid view picker. Only affects the library browser (the
    /// device view is table-only), so it is hidden in device mode.
    private var viewPickerToolbarItem: some ToolbarContent {
        ToolbarItemGroup {
            if session.selectedDeviceID == nil && session.activeLibrary != nil {
                Picker("View", selection: viewModeBinding) {
                    Image(systemName: "list.bullet")
                        .accessibilityLabel("Table")
                        .tag(BrowserViewMode.table)
                    Image(systemName: "square.grid.2x2")
                        .accessibilityLabel("Cover grid")
                        .tag(BrowserViewMode.grid)
                }
                .pickerStyle(.segmented)
                .help("Table or cover grid")
            }
        }
    }

    /// Sync status: its own toolbar item so the spinner/text swap never
    /// re-lays-out the search field or Inspector toggle. While syncing the
    /// label is a bare spinner — no “Syncing…” text — so the item keeps its
    /// icon width and the toolbar doesn't jump when syncing starts/ends.
    private var syncToolbarItem: some ToolbarContent {
        ToolbarItem {
            Button {
                Task { await session.syncNow() }
            } label: {
                syncToolbarLabel
            }
            .help(
                session.isLibraryUnavailable
                    ? "Library unavailable — read-only until the library reconnects. Click to try again."
                    : (session.isSyncing
                        ? "Syncing — checking the library for changes from other Macs"
                        : (session.pendingSyncCount > 0
                            ? "\(session.pendingSyncCount) change(s) waiting to sync — click to sync now"
                            : "Synced — click to check for changes from other Macs"))
            )
        }
    }

    @ViewBuilder
    private var syncToolbarLabel: some View {
        if session.isLibraryUnavailable {
            Label("Library unavailable", systemImage: "exclamationmark.triangle")
        } else if session.isSyncing {
            ProgressView()
                .controlSize(.small)
        } else if session.pendingSyncCount > 0 {
            Label("\(session.pendingSyncCount) pending", systemImage: "arrow.triangle.2.circlepath")
        } else {
            Label("Synced", systemImage: "checkmark.circle")
        }
    }

    /// The search field in its own toolbar item, so the sync spinner swap
    /// never re-lays-out it (or the Inspector toggle) and vice versa. Binds
    /// the ACTIVE library's search text (home in device mode, the peer when
    /// a peer is the browser context).
    private var searchToolbarItem: some ToolbarContent {
        ToolbarItem {
            if session.activeLibrary != nil {
                ToolbarSearchField(
                    text: librarySearchBinding,
                    prompt: "Search books",
                    isFocused: $searchFocused
                )
            }
        }
    }

    /// The Inspector toggle in its own toolbar item, trailing the search
    /// field so it sits at the very trailing edge of the toolbar, right of
    /// the search bar.
    private var inspectorToolbarItem: some ToolbarContent {
        ToolbarItem {
            if session.selectedDeviceID == nil {
                Button {
                    session.inspectorPresented.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .help("Show or hide the inspector")
            }
        }
    }


    /// Two-column layout (sidebar + detail): All Books and device views.
    private var twoColumnBrowser: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarColumn
        } detail: {
            detailColumn
        }
    }

    /// Three-column layout (sidebar + facet values + detail): a facet
    /// category is active in the sidebar.
    private var threeColumnBrowser: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarColumn
        } content: {
            FacetListView(browser: library)
        } detail: {
            detailColumn
        }
    }

    /// The library/device navigation sidebar, shared by both layouts. Its
    /// navigationTitle becomes the window title (the detail column sets none
    /// for the library browser — a facet value like "All Books" must not
    /// replace the browsed library's name). DeviceBooksView titles itself
    /// with the device name, which overrides this in device mode.
    private var sidebarColumn: some View {
        SidebarView(session: session)
            .navigationTitle(session.activeLibrary?.name ?? "Stacks")
    }

    /// The trailing column: the device books table, the active library's
    /// browser, or a no-library placeholder.
    private var detailColumn: some View {
        Group {
            if session.selectedDeviceID != nil {
                DeviceBooksView(session: session) {
                    session.presentImportReport()
                }
            } else if let library = session.activeLibrary {
                libraryBrowser(for: library)
            } else {
                ContentUnavailableView {
                    Label("No Library Open", systemImage: "books.vertical")
                } description: {
                    Text("Open or create a library to begin.")
                }
            }
        }
        // One `.toolbar` with separate items (not multiple `.toolbar`
        // attachments — those reorder unpredictably on macOS). Statement
        // order here is the toolbar order, and a leading flexible spacer
        // aligns the whole cluster to the trailing edge. Fixed spacers break
        // the macOS 26 glass surface into the distinct clusters below.
        // Right-to-left from the edge: Inspector toggle (home only), search
        // field, grid/list picker, library actions (home: Add Books / Open /
        // Edit Metadata; peer: Refresh / Copy to Home Library / Close),
        // device management, then the sync status at the leading end.
        .toolbar {
            ToolbarSpacer(.flexible)
            syncToolbarItem
            ToolbarSpacer(.fixed)
            deviceToolbarGroup
            ToolbarSpacer(.fixed)
            if isHomeContext {
                libraryActionsToolbarGroup
            } else if session.activeLibrary != nil {
                peerToolbarGroup
            }
            ToolbarSpacer(.fixed)
            viewPickerToolbarItem
            ToolbarSpacer(.fixed)
            searchToolbarItem
            ToolbarSpacer(.fixed)
            if isHomeContext {
                inspectorToolbarItem
            }
        }
    }

    /// Toolbar label for device activity: a determinate circular ring while a
    /// sized operation (import download) runs, an indeterminate spinner for
    /// unsized operations, an error badge when a device error is pending, and
    /// the plain drive icon when idle. Fixed 22x22 frame (applied at the call
    /// site) keeps the toolbar from jumping between states.
    @ViewBuilder
    private var activityToolbarLabel: some View {
        if let activity = session.devices.currentActivity {
            if let progress = activity.progress {
                Circle()
                    .trim(from: 0, to: max(0.02, progress))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        } else if session.devices.deviceError != nil {
            Image(systemName: "externaldrive.badge.exclamationmark")
        } else {
            Image(systemName: "externaldrive")
        }
    }

    /// The library connection backing the browser. Only the `.loaded` state
    /// shows the browser, so the active library is always present there. Task 5
    /// routes the sidebar selection between home and peers; for now the active
    /// library is home (or the most recently opened peer).
    private var library: LibraryConnection {
        guard let library = session.activeLibrary else {
            preconditionFailure("Browser shown without an open library")
        }
        return library
    }

    /// Binds the grid/list picker to the active connection's view mode.
    private var viewModeBinding: Binding<BrowserViewMode> {
        Binding(
            get: { library.viewMode },
            set: { library.viewMode = $0 }
        )
    }

    /// The browser content for a library. Home keeps the drag-drop import
    /// handler (dropped files land in home); a peer gets the PeerLibraryView
    /// wrapper, whose context menu adds Copy to Home Library (the copy itself
    /// is wired in Task 6).
    @ViewBuilder
    private func libraryBrowser(for library: LibraryConnection) -> some View {
        if library === session.home {
            Group {
                switch library.viewMode {
                case .table:
                    BookTableView(browser: library)
                case .grid:
                    CoverGridView(browser: library)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                handleDrop(providers)
            }
        } else {
            PeerLibraryView(peer: library) {
                Task { await session.copySelectionFromPeerToHome(library) }
            }
        }
    }

    /// True when the browser context is the home library. Device selection
    /// clears `activeLibraryID`, so the context resolves to home in device
    /// mode and counts as home context; peer mode does not — the home-only
    /// toolbar cluster and inspector apply only to home.
    private var isHomeContext: Bool {
        session.activeLibrary === session.home
    }

    /// Peer-context toolbar cluster, replacing Add/Open/Edit + the inspector
    /// while a peer library is the browser context: Refresh, Copy to Home
    /// Library (Task 6 wires the real transfer), and Close.
    private var peerToolbarGroup: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                if let peer = session.activeLibrary {
                    Task { await peer.refreshBooks() }
                }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Reload this library's books")
            Button {
                if let peer = session.activeLibrary, session.home != nil {
                    Task { await session.copySelectionFromPeerToHome(peer) }
                }
            } label: {
                Label("Copy to Home Library", systemImage: "arrow.down.doc")
            }
            .disabled(session.activeLibrary?.selection.isEmpty ?? true || session.home == nil)
            .help("Copy the selected books into your home library")
            Button {
                if let peer = session.activeLibrary {
                    Task { await session.closePeer(peer) }
                }
            } label: {
                Label("Close", systemImage: "xmark")
            }
            .help("Close this library")
        }
    }

    /// Binds the toolbar search field to the active library's search text.
    private var librarySearchBinding: Binding<String> {
        Binding(
            get: { library.searchText },
            set: { library.searchText = $0 }
        )
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                if let url = await LibrarySession.loadURL(from: provider) {
                    urls.append(url)
                }
            }
            guard !urls.isEmpty else { return }
            guard let target = session.activeLibrary else { return }
            await session.importFiles(into: target, urls: urls)
        }
        return true
    }

    private func openSelection() {
        if let id = session.selection.first {
            Task { await session.open(id: id) }
        }
    }

    private func editSelection() {
        session.metadataEditQueue = session.selectionBooks
    }

    /// Dismissal binding for the batch metadata editor sheet.
    private var metadataEditorPresented: Binding<Bool> {
        Binding(
            get: { session.metadataEditQueue != nil },
            set: { if !$0 { session.metadataEditQueue = nil } }
        )
    }
}

/// Toolbar popover showing device connection status, the current queue
/// operation (with detail and progress), and the queued backlog — the
/// Safari-Downloads style activity surface. Activity is secondary chrome in
/// the toolbar; the main content view stays stable.
private struct DeviceActivityPopover: View {
    @Bindable var session: LibrarySession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: session.devices.deviceError != nil
                    ? "exclamationmark.triangle"
                    : "externaldrive")
                    .foregroundStyle(session.devices.deviceError != nil ? .orange : .secondary)
                Text(session.devices.connectionStatus)
                    .lineLimit(1)
            }
            .font(.headline)
            if let activity = session.devices.currentActivity {
                activityRow(activity)
            }
            if session.devices.pendingCount > 0 {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Queued (\(session.devices.pendingCount))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(Array(session.devices.pendingTitles.enumerated()), id: \.offset) { _, title in
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.mini)
                            Text(title)
                        }
                        .font(.caption)
                    }
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
            }
        }
        .padding(14)
        .frame(minWidth: 300)
    }

    private func activityRow(_ activity: DeviceActivity) -> some View {
        HStack(spacing: 8) {
            if let progress = activity.progress {
                ProgressView(value: progress)
                    .frame(width: 90)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(activity.title)
                if let detail = activity.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

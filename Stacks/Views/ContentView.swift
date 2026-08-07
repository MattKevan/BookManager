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
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @FocusState private var searchFocused: Bool

    /// Typed binding for the session error alert (extracted so the body's
    /// modifier chain type-checks in reasonable time).
    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { session.lastError != nil },
            set: { presented in
                if !presented { session.lastError = nil }
            }
        )
    }

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
            // Device support: rescan the USB bus on activation so a device
            // plugged in while the app was inactive appears in the sidebar.
            // (The shared-FS reconnection hook left with the sync layer.)
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

        .environment(\.librarySession, session)
        .alert(
            "Something went wrong",
            isPresented: errorAlertBinding
        ) {
        } message: {
            Text(session.lastError ?? "")
        }
    }

    private var loadedBody: some View {
        // ONE stable split view (sidebar + detail), never swapped: the facet
        // "middle column" is a pane rendered inside the detail column while a
        // category is active. The previous approach swapped between 2- and
        // 3-column split views, which made SwiftUI re-register toolbar items
        // and crashed macOS (duplicate NSToolbar items / reentrant layout) —
        // so All Books is simply the detail column without the facet pane.
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarColumn
        } detail: {
            detailColumn
        }
        // `columnVisibility` is fixed at `.all` (sidebar always visible; the
        // user can still toggle it via the split view's own control).
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
    @ToolbarContentBuilder
    private var deviceToolbarItems: some ToolbarContent {
        ToolbarItem(id: "send-to-device") {
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
        }
        ToolbarItem(id: "device-activity") {
            if !session.devices.devices.isEmpty || session.calibreActivity != nil {
                Button {
                    showActivityPopover.toggle()
                } label: {
                    activityToolbarLabel
                        .frame(width: 22, height: 22)
                }
                .help("Activity")
                .popover(isPresented: $showActivityPopover, arrowEdge: .bottom) {
                    ActivityPopover(session: session)
                }
            }
        }
    }

    /// Library selection actions: Add Books, Open, Edit Metadata. The
    /// selection actions act on the library book selection, which is stale in
    /// device mode — they are hidden while a device is selected. Add Books is
    /// available in both modes.
    @ToolbarContentBuilder
    private var libraryActionItems: some ToolbarContent {
        ToolbarItem(id: "add-books") {
            Button {
                session.present(.addBooks)
            } label: {
                Label("Add Books", systemImage: "plus")
            }
        }
        ToolbarItem(id: "open") {
            if session.selectedDeviceID == nil {
                Button {
                    openSelection()
                } label: {
                    Label("Open", systemImage: "book")
                }
                .disabled(session.selection.isEmpty)
            }
        }
        ToolbarItem(id: "edit-metadata") {
            if session.selectedDeviceID == nil {
                Button {
                    editSelection()
                } label: {
                    Label("Edit Metadata", systemImage: "pencil")
                }
                .disabled(session.isLibraryUnavailable || session.selection.isEmpty)
            }
        }
        ToolbarItem(id: "copy-to-library") {
            if session.selectedDeviceID == nil, !session.peers.isEmpty {
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

    /// The Table/Grid view picker. Only affects the library browser (the
    /// device view is table-only), so it is hidden in device mode.
    private var viewPickerToolbarItem: some ToolbarContent {
        ToolbarItem(id: "view-picker") {
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

    /// The search field in its own toolbar item, so layout stays stable when
    /// the surrounding items change. Binds the ACTIVE library's search text
    /// (home in device mode, the peer when a peer is the browser context).
    private var searchToolbarItem: some ToolbarContent {
        ToolbarItem(id: "search") {
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
        ToolbarItem(id: "inspector") {
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

    /// The library/device navigation sidebar, shared by both layouts. Its
    /// navigationTitle shows the browsed library's name as the sidebar header;
    /// the WINDOW title comes from `detailColumn`'s navigationTitle (the
    /// sidebar's does not propagate to the window on macOS).
    private var sidebarColumn: some View {
        SidebarView(session: session)
            .navigationTitle(session.activeLibrary?.name ?? "Stacks")
            .navigationSplitViewColumnWidth(220)
    }

    /// The window title: the currently browsed device or library — with the
    /// active facet category when browsing one (e.g. "Library3 — Authors").
    /// Falls back to the app name only when nothing is open.
    private var windowTitle: String {
        if session.selectedDeviceID != nil {
            return session.devices.selectedDevice?.name ?? "Device"
        }
        guard let library = session.activeLibrary else { return "Stacks" }
        if let category = library.facetNavigation.category {
            return "\(library.name) — \(category.displayName)"
        }
        return library.name
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
                // The facet "middle column" as a fixed-width pane inside the
                // detail column, present only while a category is active so
                // All Books stays a true 2-column layout. Fixed (not
                // draggable): live resize reflow flickered — SwiftUI's
                // LazyVGrid cannot animate a continuous reflow.
                HStack(spacing: 0) {
                    if library.facetNavigation.category != nil {
                        FacetListView(browser: library)
                            .frame(width: 240)
                        Divider()
                    }
                    libraryBrowser(for: library)
                }
            } else {
                ContentUnavailableView {
                    Label("No Library Open", systemImage: "books.vertical")
                } description: {
                    Text("Open or create a library to begin.")
                }
            }
        }
        // The WINDOW title: the browsed device's or library's name. The
        // detail column is what drives the macOS window title (the sidebar's
        // navigationTitle does not), so the facet value must never override
        // it — a facet browser shows the library name, not "All Books".
        .navigationTitle(windowTitle)
        // One `.toolbar` with separate items (not multiple `.toolbar`
        // attachments — those reorder unpredictably on macOS). Statement
        // order here is the toolbar order, and a leading flexible spacer
        // aligns the whole cluster to the trailing edge. Fixed spacers break
        // the macOS 26 glass surface into the distinct clusters below.
        // Right-to-left from the edge: Inspector toggle (home only), search
        // field, grid/list picker, library actions (home: Add Books / Open /
        // Edit Metadata; peer: Refresh / Copy to Home Library / Close),
        // device management at the leading end.
        .toolbar {
            ToolbarSpacer(.flexible)
            ToolbarSpacer(.fixed)
            deviceToolbarItems
            ToolbarSpacer(.fixed)
            if isHomeContext {
                libraryActionItems
            } else if session.activeLibrary != nil {
                peerActionItems
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
        if let activity = session.calibreActivity {
            if let progress = activity.progress {
                Circle()
                    .trim(from: 0, to: max(0.02, progress))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        } else if let activity = session.devices.currentActivity {
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
    @ToolbarContentBuilder
    private var peerActionItems: some ToolbarContent {
        ToolbarItem(id: "refresh-peer") {
            Button {
                if let peer = session.activeLibrary {
                    Task { await peer.refreshBooks() }
                }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Reload this library's books")
        }
        ToolbarItem(id: "copy-to-home") {
            Button {
                if let peer = session.activeLibrary, session.home != nil {
                    Task { await session.copySelectionFromPeerToHome(peer) }
                }
            } label: {
                Label("Copy to Home Library", systemImage: "arrow.down.doc")
            }
            .disabled(session.activeLibrary?.selection.isEmpty ?? true || session.home == nil)
            .help("Copy the selected books into your home library")
        }
        ToolbarItem(id: "close-peer") {
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

/// Toolbar popover showing live activity: device connection status, the
/// current queue operation (with detail and progress), the queued backlog,
/// and Calibre import/scan progress — the Safari-Downloads style activity
/// surface. Activity is secondary chrome in the toolbar; the main content
/// view stays stable.
private struct ActivityPopover: View {
    @Bindable var session: LibrarySession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let activity = session.calibreActivity {
                calibreActivityRow(activity)
                Divider()
            }
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

    /// Live Calibre import/scan: headline + progress, the book being
    /// processed, and the last outcome — enough to see it is advancing, not
    /// frozen.
    private func calibreActivityRow(_ activity: CalibreImportActivity) -> some View {
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
                if let currentTitle = activity.currentTitle {
                    Text(currentTitle)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let detail = activity.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
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

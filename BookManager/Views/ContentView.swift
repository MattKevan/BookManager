import AppKit
import BookManagerCore
import SwiftUI
import UniformTypeIdentifiers

/// Menu-command bridge to the search field's focus (Cmd-F). The browser view
/// publishes its `@FocusState` binding here; the Find command in
/// `BookManagerApp` sets it via the focused value.
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
    @State private var showImportReport = false
    @State private var showDiagnostics = false
    @State private var showCalibreImport = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        Group {
            switch session.state {
            case .welcome:
                LibraryWelcomeView(
                    createLibrary: { session.present(.create) },
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
                    Button("Choose Another Library") { session.closeLibrary() }
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
            if newValue.count == 1 && !session.isMarqueeSelecting {
                session.inspectorPresented = true
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
                case .create:
                    Task { await session.createLibrary(at: urls[0]) }
                case .open:
                    Task { await session.openLibrary(at: urls[0]) }
                case .addBooks:
                    Task {
                        await session.importFiles(urls: urls)
                        showImportReport = session.importReport != nil
                    }
                case .calibre:
                    Task {
                        await session.selectCalibreLibrary(at: urls[0])
                        showCalibreImport = session.calibreSummary != nil
                    }
                case nil:
                    break
                }
            },
            onCancellation: { session.pickerAction = nil }
        )
        .sheet(isPresented: $showImportReport) {
            if let report = session.importReport {
                ImportReportView(report: report) { showImportReport = false }
            }
        }
        .sheet(isPresented: Binding(
            get: { session.devices.sendReportPresented },
            set: { session.devices.sendReportPresented = $0 }
        )) {
            if let report = session.devices.sendReport {
                SendReportView(report: report) { session.devices.sendReportPresented = false }
            }
        }
        .sheet(item: $session.inspectorBook) { book in
            MetadataEditorView(book: book, session: session, onSave: { edit, coverData in
                Task { await session.saveEdit(edit, coverData: coverData, for: book.id) }
                session.inspectorBook = nil
            }, onCancel: {
                session.inspectorBook = nil
            })
        }
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsView()
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
        NavigationSplitView {
            SidebarView(session: session)
                .navigationTitle(session.repository?.root.lastPathComponent ?? "Library")
        } detail: {
            Group {
                if session.selectedDeviceID != nil {
                    DeviceBooksView(session: session) {
                        showImportReport = true
                    }
                } else {
                    browser
                        .navigationTitle(session.selectedFacet?.value ?? "All Books")
                }
            }
        }
        .inspector(isPresented: $session.inspectorPresented) {
            BookInspectorView(session: session)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    session.present(.addBooks)
                } label: {
                    Label("Add Books", systemImage: "plus")
                }
                Button {
                    openSelection()
                } label: {
                    Label("Open", systemImage: "book")
                }
                .disabled(session.selection.isEmpty)
                Button {
                    revealSelection()
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .disabled(session.selection.isEmpty)
                Button {
                    editSelection()
                } label: {
                    Label("Edit Metadata", systemImage: "pencil")
                }
                .disabled(session.isLibraryUnavailable || session.selection.count != 1)
                Button {
                    session.inspectorPresented.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .help("Show or hide the inspector")
                Picker("View", selection: $session.viewMode) {
                    Image(systemName: "list.bullet")
                        .accessibilityLabel("Table")
                        .tag(LibrarySession.ViewMode.table)
                    Image(systemName: "square.grid.2x2")
                        .accessibilityLabel("Cover grid")
                        .tag(LibrarySession.ViewMode.grid)
                }
                .pickerStyle(.segmented)
                .help("Table or cover grid")
                if session.devices.devices.isEmpty {
                    EmptyView()
                } else if session.devices.devices.count == 1 {
                    Button {
                        Task { await session.sendSelectionToDevice() }
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
                Button {
                    showDiagnostics = true
                } label: {
                    Label("Diagnostics", systemImage: "wrench.and.screwdriver")
                }
                Button {
                    Task { await session.syncNow() }
                } label: {
                    if session.isLibraryUnavailable {
                        Label("Library unavailable", systemImage: "exclamationmark.triangle")
                    } else if session.isSyncing {
                        HStack(spacing: 4) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Syncing…")
                        }
                    } else if session.pendingSyncCount > 0 {
                        Label("\(session.pendingSyncCount) pending", systemImage: "arrow.triangle.2.circlepath")
                    } else {
                        Label("Synced", systemImage: "checkmark.circle")
                    }
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
                Button {
                    session.present(.calibre)
                } label: {
                    Label("Import from Calibre…", systemImage: "tray.and.arrow.down")
                }
                .help("Import a copy of an existing Calibre library")
            }
        }
    }

    private var browser: some View {
        Group {
            switch session.viewMode {
            case .table:
                BookTableView(session: session)
            case .grid:
                CoverGridView(session: session)
            }
        }
        .searchable(text: $session.searchText, prompt: "Search books")
        .searchFocused($searchFocused)
        .focusedValue(\.searchFocus, $searchFocused)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
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
            await session.importFiles(urls: urls)
            showImportReport = session.importReport != nil
        }
        return true
    }

    private func openSelection() {
        if let id = session.selection.first {
            Task { await session.open(id: id) }
        }
    }

    private func revealSelection() {
        if let id = session.selection.first {
            Task { await session.reveal(id: id) }
        }
    }

    private func editSelection() {
        if let id = session.selection.first,
           let book = session.books.first(where: { $0.id == id }) {
            session.inspectorBook = book
        }
    }
}

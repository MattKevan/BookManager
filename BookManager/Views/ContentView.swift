import AppKit
import BookManagerCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var session: LibrarySession
    @State private var pickerPurpose: PickerPurpose?
    @State private var isPickerPresented = false
    @State private var importURLs: [URL] = []
    @State private var showImportReport = false
    @State private var showDiagnostics = false

    private enum PickerPurpose: Identifiable {
        case create, open, addBooks
        var id: Self { self }
    }

    var body: some View {
        Group {
            switch session.state {
            case .welcome:
                LibraryWelcomeView(
                    createLibrary: {
                        pickerPurpose = .create
                        isPickerPresented = true
                    },
                    openLibrary: {
                        pickerPurpose = .open
                        isPickerPresented = true
                    }
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
        .fileImporter(
            isPresented: $isPickerPresented,
            allowedContentTypes: pickerPurpose == .addBooks
                ? [.epub, .pdf, .data]
                : [.folder],
            allowsMultipleSelection: true,
            onCompletion: { result in
                // NOTE: SwiftUI flips `isPresented` to false (firing the binding's
                // set) BEFORE onCompletion runs, so the purpose must be read from
                // `pickerPurpose`, which is only cleared here — never by the binding.
                let purpose = pickerPurpose
                pickerPurpose = nil
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
                case nil:
                    break
                }
            },
            onCancellation: { pickerPurpose = nil }
        )
        .sheet(isPresented: $showImportReport) {
            if let report = session.importReport {
                ImportReportView(report: report) { showImportReport = false }
            }
        }
        .sheet(item: $session.inspectorBook) { book in
            MetadataEditorView(book: book, onSave: { edit in
                Task { await session.saveEdit(edit, for: book.id) }
                session.inspectorBook = nil
            }, onCancel: {
                session.inspectorBook = nil
            })
        }
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsView()
        }
        .onChange(of: showDiagnostics) { _, presented in
            if presented { Task { await session.reloadDiagnostics() } }
        }
        .environment(\.librarySession, session)
    }

    private var loadedBody: some View {
        NavigationSplitView {
            SidebarView(session: session)
                .navigationTitle(session.repository?.root.lastPathComponent ?? "Library")
        } detail: {
            browser
                .navigationTitle(session.selectedFacet?.value ?? "All Books")
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    pickerPurpose = .addBooks
                    isPickerPresented = true
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
                .disabled(session.selection.count != 1)
                Picker("View", selection: $session.viewMode) {
                    Image(systemName: "list.bullet").tag(LibrarySession.ViewMode.table)
                    Image(systemName: "square.grid.2x2").tag(LibrarySession.ViewMode.grid)
                }
                .pickerStyle(.segmented)
                .help("Table or cover grid")
                Button {
                    showDiagnostics = true
                } label: {
                    Label("Diagnostics", systemImage: "wrench.and.screwdriver")
                }
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
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                if let url = await loadURL(from: provider) {
                    urls.append(url)
                }
            }
            guard !urls.isEmpty else { return }
            await session.importFiles(urls: urls)
            showImportReport = session.importReport != nil
        }
        return true
    }

    private func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadTransferable(type: URL.self) { result in
                continuation.resume(returning: try? result.get())
            }
        }
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

import SwiftUI

@main
struct StacksApp: App {
    @State private var session = LibrarySession()
    @State private var settings = AppSettings()

    init() {
        // One-time migration of the Application Support directory so
        // SyncState/outbox state survives the rename (see StacksSupportMigrator).
        StacksSupportMigrator.migrateOnce()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(session: session)
                .task {
                    // Skip auto-reopen under UI testing so tests start from a
                    // deterministic welcome screen.
                    if !CommandLine.arguments.contains("--ui-testing") {
                        await session.reopenLibraries()
                    }
                }
        }
        .defaultSize(width: 1_100, height: 720)
        .commands {
            AppCommands(session: session)
        }
        Settings {
            SettingsView(settings: settings)
                .environment(\.librarySession, session)
        }
    }
}

/// The app's menu commands. `@FocusedValue` resolves against the focused view
/// (the browser publishes its search-field focus binding), so Cmd-F can drive
/// it from here without touching the session.
private struct AppCommands: Commands {
    let session: LibrarySession

    @FocusedValue(\.searchFocus) private var searchFocus: FocusState<Bool>.Binding?

    /// The browser context is the home library (device mode counts — active
    /// library resolves to home there). Peer mode does not: the Books-menu
    /// chrome (Edit Metadata, Fetch Missing, Open in Reader, Show in Finder,
    /// Copy to Library) is home-only.
    private var isHomeContext: Bool {
        session.activeLibrary === session.home
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Create Library…") { session.createNewLibrary() }
                .keyboardShortcut("n", modifiers: [.command, .shift])   // Cmd+N reserved
            Divider()
            Button("Close Library") { Task { await session.closeLibrary() } }
                .keyboardShortcut("w", modifiers: [.command, .shift])
        }
        // File menu: library open/import actions (the old custom Library menu
        // is gone — Open moves to File with Cmd+O).
        CommandGroup(after: .newItem) {
            Button("Open Library…") { session.present(.open) }
                .keyboardShortcut("o", modifiers: .command)
            Menu("Open Recent") {
                if session.recentLibraries.isEmpty {
                    Text("No Recent Libraries")
                }
                ForEach(session.recentLibraries) { entry in
                    Button(entry.name) {
                        Task { await session.openLibraryAsPeer(at: entry.url) }
                    }
                }
            }
            Divider()
            Button("Import Books…") { session.present(.addBooks) }
                .keyboardShortcut("i", modifiers: .command)
            Button("Import Calibre Library…") { session.present(.calibre) }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Divider()
            Button("Send to Device") {
                Task { await session.sendSelectionToDevice() }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(session.selection.isEmpty || session.devices.selectedDeviceID == nil)
        }
        // Books menu: actions on the library selection and its metadata.
        // All items are HOME-ONLY chrome (peers are browse + transfer in this
        // slice), so they are disabled when a peer is the browser context.
        CommandMenu("Books") {
            Button("Edit Metadata…") {
                session.metadataEditQueue = session.selectionBooks
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(session.selection.isEmpty || session.isLibraryUnavailable || session.selectedDeviceID != nil || !isHomeContext)
            Button("Fetch Missing Metadata…") {
                Task { await session.enrichAllBooksMissingMetadata() }
            }
            .disabled(session.isLibraryUnavailable || !isHomeContext)
            Divider()
            Button("Open in Reader") {
                if let id = session.selection.first {
                    Task { await session.open(id: id) }
                }
            }
            .disabled(session.selection.isEmpty || session.isLibraryUnavailable || session.selectedDeviceID != nil || !isHomeContext)
            Button("Show in Finder") {
                if let id = session.selection.first {
                    Task { await session.reveal(id: id) }
                }
            }
            .disabled(session.selection.isEmpty || session.isLibraryUnavailable || session.selectedDeviceID != nil || !isHomeContext)
            if !session.peers.isEmpty {
                Divider()
                Menu("Copy to Library…") {
                    ForEach(session.peers) { peer in
                        Button(peer.name) {
                            Task { await session.copyHomeSelection(to: peer) }
                        }
                    }
                }
                .disabled(session.selection.isEmpty || session.isLibraryUnavailable || session.selectedDeviceID != nil || !isHomeContext)
            }
        }
        // Edit menu: deletion of the ACTIVE library's selection (Cmd+Delete;
        // the bare Delete/Backspace key is handled in the grid/table views).
        // Peers trash into their own trash; device mode stays disabled.
        CommandGroup(after: .pasteboard) {
            Button("Delete") {
                if let library = session.activeLibrary {
                    library.requestDelete(ids: library.selection)
                }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(
                session.activeLibrary?.selection.isEmpty ?? true
                    || session.activeLibrary?.isLibraryUnavailable ?? true
                    || session.selectedDeviceID != nil
            )
        }
        CommandGroup(after: .textEditing) {
            Button("Find") {
                searchFocus?.wrappedValue = true
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(searchFocus == nil)
        }
    }
}

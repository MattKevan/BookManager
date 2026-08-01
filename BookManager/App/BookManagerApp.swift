import SwiftUI

@main
struct BookManagerApp: App {
    @State private var session = LibrarySession()

    var body: some Scene {
        WindowGroup {
            ContentView(session: session)
                .task {
                    // Skip auto-reopen under UI testing so tests start from a
                    // deterministic welcome screen.
                    if !CommandLine.arguments.contains("--ui-testing") {
                        await session.openMostRecentLibrary()
                    }
                }
        }
        .defaultSize(width: 1_100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Create Library…") { session.present(.create) }
                    .keyboardShortcut("n", modifiers: .command)
                Divider()
                Button("Close Library") { session.closeLibrary() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
            }
            CommandMenu("Library") {
                Button("Open Library…") { session.present(.open) }
                    .keyboardShortcut("o", modifiers: .command)
                Divider()
                Menu("Open Recent") {
                    if session.recentLibraries.isEmpty {
                        Text("No Recent Libraries")
                    }
                    ForEach(session.recentLibraries) { entry in
                        Button(entry.name) {
                            Task { await session.openLibrary(at: entry.url) }
                        }
                    }
                }
            }
        }
    }
}

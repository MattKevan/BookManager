import SwiftUI

@main
struct BookManagerApp: App {
    @State private var session = LibrarySession()

    var body: some Scene {
        WindowGroup {
            ContentView(session: session)
        }
        .defaultSize(width: 1_100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Close Library") {
                    session.closeLibrary()
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            }
        }
    }
}

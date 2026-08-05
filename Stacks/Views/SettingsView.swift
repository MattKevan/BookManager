import SwiftUI

/// Standard macOS preferences pane (Settings… / Cmd-,). The Diagnostics
/// section moved here from the toolbar so the window toolbar stays clean.
struct SettingsView: View {
    @Bindable var settings: AppSettings
    @Environment(\.librarySession) private var librarySession

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
            libraryTab
                .tabItem {
                    Label("Library", systemImage: "books.vertical")
                }
            DiagnosticsView()
                .tabItem {
                    Label("Diagnostics", systemImage: "wrench.and.screwdriver")
                }
        }
        .frame(width: 560)
        .frame(minHeight: 460)
    }

    /// Home-library designation: which library is the primary workspace, how
    /// to change it, and how to create a new one. Peer management stays in
    /// the sidebar — this pane is home-only.
    private var libraryTab: some View {
        Form {
            Section("Home Library") {
                LabeledContent("Library", value: librarySession?.home?.name ?? "None")
                if let root = librarySession?.home?.repository.root {
                    LabeledContent("Location", value: root.path)
                }
                Button("Change Home Library…") {
                    librarySession?.present(.changeHome)
                }
                .disabled(librarySession == nil)
                Button("Create New Library…") {
                    librarySession?.createNewLibrary()
                }
                .disabled(librarySession == nil)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Library")
    }

    private var generalTab: some View {
        Form {
            Section {
                Toggle(
                    "Automatically fetch missing metadata on import",
                    isOn: $settings.automaticallyFetchMissingMetadata
                )
                Text("When an imported book is missing authors or tags, Stacks "
                    + "looks it up online and fills in the gaps (high-confidence matches "
                    + "apply silently; ambiguous ones are offered for review).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }
}

import SwiftUI

/// Standard macOS preferences pane (Settings… / Cmd-,). The Diagnostics
/// section moved here from the toolbar so the window toolbar stays clean.
struct SettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
            DiagnosticsView()
                .tabItem {
                    Label("Diagnostics", systemImage: "wrench.and.screwdriver")
                }
        }
        .frame(width: 560)
        .frame(minHeight: 460)
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

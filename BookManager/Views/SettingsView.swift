import SwiftUI

/// Standard macOS preferences pane (Settings… / Cmd-,).
struct SettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Automatically fetch missing metadata on import",
                    isOn: $settings.automaticallyFetchMissingMetadata
                )
                Text("When an imported book is missing authors or tags, Book Manager "
                    + "looks it up online and fills in the gaps (high-confidence matches "
                    + "apply silently; ambiguous ones are offered for review).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .navigationTitle("General")
    }
}

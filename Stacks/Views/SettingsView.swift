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
            sharingTab
                .tabItem {
                    Label("Sharing", systemImage: "network")
                }
            DiagnosticsView()
                .tabItem {
                    Label("Diagnostics", systemImage: "wrench.and.screwdriver")
                }
        }
        .frame(width: 560)
        .frame(minHeight: 460)
    }

    /// Share the open library over the LAN: the in-process server, Bonjour
    /// advertising, and optional basic auth. The server serves the repository
    /// the app already has open — one journal, one writer.
    private var sharingTab: some View {
        Form {
            Section("Share This Library") {
                Toggle("Share on the local network", isOn: shareBinding)
                if settings.shareLibraryOverNetwork {
                    Toggle("Advertise with Bonjour", isOn: $settings.advertiseWithBonjour)
                        .help("Other Stacks clients discover this library automatically")
                    Toggle("Require a password", isOn: $settings.requireSharePassword)
                    if settings.requireSharePassword {
                        TextField("Username", text: $settings.shareUsername)
                            .textFieldStyle(.roundedBorder)
                        SecureField("Password", text: passwordBinding)
                            .textFieldStyle(.roundedBorder)
                    }
                    if let sharing = librarySession?.sharing {
                        if sharing.isSharing {
                            LabeledContent("Address", value: sharing.addressString)
                            Button("Copy Address") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(sharing.addressString, forType: .string)
                            }
                        } else if let error = sharing.lastError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Sharing")
    }

    /// The share toggle owns the server lifecycle: flipping it on starts the
    /// in-process server for the home library, flipping it off stops it.
    private var shareBinding: Binding<Bool> {
        Binding(
            get: { settings.shareLibraryOverNetwork },
            set: { newValue in
                settings.shareLibraryOverNetwork = newValue
                guard let session = librarySession else { return }
                Task { @MainActor in
                    if newValue {
                        guard let home = session.home else {
                            settings.shareLibraryOverNetwork = false
                            session.lastError = "Open a library before sharing it."
                            return
                        }
                        let password = ShareCredentials.load()
                        await session.sharing.start(
                            library: home,
                            advertiseBonjour: settings.advertiseWithBonjour,
                            username: password == nil ? nil : settings.shareUsername,
                            password: password
                        )
                    } else {
                        await session.sharing.stop()
                    }
                }
            }
        )
    }

    /// The password field writes through to the Keychain, never UserDefaults.
    private var passwordBinding: Binding<String> {
        Binding(
            get: { ShareCredentials.load() ?? "" },
            set: {
                if $0.isEmpty {
                    ShareCredentials.delete()
                } else {
                    ShareCredentials.save(password: $0)
                }
            }
        )
    }

    /// Home-library designation: which library is the primary workspace, how
    /// to change it, and how to create a new one. Peer management stays in
    /// the sidebar — this pane is home-only.
    private var libraryTab: some View {
        Form {
            Section("Home Library") {
                LabeledContent("Library", value: librarySession?.home?.name ?? "None")
                if let root = librarySession?.home?.coreRepository.root {
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

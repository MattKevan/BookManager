import StacksCore
import Foundation
import SwiftUI

/// One selectable row in the sidebar: All Books, a library facet category,
/// or a connected device (Finder-style, with eject).
enum SidebarItem: Hashable {
    case allBooks
    case category(FacetType)
    case device(UUID)
}

struct SidebarView: View {
    @Bindable var session: LibrarySession

    /// The facet categories offered in the Library section, in order.
    private let libraryCategories: [FacetType] = [.author, .series, .tag, .format]

    var body: some View {
        List(selection: Binding<SidebarItem?>(
            get: {
                if let id = session.selectedDeviceID {
                    return .device(id)
                }
                // The browser context is the active library: rows map to
                // `.allBooks`/`.category`.
                guard let library = session.activeLibrary else { return .allBooks }
                if let category = library.facetNavigation.category {
                    return .category(category)
                }
                return .allBooks
            },
            set: { item in
                switch item {
                case .allBooks:
                    session.selectCategory(nil)
                case let .category(category):
                    session.selectCategory(category)
                case let .device(id):
                    session.selectDevice(id)
                case nil:
                    break
                }
            }
        )) {
            Section("Library") {
                Label("All Books", systemImage: "books.vertical")
                    .tag(SidebarItem.allBooks)
                ForEach(libraryCategories, id: \.self) { category in
                    Label(category.displayName, systemImage: category.sidebarSymbol)
                        .tag(SidebarItem.category(category))
                }
            }
            if !session.devices.devices.isEmpty {
                Section("Devices") {
                    ForEach(session.devices.devices) { device in
                        HStack(spacing: 6) {
                            Label(device.name, systemImage: "externaldrive")
                            Spacer()
                            Button {
                                Task { await session.devices.eject(device.id) }
                            } label: {
                                Image(systemName: "eject.fill")
                            }
                            .buttonStyle(.borderless)
                            .help("Eject \(device.name)")
                        }
                        .tag(SidebarItem.device(device.id))
                        .contentShape(Rectangle())
                        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                            handleDrop(providers, deviceID: device.id)
                        }
                    }
                }
            }
            SharedLibrariesSection(session: session)
        }
        .listStyle(.sidebar)
    }

    /// LAN libraries advertised over Bonjour, Finder-style: click to connect
    /// (the server is the single writer; edits happen server-side), the
    /// connected one shows an eject.
    private struct SharedLibrariesSection: View {
        @Bindable var session: LibrarySession

        var body: some View {
            let libraries = session.discovery.libraries.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            Section("Shared") {
                if libraries.isEmpty {
                    Text(session.discovery.browseError == nil
                        ? "Browsing for libraries on this network…"
                        : "Local Network access is off")
                        .foregroundStyle(.secondary)
                }
                ForEach(libraries) { library in
                    HStack(spacing: 6) {
                        Label(library.name, systemImage: "network")
                        Spacer()
                        if let browser = session.remoteBrowser, browser.id == library.id {
                            PendingBadge(browser: browser)
                            Button {
                                session.disconnectRemote()
                            } label: {
                                Image(systemName: "eject.fill")
                            }
                            .buttonStyle(.borderless)
                            .help("Disconnect from \(library.name)")
                        } else {
                            Button {
                                Task { await session.connect(to: library) }
                            } label: {
                                Image(systemName: "arrow.down.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Connect to \(library.name)")
                        }
                    }
                    .contentShape(Rectangle())
                }
                if let error = session.discovery.browseError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // Servers that can't advertise (Linux without Avahi, other
                // subnets, containers) connect by typed host:port.
                Button {
                    session.connectToServerPresented = true
                } label: {
                    Label("Connect to Server…", systemImage: "plus.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }
        }
    }

    /// The offline-queue badge on the connected Shared row: how many edits are
    /// queued until the server is reachable again.
    private struct PendingBadge: View {
        let browser: RemoteLibraryBrowser
        @State private var count = 0

        var body: some View {
            Group {
                if count > 0 {
                    Text("\(count) pending")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .task {
                count = await browser.pendingCount()
            }
        }
    }

    /// Finder-style drag: file URLs dropped on a device row are sent to that
    /// device (selecting it first so the send targets the right one).
    private func handleDrop(_ providers: [NSItemProvider], deviceID: UUID) -> Bool {
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                if let url = await LibrarySession.loadURL(from: provider) {
                    urls.append(url)
                }
            }
            guard !urls.isEmpty else { return }
            await session.sendDroppedFiles(urls: urls, to: deviceID)
        }
        return true
    }
}

private struct LibrarySessionKey: EnvironmentKey {
    static let defaultValue: LibrarySession? = nil
}

extension EnvironmentValues {
    var librarySession: LibrarySession? {
        get { self[LibrarySessionKey.self] }
        set { self[LibrarySessionKey.self] = newValue }
    }
}

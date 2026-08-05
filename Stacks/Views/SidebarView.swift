import StacksCore
import Foundation
import SwiftUI

/// One selectable row in the sidebar: All Books, a library facet category, a
/// peer library's sub-section, or a connected device (Finder-style, with
/// eject). Home's rows are `.allBooks`/`.category`; every other open library
/// is a `.library` row carrying its sub-section.
enum LibrarySubsection: Hashable {
    case allBooks
    case category(FacetType)
}

enum SidebarItem: Hashable {
    case allBooks
    case category(FacetType)
    case library(UUID, LibrarySubsection)
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
                // The browser context is the active library: home rows map to
                // `.allBooks`/`.category`, peer rows to `.library(id, sub)`.
                guard let library = session.activeLibrary else { return .allBooks }
                if let category = library.facetNavigation.category {
                    return library === session.home
                        ? .category(category)
                        : .library(library.id, .category(category))
                }
                return library === session.home
                    ? .allBooks
                    : .library(library.id, .allBooks)
            },
            set: { item in
                switch item {
                case .allBooks:
                    session.selectCategory(nil)
                case let .category(category):
                    session.selectCategory(category)
                case let .library(id, subsection):
                    session.selectLibrarySubsection((id, subsection))
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
            if !session.peers.isEmpty || !session.offlinePeers.isEmpty {
                LibraryPeersSection(session: session)
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
        }
        .listStyle(.sidebar)
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

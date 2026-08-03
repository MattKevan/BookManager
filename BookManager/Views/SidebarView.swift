import BookManagerCore
import Foundation
import SwiftUI

/// One selectable row in the sidebar: the all-books entry, a library facet,
/// or a connected device (Finder-style).
enum SidebarItem: Hashable {
    case allBooks
    case facet(LibrarySession.FacetSelection)
    case device(UUID)
}

struct SidebarView: View {
    @Bindable var session: LibrarySession

    var body: some View {
        List(selection: Binding<SidebarItem?>(
            get: {
                if let id = session.selectedDeviceID {
                    return .device(id)
                } else if let facet = session.selectedFacet {
                    return .facet(facet)
                } else {
                    return .allBooks
                }
            },
            set: { item in
                switch item {
                case .allBooks:
                    session.selectDevice(nil)
                    session.selectFacet(nil)
                case let .facet(facet):
                    session.selectDevice(nil)
                    session.selectFacet(facet)
                case let .device(id):
                    session.selectDevice(id)
                case nil:
                    break
                }
            }
        )) {
            if !session.devices.devices.isEmpty {
                Section("Devices") {
                    ForEach(session.devices.devices) { device in
                        Label(device.name, systemImage: "externaldrive")
                            .tag(SidebarItem.device(device.id))
                            .contentShape(Rectangle())
                            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                                handleDrop(providers, deviceID: device.id)
                            }
                    }
                }
            }
            Section {
                Label("All Books", systemImage: "books.vertical")
                    .tag(SidebarItem.allBooks)
            }
            Section("Authors") {
                ForEach(session.authors, id: \.value) { item in
                    FacetRow(title: item.value, count: item.count, type: .author)
                }
            }
            Section("Series") {
                ForEach(session.series, id: \.value) { item in
                    FacetRow(title: item.value, count: item.count, type: .series)
                }
            }
            Section("Tags") {
                ForEach(session.tags, id: \.value) { item in
                    FacetRow(title: item.value, count: item.count, type: .tag)
                }
            }
            Section("Formats") {
                ForEach(session.formats, id: \.value) { item in
                    FacetRow(title: item.value, count: item.count, type: .format)
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
            await session.devices.select(deviceID)
            await session.sendFiles(urls: urls)
        }
        return true
    }

    private struct FacetRow: View {
        let title: String
        let count: Int
        let type: FacetType

        var body: some View {
            HStack {
                Text(title)
                Spacer()
                Text("\(count)")
                    .foregroundStyle(.secondary)
            }
            .tag(SidebarItem.facet(LibrarySession.FacetSelection(type: type, value: title)))
        }
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

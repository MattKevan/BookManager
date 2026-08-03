import BookManagerCore
import SwiftUI

/// Browser for a connected device's books: table with DRM badges, Import
/// Selected/All (through the existing library import pipeline), Refresh, and
/// Eject. `onImported` lets the host flip its import-report sheet after a
/// device import completes.
struct DeviceBooksView: View {
    @Bindable var session: LibrarySession
    @State private var selection = Set<String>() // DeviceBookRecord ids
    var onImported: () -> Void = {}

    var body: some View {
        Group {
            if let error = session.devices.deviceError, session.devices.deviceBooks.isEmpty {
                ContentUnavailableView {
                    Label("Couldn't Read Device", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Scan Again") { Task { await session.devices.scanForDevices() } }
                }
            } else if session.devices.deviceBooks.isEmpty {
                ContentUnavailableView {
                    Label("No Books on Device", systemImage: "books.vertical")
                } description: {
                    Text(
                        session.devices.isListing
                            ? "Reading the device…"
                            : "Send books from your library, or copy them onto the Kindle another way."
                    )
                }
            } else {
                Table(session.devices.deviceBooks, selection: $selection) {
                    TableColumn("Title") { record in
                        HStack(spacing: 6) {
                            if record.isDRM { Image(systemName: "lock").foregroundStyle(.secondary) }
                            Text(record.title)
                            if record.format == "KFX" {
                                Text("unsupported").font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                    TableColumn("Author") { record in Text(record.authors.joined(separator: ", ")) }
                    TableColumn("Format") { record in Text(record.format) }
                    TableColumn("Size") { record in
                        Text(ByteCountFormatter.string(fromByteCount: record.file.size, countStyle: .file))
                    }
                }
            }
        }
        .navigationTitle(session.devices.devices.first { $0.id == session.selectedDeviceID }?.name ?? "Device")
        .toolbar {
            ToolbarItemGroup {
                Button("Import Selected") { importSelected() }
                    .disabled(selection.isEmpty || session.devices.isListing)
                Button("Import All") { importAll() }
                    .disabled(session.devices.deviceBooks.isEmpty)
                Button {
                    if let id = session.selectedDeviceID { Task { await session.devices.refreshBooks() } }
                } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                Button {
                    if let id = session.selectedDeviceID { Task { await session.devices.eject(id) } }
                } label: { Label("Eject", systemImage: "eject") }
            }
        }
    }

    private func importFiles(_ files: [DeviceFile]) {
        Task {
            do {
                let urls = try await session.devices.download(files)
                await session.importFiles(urls: urls)
                onImported()
            } catch {
                session.devices.deviceError = error.localizedDescription
            }
        }
    }

    private func importSelected() {
        let files = session.devices.deviceBooks
            .filter { selection.contains($0.id) }
            .map(\.file)
        importFiles(files)
    }

    private func importAll() {
        importFiles(session.devices.deviceBooks.map(\.file))
    }
}

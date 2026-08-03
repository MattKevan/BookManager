import BookManagerCore
import SwiftUI

/// Browser for a connected device's books: table with DRM badges, Import
/// Selected/All (through the existing library import pipeline), Refresh, and
/// Eject. A status strip along the bottom shows the connection status and the
/// serial activity queue (current operation + queued count). `onImported`
/// lets the host flip its import-report sheet after a device import completes.
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
                            if record.isEnriched && record.isDRM {
                                Image(systemName: "lock").foregroundStyle(.secondary)
                            }
                            Text(record.title)
                            if !record.isEnriched && selection.contains(record.id) {
                                ProgressView()
                                    .controlSize(.small)
                                    .help("Fetching book details…")
                            }
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
        .onChange(of: selection) { _, newSelection in
            // Lazy detail: fetching metadata downloads the file (~24s per book
            // on the Kindle), so enrich only the selected row, never the whole
            // list. The spinner in the row stays until isEnriched flips.
            guard let first = newSelection.first,
                  let record = session.devices.deviceBooks.first(where: { $0.id == first }),
                  !record.isEnriched else { return }
            Task { await session.devices.enrich(record) }
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Import Selected") { importSelected() }
                    .disabled(selection.isEmpty || session.devices.isBusy)
                    .help(
                        selection.isEmpty
                            ? "Select a book on the device to import it into the library"
                            : "Import the selected book(s) into the library"
                    )
                Button("Import All") { importAll() }
                    .disabled(session.devices.deviceBooks.isEmpty || session.devices.isBusy)
                    .help(
                        session.devices.deviceBooks.isEmpty
                            ? "No books on the device to import"
                            : "Import every book on the device into the library"
                    )
                Button {
                    if let id = session.selectedDeviceID { Task { await session.devices.refreshBooks() } }
                } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(session.devices.isBusy)
                Button {
                    if let id = session.selectedDeviceID { Task { await session.devices.eject(id) } }
                } label: { Label("Eject", systemImage: "eject") }
                .disabled(session.devices.isBusy)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Status strip: hidden when idle and connected (no noise). Visible
            // while the queue is busy or a device error is pending.
            if session.devices.isBusy || session.devices.deviceError != nil {
                statusStrip
            }
        }
    }

    // MARK: - Status strip

    private var statusStrip: some View {
        HStack(spacing: 10) {
            connectionStatusView
            if let activity = session.devices.currentActivity {
                Divider()
                activityView(activity)
            }
            if session.devices.pendingCount > 0 {
                Text("+\(session.devices.pendingCount) queued")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var connectionStatusView: some View {
        HStack(spacing: 6) {
            Image(systemName: session.devices.deviceError != nil
                ? "exclamationmark.triangle"
                : "externaldrive")
                .foregroundStyle(session.devices.deviceError != nil ? .orange : .secondary)
            Text(session.devices.connectionStatus)
                .lineLimit(1)
        }
    }

    private func activityView(_ activity: DeviceActivity) -> some View {
        HStack(spacing: 6) {
            if let progress = activity.progress {
                ProgressView(value: progress)
                    .frame(width: 80)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            Text(activity.title)
            if let detail = activity.detail {
                Text(detail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Import

    private func importFiles(_ files: [DeviceFile]) {
        guard !files.isEmpty else { return }
        Task {
            // The download + conversion phases run as ONE queued device
            // operation; the status strip shows "Importing books…" with
            // per-book progress, then "Converting to library format…".
            await session.devices.importBooks(files) { urls in
                await session.importFiles(urls: urls)
            }
            onImported()
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

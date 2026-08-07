import AppKit
import StacksCore
import SwiftUI

/// Diagnostics content, embedded in the Settings ▸ Diagnostics tab (it moved
/// out of the window toolbar). Inspects the ACTIVE library connection (falls
/// back to home when nothing is active, e.g. device mode), so rebuilding or
/// reloading diagnostics always targets the library the user is looking at.
struct DiagnosticsView: View {
    @Environment(\.librarySession) private var session

    /// The connection Diagnostics inspects: the active library, falling back
    /// to home when nothing is active.
    private var connection: LibraryConnection? {
        session?.activeLibrary ?? session?.home
    }

    var body: some View {
        List {
            Section("Library") {
                LabeledContent("Library", value: connection?.coreRepository.root.lastPathComponent ?? "—")
                LabeledContent("Books", value: "\(connection?.books.count ?? 0)")
                if connection?.isRebuilding == true {
                    ProgressView(value: connection?.rebuildProgress ?? 0)
                    Button("Cancel Rebuild") {
                        connection?.cancelRebuild()
                    }
                } else {
                    Button("Rebuild Local Index") {
                        if let connection { Task { await connection.rebuildIndex() } }
                    }
                }
            }
            Section("Missing Format Files") {
                if let connection, connection.missingFiles.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                } else {
                    ForEach(connection?.missingFiles ?? [], id: \.book.id) { entry in
                        HStack {
                            Text(entry.book.title)
                            Spacer()
                            Text(entry.filename).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                Text("\(connection?.journalSeq.description ?? "—")")
                    .monospacedDigit()
            } header: {
                Text("Journal")
            } footer: {
                Text("The append-only operation log is authoritative; the catalog is rebuilt from it.")
            }
            Section("Trash") {
                if let connection, connection.deletedBooks.isEmpty {
                    Text("Empty").foregroundStyle(.secondary)
                } else {
                    ForEach(connection?.deletedBooks ?? [], id: \.id) { book in
                        HStack {
                            Text(book.title)
                            Spacer()
                            Button("Restore") {
                                if let connection { Task { await connection.restore(id: book.id) } }
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .task { if let connection { await connection.reloadDiagnostics() } }
    }
}

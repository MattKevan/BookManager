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
                LabeledContent("Library", value: connection?.repository.root.lastPathComponent ?? "—")
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
                if let connection, connection.quarantinedChanges.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                } else {
                    ForEach(connection?.quarantinedChanges ?? [], id: \.path) { url in
                        Text(url.lastPathComponent).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Quarantined Changes")
            } footer: {
                Text("Undecodable change files, preserved instead of deleted.")
            }
            Section {
                if let connection, let report = connection.reconciliationReport {
                    if report.renamed.isEmpty && report.adopted.isEmpty
                        && report.conflictCopies.isEmpty && report.restoredFromTrash.isEmpty
                        && report.missingFolders.isEmpty && report.errors.isEmpty {
                        Text("Last sync reconciled nothing out of place.")
                            .foregroundStyle(.secondary)
                    } else {
                        if !report.renamed.isEmpty {
                            LabeledContent("Re-pointed folders", value: "\(report.renamed.count)")
                        }
                        if !report.adopted.isEmpty {
                            LabeledContent("Adopted folders", value: "\(report.adopted.count)")
                        }
                        if !report.restoredFromTrash.isEmpty {
                            LabeledContent("Restored from trash", value: "\(report.restoredFromTrash.count)")
                        }
                        if !report.missingFolders.isEmpty {
                            LabeledContent("Missing folders", value: "\(report.missingFolders.count)")
                        }
                        ForEach(report.conflictCopies, id: \.path) { url in
                            LabeledContent("Conflict copy", value: url.lastPathComponent)
                        }
                        ForEach(report.errors, id: \.self) { message in
                            Text(message).foregroundStyle(.red)
                        }
                    }
                } else {
                    Text("No sync has run yet.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Reconciliation")
            } footer: {
                Text("Folders re-pointed to canonical paths after merges; conflicts are forked, never overwritten.")
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

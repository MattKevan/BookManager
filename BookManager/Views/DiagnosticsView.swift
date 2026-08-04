import AppKit
import BookManagerCore
import SwiftUI

/// Diagnostics content, embedded in the Settings ▸ Diagnostics tab (it moved
/// out of the window toolbar). Reads the library session from the environment,
/// which the Settings scene injects.
struct DiagnosticsView: View {
    @Environment(\.librarySession) private var session

    var body: some View {
        List {
            Section("Library") {
                LabeledContent("Library", value: session?.repository?.root.lastPathComponent ?? "—")
                LabeledContent("Books", value: "\(session?.books.count ?? 0)")
                if session?.isRebuilding == true {
                    ProgressView(value: session?.rebuildProgress ?? 0)
                    Button("Cancel Rebuild") {
                        session?.cancelRebuild()
                    }
                } else {
                    Button("Rebuild Local Index") {
                        Task { await session?.rebuildIndex() }
                    }
                }
            }
            Section("Missing Format Files") {
                if let session, session.missingFiles.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                } else {
                    ForEach(session?.missingFiles ?? [], id: \.book.id) { entry in
                        HStack {
                            Text(entry.book.title)
                            Spacer()
                            Text(entry.filename).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                if let session, session.quarantinedChanges.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                } else {
                    ForEach(session?.quarantinedChanges ?? [], id: \.path) { url in
                        Text(url.lastPathComponent).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Quarantined Changes")
            } footer: {
                Text("Undecodable change files, preserved instead of deleted.")
            }
            Section {
                if let session, let report = session.reconciliationReport {
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
                if let session, session.deletedBooks.isEmpty {
                    Text("Empty").foregroundStyle(.secondary)
                } else {
                    ForEach(session?.deletedBooks ?? [], id: \.id) { book in
                        HStack {
                            Text(book.title)
                            Spacer()
                            Button("Restore") {
                                Task { await session?.restore(id: book.id) }
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .task { await session?.reloadDiagnostics() }
    }
}

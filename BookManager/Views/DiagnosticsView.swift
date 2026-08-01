import AppKit
import BookManagerCore
import SwiftUI

struct DiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.librarySession) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Diagnostics")
                .font(.headline)
                .padding()
            List {
                Section("Library") {
                    LabeledContent("Library", value: session?.repository?.root.lastPathComponent ?? "—")
                    LabeledContent("Books", value: "\(session?.books.count ?? 0)")
                    Button("Rebuild Local Index") {
                        Task { await session?.rebuildIndex() }
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
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .padding()
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .task { await session?.reloadDiagnostics() }
    }
}

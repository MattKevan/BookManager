import StacksCore
import SwiftUI

/// Wizard for importing a copy of an existing Calibre library:
/// summary → book selection → resumable import → report.
struct CalibreImportView: View {
    @Bindable var session: LibrarySession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Import from Calibre")
                .font(.headline)
                .padding()

            if let summary = session.calibreSummary {
                header(summary)
                    .padding([.horizontal, .bottom])
            }

            if let report = session.calibreImportReport {
                reportSection(report)
            } else {
                selectionSection
            }

            footer
                .padding()
        }
        .frame(minWidth: 560, minHeight: 460)
        .onDisappear { session.cancelCalibreImport() }
    }

    private var sourceName: String {
        session.calibreSourcePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Calibre library"
    }

    private func header(_ summary: CalibreLibrarySummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Source", value: sourceName)
            if let destination = session.calibreImportTargetName {
                LabeledContent("Destination", value: destination)
            }
            LabeledContent("Schema version", value: "\(summary.userVersion)")
            LabeledContent("Contents", value: "\(summary.bookCount) books · \(summary.formatCount) formats")
            Text("The source library is read-only — a copy is imported.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var selectionSection: some View {
        List {
            Section {
                ForEach(session.calibreBooks, id: \.calibreID) { book in
                    Toggle(isOn: selectedBinding(for: book.calibreID)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(book.title)
                            Text(subtitle(for: book))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                if let destination = session.calibreImportTargetName {
                    Text("Select the books to copy into \(destination).")
                } else {
                    Text("Select the books to copy into this library.")
                }
            }
        }
    }

    private func subtitle(for book: CalibreBookRecord) -> String {
        let authors = book.authors.map(\.name).joined(separator: ", ")
        let formats = book.formats.map(\.format).joined(separator: ", ")
        return "\(authors) · \(formats)"
    }

    private func selectedBinding(for id: Int) -> Binding<Bool> {
        Binding(
            get: { session.calibreSelectedIDs.contains(id) },
            set: { on in
                if on {
                    session.calibreSelectedIDs.insert(id)
                } else {
                    session.calibreSelectedIDs.remove(id)
                }
            }
        )
    }

    private func reportSection(_ report: CalibreImportReport) -> some View {
        List {
            Text(report.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Section("Imported") {
                ForEach(report.imported, id: \.calibreID) { item in
                    statusRow(item, icon: "checkmark.circle", color: .green)
                }
            }
            if !report.duplicates.isEmpty {
                Section("Duplicates (not copied)") {
                    ForEach(report.duplicates, id: \.calibreID) { item in
                        statusRow(item, icon: "exclamationmark.circle", color: .orange)
                    }
                }
            }
            if !report.failed.isEmpty {
                Section("Failed") {
                    ForEach(report.failed, id: \.calibreID) { item in
                        statusRow(item, icon: "xmark.circle", color: .red)
                    }
                }
            }
            if !report.skipped.isEmpty {
                Section("Skipped (already imported)") {
                    ForEach(report.skipped, id: \.calibreID) { item in
                        statusRow(item, icon: "arrow.uturn.backward.circle", color: .secondary)
                    }
                }
            }
        }
    }

    private func statusRow(_ item: CalibreImportItem, icon: String, color: Color) -> some View {
        HStack {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                if item.likelyDuplicateOf != nil {
                    Text("May duplicate an existing book")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if case .failed(let message) = item.status {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                } else if case .duplicate = item.status {
                    Text("Already in library").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if session.calibreImportReport == nil {
                Button("Select All") {
                    session.calibreSelectedIDs = Set(session.calibreBooks.map(\.calibreID))
                }
                .disabled(session.calibreBooks.isEmpty)
                Button("Clear") {
                    session.calibreSelectedIDs = []
                }
                .disabled(session.calibreSelectedIDs.isEmpty)
            }
            Spacer()
            if session.calibreImportInProgress {
                ProgressView(value: session.calibreImportProgress ?? 0)
                    .frame(width: 120)
                if let progress = session.calibreImportProgress {
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            if session.calibreImportReport != nil {
                if let report = session.calibreImportReport, !report.skipped.isEmpty {
                    Button("Re-import Skipped") { session.resetCalibreImportProgress() }
                }
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            } else {
                // Cancel stays enabled while importing: it now actually stops
                // the import (the session owns the task), instead of only
                // dismissing the wizard while books keep being written.
                Button("Cancel") { dismiss() }
                Button("Import") {
                    session.startCalibreImport()
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.calibreSelectedIDs.isEmpty || session.calibreImportInProgress)
            }
        }
    }
}

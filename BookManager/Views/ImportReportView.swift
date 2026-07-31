import BookManagerCore
import SwiftUI

struct ImportReportView: View {
    let report: ImportReport
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Import Complete")
                .font(.headline)
                .padding()
            Text(report.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding([.horizontal, .bottom])
            List {
                Section("Imported") {
                    ForEach(report.imported, id: \.sourceURL) { item in
                        row(item, icon: "checkmark.circle", color: .green)
                    }
                }
                if !report.duplicates.isEmpty {
                    Section("Duplicates (not copied)") {
                        ForEach(report.duplicates, id: \.sourceURL) { item in
                            row(item, icon: "exclamationmark.circle", color: .orange)
                        }
                    }
                }
                if !report.failed.isEmpty {
                    Section("Failed") {
                        ForEach(report.failed, id: \.sourceURL) { item in
                            row(item, icon: "xmark.circle", color: .red)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done") { onClose() }
                    .buttonStyle(.borderedProminent)
                    .padding()
            }
        }
        .frame(minWidth: 480, minHeight: 360)
    }

    private func row(_ item: ImportItem, icon: String, color: Color) -> some View {
        HStack {
            Image(systemName: icon).foregroundStyle(color)
            Text(item.sourceURL.lastPathComponent)
            Spacer()
            if case .duplicate = item.status {
                Text("Already in library").font(.caption).foregroundStyle(.secondary)
            } else if case let .failed(message) = item.status {
                Text(message).font(.caption).foregroundStyle(.secondary)
            } else if item.likelyDuplicateOf != nil {
                // Never merge silently: surface the likely-duplicate hint.
                Text("Possible duplicate of an existing book").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

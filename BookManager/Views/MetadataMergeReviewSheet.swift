import AppKit
import BookManagerCore
import SwiftUI

/// Per-field Keep / Use-fetched review for a fetched metadata candidate. The
/// cover row shows both thumbnails; a field the candidate can't supply has no
/// picker (forced Keep). Pure view — no lookup, no writes; the parent applies
/// the choices.
struct MetadataMergeReviewSheet: View {
    let plan: MetadataMergePlan
    @Binding var choices: [MetadataMergeItem.Field: MetadataMergeChoice]
    let currentCover: NSImage?
    let fetchedCover: NSImage?
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review fetched metadata")
                .font(.headline)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(plan.items) { item in
                        if item.field == .cover {
                            coverRow(item)
                        } else {
                            fieldRow(item)
                        }
                    }
                }
            }
            HStack {
                Text("Use fetched only where you choose — nothing is written until Save.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { onCancel() }
                Button("Apply") { onConfirm() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(minWidth: 420)
    }

    private func fieldRow(_ item: MetadataMergeItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label)
                    .font(.headline)
                    .frame(minWidth: 110, alignment: .leading)
                Text("Current: \(item.currentValue ?? "—")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Fetched: \(item.fetchedValue ?? "—")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if item.fetchedValue == nil {
                Text("Keep")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                choicePicker(item.field)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.3)))
    }

    private func coverRow(_ item: MetadataMergeItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.label)
                    .font(.headline)
                HStack(spacing: 16) {
                    coverThumbnail(currentCover, caption: "Current")
                    coverThumbnail(fetchedCover, caption: "Fetched")
                }
            }
            Spacer()
            if item.fetchedValue == nil {
                Text("Keep")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                choicePicker(item.field)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.3)))
    }

    private func coverThumbnail(_ image: NSImage?, caption: String) -> some View {
        VStack(spacing: 2) {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 90)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                    .frame(width: 60, height: 90)
                    .overlay(Image(systemName: "book.closed").foregroundStyle(.secondary))
            }
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func choicePicker(_ field: MetadataMergeItem.Field) -> some View {
        Picker("", selection: choiceBinding(field)) {
            Text("Keep").tag(MetadataMergeChoice.keep)
            Text("Use fetched").tag(MetadataMergeChoice.useFetched)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 170)
    }

    private func choiceBinding(_ field: MetadataMergeItem.Field) -> Binding<MetadataMergeChoice> {
        Binding(
            get: { choices[field] ?? .keep },
            set: { choices[field] = $0 }
        )
    }
}

import AppKit
import BookManagerCore
import SwiftUI

/// Candidate picker for ambiguous metadata lookups. Each candidate lists the
/// source and a best-effort cover thumbnail; Apply routes the pick back to the
/// session, Skip dismisses without changes.
struct MetadataReviewSheet: View {
    let candidates: [MetadataCandidate]
    let onPick: (MetadataCandidate) -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a match")
                .font(.headline)
            ScrollView {
                ForEach(candidates) { candidate in
                    HStack(spacing: 12) {
                        Thumbnail(url: candidate.coverURL)
                            .frame(width: 48, height: 72)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.title)
                            Text(candidate.authors.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(candidate.sourceName)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button("Apply") {
                            onPick(candidate)
                        }
                    }
                    .padding(6)
                }
            }
            .frame(minHeight: 220)
            HStack {
                Spacer()
                Button("Skip") { onSkip() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(width: 460, height: 320)
    }
}

/// Best-effort cover thumbnail; a failed or missing download shows a
/// placeholder. Never blocks the list.
private struct Thumbnail: View {
    let url: URL?
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                    .overlay(
                        Image(systemName: "book.closed")
                            .foregroundStyle(.secondary)
                    )
            }
        }
        .task {
            guard let url else { return }
            let request = URLRequest(url: url)
            if let data = try? await URLSessionMetadataHTTPClient().data(from: request) {
                guard !Task.isCancelled else { return }
                image = NSImage(data: data)
            }
        }
    }
}

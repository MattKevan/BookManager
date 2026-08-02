import AppKit
import BookManagerCore
import SwiftUI

struct MetadataEditorView: View {
    let book: IndexedBook
    let session: LibrarySession?
    let onSave: (BookEdit, Data?) -> Void
    let onCancel: () -> Void

    @State private var title = ""
    @State private var authorsText = ""
    @State private var series = ""
    @State private var seriesIndex = ""
    @State private var tagsText = ""
    @State private var rating = 0
    @State private var publisher = ""
    @State private var publicationDate: Date?
    @State private var hasPublicationDate = false
    @State private var languagesText = ""
    @State private var identifiersText = ""
    @State private var comments = ""

    // Metadata merge (Fetch Metadata…): candidate pick, then the per-field
    // Keep/Use-fetched review. One sheet whose content switches step — avoids
    // the double-sheet presentation glitch.
    private enum ReviewStep: Identifiable {
        case candidates([MetadataCandidate])
        case merge(plan: MetadataMergePlan, candidate: MetadataCandidate)

        var id: String {
            switch self {
            case .candidates: return "candidates"
            case .merge(let plan, _): return "merge-\(plan.items.map(\.id).joined(separator: ","))"
            }
        }
    }

    @State private var reviewStep: ReviewStep?
    @State private var mergeChoices: [MetadataMergeItem.Field: MetadataMergeChoice] = [:]
    @State private var pendingCoverData: Data?
    @State private var coverPending = false
    @State private var isFetchingMetadata = false
    @State private var currentCoverImage: NSImage?
    @State private var fetchedCoverImage: NSImage?
    @State private var mergeError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Edit Metadata")
                .font(.headline)
                .padding()
            Form {
                TextField("Title", text: $title)
                TextField("Authors (comma separated)", text: $authorsText)
                TextField("Series", text: $series)
                TextField("Series index", text: $seriesIndex)
                TextField("Tags (comma separated)", text: $tagsText)
                Stepper(value: $rating, in: 0...5) {
                    Text("Rating: \(rating == 0 ? "None" : String(repeating: "★", count: rating))")
                }
                TextField("Publisher", text: $publisher)
                Toggle("Publication date", isOn: $hasPublicationDate)
                if hasPublicationDate {
                    DatePicker("Date", selection: Binding(
                        get: { publicationDate ?? .now },
                        set: { publicationDate = $0 }
                    ), displayedComponents: .date)
                }
                TextField("Languages (comma separated)", text: $languagesText)
                TextField("Identifiers (type=value, one per line)", text: $identifiersText, axis: .vertical)
                TextField("Comments", text: $comments, axis: .vertical)
            }
            .formStyle(.grouped)
            .padding()
            HStack {
                Button("Fetch Metadata…") {
                    fetchMetadata()
                }
                .disabled(isFetchingMetadata)
                .help("Fetch metadata and a cover from OpenLibrary / Google Books and review per-field changes before saving")
                Spacer()
                Button("Cancel") { onCancel() }
                Button("Save") {
                    onSave(collectEdit(), pendingCoverData)
                }
                .buttonStyle(.borderedProminent)
                .disabled(coverPending)
                if coverPending {
                    ProgressView()
                        .controlSize(.small)
                        .help("Downloading the chosen cover…")
                }
            }
            .padding()
        }
        .frame(minWidth: 420, minHeight: 480)
        .onAppear(perform: populate)
        .sheet(item: $reviewStep) { step in
            switch step {
            case .candidates(let candidates):
                MetadataReviewSheet(
                    candidates: candidates,
                    onPick: startMerge(with:),
                    onSkip: { reviewStep = nil }
                )
            case .merge(let plan, let candidate):
                MetadataMergeReviewSheet(
                    plan: plan,
                    choices: $mergeChoices,
                    currentCover: currentCoverImage,
                    fetchedCover: fetchedCoverImage,
                    onConfirm: {
                        confirmMerge(plan: plan, candidate: candidate)
                    },
                    onCancel: { reviewStep = nil }
                )
            }
        }
        .alert(
            "Fetch Metadata",
            isPresented: Binding(
                get: { mergeError != nil },
                set: { if !$0 { mergeError = nil } }
            )
        ) {
        } message: {
            Text(mergeError ?? "")
        }
    }

    private func populate() {
        title = book.title
        authorsText = book.authors.joined(separator: ", ")
        series = book.series ?? ""
        seriesIndex = book.seriesIndex.map { String($0) } ?? ""
        tagsText = book.tags.joined(separator: ", ")
        rating = book.rating ?? 0
        publisher = book.publisher ?? ""
        if let date = book.publicationDate {
            hasPublicationDate = true
            publicationDate = date
        }
        languagesText = book.languages.joined(separator: ", ")
        identifiersText = book.identifiers.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n")
        comments = book.comments ?? ""
    }

    private func collectEdit() -> BookEdit {
        let splitList = { (value: String) -> [String] in
            value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        var identifiers: [String: String] = [:]
        for line in identifiersText.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if parts.count == 2 { identifiers[parts[0]] = parts[1] }
        }
        let newSeries = series.trimmingCharacters(in: .whitespacesAndNewlines)
        let seriesEdit: FieldEdit<String> = newSeries.isEmpty ? .clear : .set(newSeries)
        let trimmedIndex = seriesIndex.trimmingCharacters(in: .whitespacesAndNewlines)
        let newIndex = trimmedIndex.isEmpty ? nil : Double(trimmedIndex)
        let indexEdit: FieldEdit<Double> = newSeries.isEmpty ? .clear : (newIndex.map { .set($0) } ?? .clear)
        let ratingEdit: FieldEdit<Int> = rating == 0 ? .clear : .set(rating)
        let publisherEdit: FieldEdit<String> = {
            let value = publisher.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? .clear : .set(value)
        }()
        let dateEdit: FieldEdit<Date> = hasPublicationDate
            ? (publicationDate.map { .set($0) } ?? .clear)
            : .clear
        let commentsEdit: FieldEdit<String> = {
            let value = comments.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? .clear : .set(value)
        }()
        let newTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return BookEdit(
            title: newTitle == book.title ? nil : newTitle,
            authors: splitList(authorsText) == book.authors ? nil : splitList(authorsText),
            series: seriesEdit,
            seriesIndex: indexEdit,
            tags: splitList(tagsText) == book.tags ? nil : splitList(tagsText),
            rating: ratingEdit,
            publisher: publisherEdit,
            publicationDate: dateEdit,
            languages: splitList(languagesText) == book.languages ? nil : splitList(languagesText),
            identifiers: identifiers == book.identifiers ? nil : identifiers,
            comments: commentsEdit
        )
    }

    // MARK: - Fetch Metadata…

    /// Runs the review-first lookup; the result goes to the candidate pick
    /// (never auto-applied — the editor is per-field review by design).
    private func fetchMetadata() {
        guard let session, !isFetchingMetadata else { return }
        isFetchingMetadata = true
        // A fresh flow must not carry a stale cover or error from a previous
        // merge (fetch → merge → cancel → Save would otherwise apply an old
        // pending cover).
        pendingCoverData = nil
        coverPending = false
        mergeError = nil
        Task {
            let candidates = await session.lookupMetadataCandidates(for: book.id)
            isFetchingMetadata = false
            guard !Task.isCancelled else { return }
            if candidates.isEmpty {
                mergeError = session.metadataLookupError ?? "No metadata found."
                return
            }
            reviewStep = .candidates(candidates)
        }
    }

    /// Picking a candidate builds the per-field plan (defaults from the book's
    /// empty fields) and moves to the merge review.
    private func startMerge(with candidate: MetadataCandidate) {
        let plan = MetadataMergePlan.make(book: book, candidate: candidate)
        var choices: [MetadataMergeItem.Field: MetadataMergeChoice] = [:]
        for item in plan.items {
            choices[item.field] = item.defaultChoice
        }
        mergeChoices = choices
        reviewStep = .merge(plan: plan, candidate: candidate)
        loadCoverImages(for: candidate)
    }

    private func loadCoverImages(for candidate: MetadataCandidate) {
        currentCoverImage = nil
        fetchedCoverImage = nil
        let repository = session?.repository
        let book = self.book
        Task {
            let image = await ThumbnailCache.shared.thumbnail(for: book, repository: repository)
            guard !Task.isCancelled else { return }
            currentCoverImage = image
        }
        guard let coverURL = candidate.coverURL else { return }
        Task {
            guard let data = await Self.downloadBounded(coverURL), !Task.isCancelled else { return }
            fetchedCoverImage = NSImage(data: data)
        }
    }

    /// Applies the chosen fields to the editor draft (no writes yet — Save is
    /// the commit point) and keeps a pending cover for Save to apply.
    private func confirmMerge(plan: MetadataMergePlan, candidate: MetadataCandidate) {
        let result = MetadataMergePlan.apply(choices: mergeChoices, book: book, candidate: candidate)
        let use: (MetadataMergeItem.Field) -> Bool = { mergeChoices[$0] == .useFetched }
        if use(.title) {
            title = candidate.title
        }
        if use(.authors) {
            authorsText = candidate.authors.joined(separator: ", ")
        }
        if use(.publisher), let publisher = candidate.publisher {
            self.publisher = publisher
        }
        if use(.publicationDate), let date = candidate.publicationDate {
            hasPublicationDate = true
            publicationDate = date
        }
        if use(.isbn), let isbn = candidate.isbn {
            var identifiers = book.identifiers
            identifiers["isbn"] = isbn
            identifiersText = identifiers.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n")
        }
        if result.coverChosen, let coverURL = candidate.coverURL {
            // Keep Save disabled until the bounded download resolves, so Save
            // can never beat the download and silently drop the chosen cover.
            coverPending = true
            Task {
                if let data = await Self.downloadBounded(coverURL) {
                    pendingCoverData = data
                } else {
                    mergeError = "Cover download failed — the rest was applied to the form."
                }
                coverPending = false
            }
        }
        reviewStep = nil
    }

    /// Best-effort bounded download (10s) for review thumbnails and the
    /// pending cover. Mirrors the session's enrichment download.
    private static func downloadBounded(_ url: URL) async -> Data? {
        let client = URLSessionMetadataHTTPClient()
        let request = URLRequest(url: url)
        do {
            return try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask { try await client.data(from: request) }
                group.addTask {
                    try await Task.sleep(for: .seconds(10))
                    throw CancellationError()
                }
                guard let data = try await group.next() else {
                    throw CancellationError()
                }
                group.cancelAll()
                return data
            }
        } catch {
            return nil
        }
    }
}

import AppKit
import StacksCore
import SwiftUI

/// One queued book's pending edit from the batch metadata editor. `onSave`
/// receives the whole batch; books whose form has no actual changes are
/// omitted (a no-op edit would write an unnecessary change record).
struct MetadataEditResult {
    let book: IndexedBook
    let edit: BookEdit
    let coverData: Data?
}

/// Snapshot of one queued book's form so Prev/Next navigation preserves edits
/// made earlier in the batch. Drafts are kept per book and committed together
/// on Save Changes; the live form state below is the current book's draft.
private struct Draft {
    var title: String
    var authorsText: String
    var series: String
    var seriesIndex: String
    var tagsText: String
    var rating: Int
    var publisher: String
    var publicationDate: Date?
    var hasPublicationDate: Bool
    var languagesText: String
    var identifiersText: String
    var comments: String
    var coverData: Data?

    init(book: IndexedBook) {
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
        } else {
            hasPublicationDate = false
            publicationDate = nil
        }
        languagesText = book.languages.joined(separator: ", ")
        identifiersText = book.identifiers.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n")
        comments = book.comments ?? ""
        coverData = nil
    }

    /// Full snapshot init used when flushing the live form into a draft.
    init(
        title: String,
        authorsText: String,
        series: String,
        seriesIndex: String,
        tagsText: String,
        rating: Int,
        publisher: String,
        publicationDate: Date?,
        hasPublicationDate: Bool,
        languagesText: String,
        identifiersText: String,
        comments: String,
        coverData: Data?
    ) {
        self.title = title
        self.authorsText = authorsText
        self.series = series
        self.seriesIndex = seriesIndex
        self.tagsText = tagsText
        self.rating = rating
        self.publisher = publisher
        self.publicationDate = publicationDate
        self.hasPublicationDate = hasPublicationDate
        self.languagesText = languagesText
        self.identifiersText = identifiersText
        self.comments = comments
        self.coverData = coverData
    }
}

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

struct MetadataEditorView: View {
    /// The batch queue, walked in order (Book 1 of N). Single-book callers
    /// pass a one-element array; the Prev/Next controls only appear when
    /// there is more than one book.
    let books: [IndexedBook]
    let session: LibrarySession?
    let onSave: ([MetadataEditResult]) -> Void
    let onCancel: () -> Void

    // Live form state — the current book's draft.
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

    // Batch navigation: drafts keyed by book id preserve edits across
    // Prev/Next; the index points at the book the live form shows.
    @State private var currentIndex = 0
    @State private var drafts: [UUID: Draft] = [:]

    @State private var reviewStep: ReviewStep?
    @State private var mergeChoices: [MetadataMergeItem.Field: MetadataMergeChoice] = [:]
    @State private var pendingCoverData: Data?
    @State private var coverPending = false
    @State private var coverDownloadTask: Task<Void, Never>?
    @State private var fetchTask: Task<Void, Never>?
    @State private var isFetchingMetadata = false
    @State private var currentCoverImage: NSImage?
    @State private var fetchedCoverImage: NSImage?
    @State private var mergeError: String?

    private var currentBook: IndexedBook { books[currentIndex] }
    private var isBatch: Bool { books.count > 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Edit Metadata")
                    .font(.headline)
                if isBatch {
                    Text("Book \(currentIndex + 1) of \(books.count)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
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
                if isBatch {
                    Button {
                        navigate(by: -1)
                    } label: {
                        Label("Previous", systemImage: "chevron.left")
                    }
                    .disabled(currentIndex == 0)
                    .help("Previous book")

                    Button {
                        navigate(by: 1)
                    } label: {
                        Label("Next", systemImage: "chevron.right")
                    }
                    .disabled(currentIndex == books.count - 1)
                    .help("Next book")
                }
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(isBatch ? "Save Changes" : "Save") {
                    saveAll()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
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
        .onAppear(perform: loadCurrentDraft)
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

}

extension MetadataEditorView {
    // MARK: - Batch navigation

    private func navigate(by delta: Int) {
        commitCurrentDraft()
        // A book switch invalidates the previous book's in-flight work: cancel
        // any fetch/cover download so a late completion can't populate the
        // form (or a pending cover) of the book now on screen.
        fetchTask?.cancel()
        fetchTask = nil
        isFetchingMetadata = false
        coverDownloadTask?.cancel()
        coverDownloadTask = nil
        coverPending = false
        pendingCoverData = nil
        currentIndex = min(max(currentIndex + delta, 0), books.count - 1)
        loadCurrentDraft()
    }

    /// Flushes the live form into the current book's draft (idempotent — Save
    /// filters unchanged books out before committing).
    private func commitCurrentDraft() {
        drafts[currentBook.id] = Draft(
            title: title, authorsText: authorsText, series: series, seriesIndex: seriesIndex,
            tagsText: tagsText, rating: rating, publisher: publisher,
            publicationDate: publicationDate, hasPublicationDate: hasPublicationDate,
            languagesText: languagesText, identifiersText: identifiersText,
            comments: comments, coverData: pendingCoverData
        )
    }

    /// Populates the live form from the current book's draft (or the book
    /// itself on first visit) and clears per-book review state.
    private func loadCurrentDraft() {
        if let draft = drafts[currentBook.id] {
            title = draft.title
            authorsText = draft.authorsText
            series = draft.series
            seriesIndex = draft.seriesIndex
            tagsText = draft.tagsText
            rating = draft.rating
            publisher = draft.publisher
            hasPublicationDate = draft.hasPublicationDate
            publicationDate = draft.publicationDate
            languagesText = draft.languagesText
            identifiersText = draft.identifiersText
            comments = draft.comments
            pendingCoverData = draft.coverData
        } else {
            title = currentBook.title
            authorsText = currentBook.authors.joined(separator: ", ")
            series = currentBook.series ?? ""
            seriesIndex = currentBook.seriesIndex.map { String($0) } ?? ""
            tagsText = currentBook.tags.joined(separator: ", ")
            rating = currentBook.rating ?? 0
            publisher = currentBook.publisher ?? ""
            if let date = currentBook.publicationDate {
                hasPublicationDate = true
                publicationDate = date
            } else {
                hasPublicationDate = false
                publicationDate = nil
            }
            languagesText = currentBook.languages.joined(separator: ", ")
            identifiersText = currentBook.identifiers.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n")
            comments = currentBook.comments ?? ""
            pendingCoverData = nil
        }
        reviewStep = nil
        mergeChoices = [:]
        currentCoverImage = nil
        fetchedCoverImage = nil
        mergeError = nil
    }

    /// Save Changes: flush the current form, then commit every book whose
    /// draft actually differs (empty edits and cover-less books are skipped).
    private func saveAll() {
        commitCurrentDraft()
        var results: [MetadataEditResult] = []
        for book in books {
            guard let draft = drafts[book.id] else { continue }
            let edit = makeEdit(from: draft, for: book)
            if !edit.isEmpty || draft.coverData != nil {
                results.append(MetadataEditResult(book: book, edit: edit, coverData: draft.coverData))
            }
        }
        onSave(results)
    }

    private func makeEdit(from draft: Draft, for book: IndexedBook) -> BookEdit {
        let splitList = { (value: String) -> [String] in
            value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        var identifiers: [String: String] = [:]
        for line in draft.identifiersText.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if parts.count == 2 { identifiers[parts[0]] = parts[1] }
        }
        let newSeries = draft.series.trimmingCharacters(in: .whitespacesAndNewlines)
        let seriesEdit: FieldEdit<String> = newSeries.isEmpty ? .clear : .set(newSeries)
        let trimmedIndex = draft.seriesIndex.trimmingCharacters(in: .whitespacesAndNewlines)
        let newIndex = trimmedIndex.isEmpty ? nil : Double(trimmedIndex)
        let indexEdit: FieldEdit<Double> = newSeries.isEmpty ? .clear : (newIndex.map { .set($0) } ?? .clear)
        let ratingEdit: FieldEdit<Int> = draft.rating == 0 ? .clear : .set(draft.rating)
        let publisherEdit: FieldEdit<String> = {
            let value = draft.publisher.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? .clear : .set(value)
        }()
        let dateEdit: FieldEdit<Date> = draft.hasPublicationDate
            ? (draft.publicationDate.map { .set($0) } ?? .clear)
            : .clear
        let commentsEdit: FieldEdit<String> = {
            let value = draft.comments.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? .clear : .set(value)
        }()
        let newTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return BookEdit(
            title: newTitle == book.title ? nil : newTitle,
            authors: splitList(draft.authorsText) == book.authors ? nil : splitList(draft.authorsText),
            series: seriesEdit,
            seriesIndex: indexEdit,
            tags: splitList(draft.tagsText) == book.tags ? nil : splitList(draft.tagsText),
            rating: ratingEdit,
            publisher: publisherEdit,
            publicationDate: dateEdit,
            languages: splitList(draft.languagesText) == book.languages ? nil : splitList(draft.languagesText),
            identifiers: identifiers == book.identifiers ? nil : identifiers,
            comments: commentsEdit
        )
    }

}

extension MetadataEditorView {
    // MARK: - Fetch Metadata…

    /// Runs the review-first lookup; the result goes to the candidate pick
    /// (never auto-applied — the editor is per-field review by design). The
    /// lookup targets the book the fetch was started on, even if the queue is
    /// later navigated — though the review sheet is modal, so navigation while
    /// it is up is impossible anyway.
    private func fetchMetadata() {
        guard let session, !isFetchingMetadata else { return }
        isFetchingMetadata = true
        let targetBook = currentBook
        // Cancel any in-flight cover download BEFORE the reset: a stale
        // download completing after this point must never repopulate the draft
        // with a cover the user did not choose in the current flow.
        coverDownloadTask?.cancel()
        coverDownloadTask = nil
        // A fresh flow must not carry a stale cover or error from a previous
        // merge (fetch → merge → cancel → Save would otherwise apply an old
        // pending cover).
        pendingCoverData = nil
        coverPending = false
        mergeError = nil
        fetchTask = Task {
            let candidates = await session.lookupMetadataCandidates(for: targetBook.id)
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
        let plan = MetadataMergePlan.make(book: currentBook, candidate: candidate)
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
        let book = currentBook
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
    /// the commit point) and keeps a pending cover for Save to apply. The draft
    /// is populated from `MetadataMergePlan.apply`'s edit (single source of
    /// truth — no hand-mirrored field mapping).
    private func confirmMerge(plan: MetadataMergePlan, candidate: MetadataCandidate) {
        let result = MetadataMergePlan.apply(choices: mergeChoices, book: currentBook, candidate: candidate)
        if let newTitle = result.edit.title {
            title = newTitle
        }
        if let newAuthors = result.edit.authors {
            authorsText = newAuthors.joined(separator: ", ")
        }
        switch result.edit.publisher {
        case .set(let value):
            self.publisher = value
        case .clear:
            self.publisher = ""
        case .keep:
            break
        }
        switch result.edit.publicationDate {
        case .set(let date):
            hasPublicationDate = true
            publicationDate = date
        case .clear:
            hasPublicationDate = false
            publicationDate = nil
        case .keep:
            break
        }
        if let newIdentifiers = result.edit.identifiers {
            identifiersText = newIdentifiers.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n")
        }
        if result.coverChosen, let coverURL = candidate.coverURL {
            // Keep Save disabled until the bounded download resolves, so Save
            // can never beat the download and silently drop the chosen cover.
            coverPending = true
            coverDownloadTask = Task {
                if let data = await Self.downloadBounded(coverURL), !Task.isCancelled {
                    pendingCoverData = data
                } else if !Task.isCancelled {
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

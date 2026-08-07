import AppKit
import StacksCore
import Foundation

// MARK: - Editing, metadata enrichment

extension LibrarySession {
    // MARK: - Editing

    func saveEdit(_ edit: BookEdit, coverData: Data?, for id: UUID) async {
        guard let repository else { return }
        do {
            let updated = try await repository.updateBook(id: id, edit: edit)
            // Best-effort cover: a failure must not undo the metadata save.
            // NOTE: `metadataEditQueue` is deliberately NOT reassigned here — the
            // editor sheet's presentation is owned by its callers (onSave/
            // onCancel set it to nil to dismiss); reassigning it on save would
            // re-present the sheet. The updated book reaches the UI via
            // `refreshAll()` → `session.books`.
            if let coverData {
                do {
                    _ = try await repository.updateCover(coverData: coverData, for: id)
                } catch {
                    lastError = "Metadata saved; cover update failed: \(error.localizedDescription)"
                }
            }
        } catch {
            // The library folder may be unreachable (volume unmounted, cloud
            // folder offline). The offline command queue returns with the
            // network slice; for now the edit fails visibly.
            lastError = error.localizedDescription
        }
        await refreshAll()
    }

    // MARK: - Metadata enrichment

    /// The metadata lookup service, created once (sources: OpenLibrary then
    /// Google Books). Shared by the inspector's fetch and the editor's
    /// review-first fetch.
    private func lookupService() -> MetadataLookupService {
        if let existing = metadataService {
            return existing
        }
        let client = URLSessionMetadataHTTPClient()
        let registry = MetadataRegistry(sources: [
            OpenLibrarySource(client: client, userAgent: Self.metadataUserAgent),
            GoogleBooksSource(client: client, userAgent: Self.metadataUserAgent),
        ])
        let created = MetadataLookupService(registry: registry)
        metadataService = created
        return created
    }

    private func lookupResult(for book: IndexedBook) async throws -> MetadataLookupResult {
        let query = MetadataLookupQuery(
            isbn: book.identifiers["isbn"], title: book.title, authors: book.authors
        )
        return try await lookupService().lookup(query)
    }

    /// Looks up metadata for a book (ISBN-first, then title+author) and either
    /// auto-applies a high-confidence candidate or presents the review sheet.
    func fetchMetadata(for bookID: UUID) async {
        guard let repository, !isFetchingMetadata else { return }
        guard let book = books.first(where: { $0.id == bookID }) else { return }
        metadataLookupError = nil
        isFetchingMetadata = true
        defer { isFetchingMetadata = false }
        do {
            let result = try await lookupResult(for: book)
            if let autoApply = result.autoApply {
                await applyMetadataCandidate(autoApply, for: bookID, auto: true)
            } else if !result.candidates.isEmpty {
                metadataCandidates = result.candidates
                metadataBookID = bookID
                metadataReviewPresented = true
            } else {
                metadataLookupError = "No metadata found."
            }
        } catch {
            metadataLookupError = error.localizedDescription
        }
    }

    /// Enriches the given books when they are missing authors/tags (see
    /// `EnrichmentPolicy`). Sequential — the lookup allows one in-flight
    /// fetch; high-confidence candidates auto-apply, ambiguous ones present
    /// the review sheet.
    func enrichBooksMissingMetadata(_ bookIDs: [UUID]) async {
        for id in bookIDs {
            guard let book = books.first(where: { $0.id == id }),
                  EnrichmentPolicy.needsEnrichment(book) else { continue }
            await fetchMetadata(for: id)
            // A candidate set is presented for the user to review: stop the
            // sweep. The next iteration would clobber `metadataCandidates`
            // (the user only ever sees the last book's), and a later
            // high-confidence hit would auto-apply while the review sheet is
            // still up. The menu action re-runs after the sheet closes.
            if metadataReviewPresented { return }
        }
    }

    /// Library-wide sweep: fetch metadata for every book missing authors or
    /// tags. Menu: Library ▸ Fetch Missing Metadata…
    func enrichAllBooksMissingMetadata() async {
        let missing = books
            .filter { EnrichmentPolicy.needsEnrichment($0) }
            .map(\.id)
        await enrichBooksMissingMetadata(missing)
    }

    /// Returns candidates for the editor's review-first fetch. Never applies —
    /// even a high-confidence candidate comes back as a candidate so the user
    /// can decide per field. Errors surface via `metadataLookupError`.
    func lookupMetadataCandidates(for bookID: UUID) async -> [MetadataCandidate] {
        guard let repository else { return [] }
        guard let book = books.first(where: { $0.id == bookID }) else { return [] }
        do {
            let result = try await lookupResult(for: book)
            if let autoApply = result.autoApply {
                return [autoApply]
            }
            return result.candidates
        } catch {
            metadataLookupError = error.localizedDescription
            return []
        }
    }

    /// Applies a chosen candidate with missing-fields-only semantics — existing
    /// values are never clobbered — and downloads the cover (bounded) when the
    /// book has none. `auto` suppresses the review-sheet cleanup (nothing to
    /// clear on the auto-apply path).
    func applyMetadataCandidate(_ candidate: MetadataCandidate, for bookID: UUID, auto: Bool = false) async {
        defer {
            if !auto {
                metadataCandidates = []
                metadataBookID = nil
                metadataReviewPresented = false
            }
        }
        guard let repository else { return }
        guard let book = books.first(where: { $0.id == bookID }) else { return }

        var edit = BookEdit()
        var changed = false
        if book.title.isEmpty, !candidate.title.isEmpty {
            edit.title = candidate.title
            changed = true
        }
        if book.authors.isEmpty, !candidate.authors.isEmpty {
            edit.authors = candidate.authors
            changed = true
        }
        if book.publisher == nil, let publisher = candidate.publisher, !publisher.isEmpty {
            edit.publisher = .set(publisher)
            changed = true
        }
        if book.publicationDate == nil, let date = candidate.publicationDate {
            edit.publicationDate = .set(date)
            changed = true
        }
        if book.identifiers["isbn"] == nil, let isbn = candidate.isbn {
            edit.identifiers = book.identifiers.merging(["isbn": isbn]) { _, new in new }
            changed = true
        }
        if changed {
            do {
                _ = try await repository.updateBook(id: bookID, edit: edit)
            } catch {
                lastError = error.localizedDescription
            }
        }

        if book.coverHash == nil, let coverURL = candidate.coverURL {
            do {
                let client = URLSessionMetadataHTTPClient()
                let request = URLRequest(url: coverURL)
                let data = try await withThrowingTaskGroup(of: Data.self) { group in
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
                _ = try await repository.updateCover(coverData: data, for: bookID)
            } catch {
                // Best-effort: a cover download failure must not undo the metadata apply.
                metadataLookupError = "Metadata applied; cover download failed."
            }
        }
        await refreshAll()
    }
}

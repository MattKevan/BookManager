import Foundation

/// The repository surface importers and the network ingest path depend on —
/// kept out of `ImportService` so the headless server package (which excludes
/// the Import layer) can compile it.
public protocol LibraryRepositoryImporting: Sendable {
    func bookIDs(byFormatHash contentHash: String) async throws -> [UUID]
    func allBooksForDuplicateCheck() async throws -> [IndexedBook]
    func createBook(
        metadata: NewBookMetadata,
        staged: [BookFolder.StagedFile],
        cover: Data?
    ) async throws -> IndexedBook
}

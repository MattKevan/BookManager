import Foundation

/// Human-readable descriptions for `LibraryRepositoryError` — the raw enum
/// description ("StacksCore.LibraryRepositoryError error 4") was surfaced
/// verbatim in dialogs; every failure now explains itself.
extension LibraryRepositoryError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let version):
            return "This library uses an unsupported format version (\(version))."
        case .missingDependencies(let bookID):
            return "The library is missing changes for a book (\(bookID.uuidString))."
        case .bookNotFound(let bookID):
            return "The requested book (\(bookID.uuidString)) was not found."
        case .rebuildCancelled:
            return "The index rebuild was cancelled."
        case .libraryAlreadyExists:
            return "A library already exists in this folder. Choose a different folder or name."
        }
    }
}

import Foundation

/// A per-field Keep / Use-fetched decision in the metadata merge review.
public enum MetadataMergeChoice: Sendable, Equatable {
    case keep
    case useFetched
}

/// The pure decision model behind the editor's "Fetch Metadata…" review: for
/// each field a candidate can supply, compare the book's current value against
/// the fetched value and default to "use fetched" only when the book's field
/// is empty. `apply` turns the user's choices into a `BookEdit` + cover flag —
/// no network, no view logic (precedent: `GridSelectionSemantics`).
public struct MetadataMergePlan: Sendable, Equatable {
    public struct Item: Identifiable, Sendable, Equatable {
        public enum Field: String, Sendable, Equatable, Hashable {
            case title
            case authors
            case publisher
            case publicationDate
            case isbn
            case cover
        }

        public let field: Field
        public let label: String
        public let currentValue: String?
        public let fetchedValue: String?
        public let defaultChoice: MetadataMergeChoice

        public var id: String { field.rawValue }

        public init(
            field: Field,
            label: String,
            currentValue: String?,
            fetchedValue: String?,
            defaultChoice: MetadataMergeChoice
        ) {
            self.field = field
            self.label = label
            self.currentValue = currentValue
            self.fetchedValue = fetchedValue
            self.defaultChoice = defaultChoice
        }
    }

    public let items: [Item]

    public init(items: [Item]) {
        self.items = items
    }

    // MARK: - Building the plan

    public static func make(
        book: IndexedBook,
        candidate: MetadataCandidate
    ) -> MetadataMergePlan {
        let currentIsbn = book.identifiers["isbn"]
        let coverFetched = candidate.coverURL != nil

        let items: [Item] = [
            Item(
                field: .title,
                label: "Title",
                currentValue: book.title,
                fetchedValue: candidate.title,
                defaultChoice: defaultChoice(current: book.title, fetched: candidate.title)
            ),
            Item(
                field: .authors,
                label: "Authors",
                currentValue: book.authors.isEmpty ? nil : book.authors.joined(separator: ", "),
                fetchedValue: candidate.authors.isEmpty ? nil : candidate.authors.joined(separator: ", "),
                defaultChoice: defaultChoice(
                    current: book.authors.isEmpty ? nil : book.authors.joined(separator: ", "),
                    fetched: candidate.authors.isEmpty ? nil : candidate.authors.joined(separator: ", ")
                )
            ),
            Item(
                field: .publisher,
                label: "Publisher",
                currentValue: book.publisher,
                fetchedValue: candidate.publisher,
                defaultChoice: defaultChoice(current: book.publisher, fetched: candidate.publisher)
            ),
            Item(
                field: .publicationDate,
                label: "Publication Date",
                currentValue: book.publicationDate.map(Self.displayDate),
                fetchedValue: candidate.publicationDate.map(Self.displayDate),
                defaultChoice: defaultChoice(
                    current: book.publicationDate.map(Self.displayDate),
                    fetched: candidate.publicationDate.map(Self.displayDate)
                )
            ),
            Item(
                field: .isbn,
                label: "ISBN",
                currentValue: currentIsbn,
                fetchedValue: candidate.isbn,
                defaultChoice: defaultChoice(current: currentIsbn, fetched: candidate.isbn)
            ),
            Item(
                field: .cover,
                label: "Cover",
                currentValue: book.coverHash == nil ? nil : "Cover present",
                fetchedValue: coverFetched ? "Cover available" : nil,
                defaultChoice: book.coverHash == nil && coverFetched ? .useFetched : .keep
            ),
        ]
        return MetadataMergePlan(items: items)
    }

    private static func defaultChoice(current: String?, fetched: String?) -> MetadataMergeChoice {
        guard let fetched, !fetched.isEmpty else { return .keep }
        if let current, !current.isEmpty { return .keep }
        return .useFetched
    }

    private static func displayDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    // MARK: - Applying the choices

    /// Builds the `BookEdit` for the chosen fields and whether the cover was
    /// chosen. Fields not chosen (or `.keep`) are left as no-ops. "Use
    /// fetched" for a field the candidate can't supply resolves to `.clear`
    /// (publisher/date) or no change (isbn).
    public static func apply(
        choices: [Item.Field: MetadataMergeChoice],
        book: IndexedBook,
        candidate: MetadataCandidate
    ) -> (edit: BookEdit, coverChosen: Bool) {
        let use: (Item.Field) -> Bool = { choices[$0] == .useFetched }

        let publisher: FieldEdit<String>
        if use(.publisher) {
            publisher = candidate.publisher.map(FieldEdit.set) ?? .clear
        } else {
            publisher = .keep
        }

        let publicationDate: FieldEdit<Date>
        if use(.publicationDate) {
            publicationDate = candidate.publicationDate.map(FieldEdit.set) ?? .clear
        } else {
            publicationDate = .keep
        }

        var identifiers: [String: String]?
        if use(.isbn), let isbn = candidate.isbn, !isbn.isEmpty {
            identifiers = book.identifiers
            identifiers?["isbn"] = isbn
        }

        let coverChosen = use(.cover) && candidate.coverURL != nil

        let edit = BookEdit(
            title: use(.title) ? candidate.title : nil,
            authors: use(.authors) ? candidate.authors : nil,
            publisher: publisher,
            publicationDate: publicationDate,
            identifiers: identifiers
        )
        return (edit, coverChosen)
    }
}

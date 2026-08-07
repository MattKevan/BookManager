import Foundation
import Testing
@testable import StacksCore

@Suite
struct EnrichmentPolicyTests {
    private func makeBook(
        authors: [String] = ["An Author"],
        tags: [String] = ["A Tag"]
    ) -> IndexedBook {
        IndexedBook(
            id: UUID(),
            title: "Title",
            authors: authors,
            tags: tags,
            modifiedMilliseconds: 1_000,
            isDeleted: false
        )
    }

    @Test
    func completeBookDoesNotNeedEnrichment() {
        #expect(!EnrichmentPolicy.needsEnrichment(makeBook()))
    }

    @Test
    func emptyAuthorsNeedsEnrichment() {
        #expect(EnrichmentPolicy.needsEnrichment(makeBook(authors: [])))
    }

    @Test
    func placeholderUnknownAuthorNeedsEnrichment() {
        #expect(EnrichmentPolicy.needsEnrichment(makeBook(authors: ["Unknown"])))
        #expect(EnrichmentPolicy.needsEnrichment(makeBook(authors: ["Unknown", "Unknown"])))
    }

    @Test
    func emptyTagsNeedsEnrichment() {
        #expect(EnrichmentPolicy.needsEnrichment(makeBook(tags: [])))
    }

    @Test
    func missingAuthorsWithTagsStillNeedsEnrichment() {
        #expect(EnrichmentPolicy.needsEnrichment(makeBook(authors: [], tags: ["A Tag"])))
    }

    @Test
    func differentlyCasedUnknownIsNotTreatedAsPlaceholder() {
        // Only the exact placeholder counts as missing; a real author whose
        // name is spelled "unknown" is not enriched.
        #expect(!EnrichmentPolicy.needsEnrichment(makeBook(authors: ["unknown"])))
    }
}

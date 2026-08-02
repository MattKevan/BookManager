import Foundation
import Testing
@testable import BookManagerCore

@Suite
struct MetadataLookupServiceTests {
    private actor SourceProbe {
        private(set) var calls: [String] = []
        func record(_ name: String) { calls.append(name) }
        func recorded() -> [String] { calls }
    }

    /// Records calls (for priority/cache assertions) and returns fixed results.
    private final class RecordingSource: MetadataSourceProviding, @unchecked Sendable {
        let name: String
        let results: [MetadataCandidate]
        let probe: SourceProbe?
        init(name: String, results: [MetadataCandidate], probe: SourceProbe? = nil) {
            self.name = name
            self.results = results
            self.probe = probe
        }

        func search(_ query: MetadataLookupQuery) async throws -> [MetadataCandidate] {
            await probe?.record(name)
            return results
        }
    }

    /// A slow source whose only purpose is to sit inside the cancellation window.
    private struct CancellingSource: MetadataSourceProviding {
        let name = "slow"
        func search(_ query: MetadataLookupQuery) async throws -> [MetadataCandidate] {
            try await Task.sleep(for: .seconds(1))
            return []
        }
    }

    private func candidate(
        _ title: String,
        isbn: String? = nil,
        authors: [String] = ["Alice"],
        source: String = "fake"
    ) -> MetadataCandidate {
        MetadataCandidate(
            id: "\(source)-\(title)", title: title, authors: authors,
            publisher: "Riverhead", publicationDate: nil, isbn: isbn,
            coverURL: nil, sourceName: source
        )
    }

    @Test
    func isbnExactAutoApplies() async throws {
        let registry = MetadataRegistry(sources: [
            RecordingSource(name: "a", results: [candidate("Range", isbn: "9780735221291")]),
        ])
        let service = MetadataLookupService(registry: registry)
        let result = try await service.lookup(
            MetadataLookupQuery(isbn: "978-0-7352-2129-1", title: "Range", authors: ["David Epstein"])
        )
        // Hyphenated query ISBN normalizes to the same digits → score 100.
        #expect(result.autoApply?.isbn == "9780735221291")
        #expect(result.candidates.count == 1)
    }

    @Test
    func titleAuthorMatchAutoAppliesWhenUnambiguous() async throws {
        let registry = MetadataRegistry(sources: [
            RecordingSource(name: "a", results: [
                candidate("Range: Why Generalists Triumph in a Specialized World", authors: ["David Epstein"]),
            ]),
        ])
        let service = MetadataLookupService(registry: registry)
        let result = try await service.lookup(
            MetadataLookupQuery(
                isbn: nil,
                title: "Range: Why Generalists Triumph in a Specialized World",
                authors: ["David Epstein"]
            )
        )
        // Exact normalized title + full author overlap → score 100.
        #expect(result.autoApply?.title == "Range: Why Generalists Triumph in a Specialized World")
        #expect(result.candidates.count == 1)
    }

    @Test
    func ambiguousResultsGoToReview() async throws {
        let registry = MetadataRegistry(sources: [
            RecordingSource(name: "a", results: [
                candidate("Range A"), candidate("Range B"),
            ]),
        ])
        let service = MetadataLookupService(registry: registry)
        let result = try await service.lookup(
            MetadataLookupQuery(isbn: nil, title: "Range", authors: ["X"])
        )
        // Neither title matches "Range"; scores tie at 0 → review, no auto-apply.
        #expect(result.autoApply == nil)
        #expect(result.candidates.count == 2)
    }

    @Test
    func firstNonEmptySourceWinsAndLaterSourcesAreNotConsulted() async throws {
        let probe = SourceProbe()
        let registry = MetadataRegistry(sources: [
            RecordingSource(name: "first", results: [candidate("Range")], probe: probe),
            RecordingSource(name: "second", results: [candidate("Other")], probe: probe),
        ])
        let service = MetadataLookupService(registry: registry)
        let result = try await service.lookup(
            MetadataLookupQuery(isbn: nil, title: "Range", authors: ["Alice"])
        )
        #expect(result.candidates.map(\.title) == ["Range"])
        #expect(await probe.recorded() == ["first"])
    }

    @Test
    func emptySourceFallsThroughToNextSource() async throws {
        let probe = SourceProbe()
        let registry = MetadataRegistry(sources: [
            RecordingSource(name: "empty", results: [], probe: probe),
            RecordingSource(name: "full", results: [candidate("Range")], probe: probe),
        ])
        let service = MetadataLookupService(registry: registry)
        let result = try await service.lookup(
            MetadataLookupQuery(isbn: nil, title: "Range", authors: ["Alice"])
        )
        #expect(result.candidates.map(\.title) == ["Range"])
        #expect(await probe.recorded() == ["empty", "full"])
    }

    @Test
    func cacheShortCircuitsSecondLookup() async throws {
        let probe = SourceProbe()
        let registry = MetadataRegistry(sources: [
            RecordingSource(name: "a", results: [candidate("Range")], probe: probe),
        ])
        let service = MetadataLookupService(registry: registry)
        _ = try await service.lookup(MetadataLookupQuery(isbn: nil, title: "Range", authors: ["A"]))
        _ = try await service.lookup(MetadataLookupQuery(isbn: nil, title: "RANGE", authors: ["a"]))
        // Same normalized key → the source is consulted exactly once.
        #expect(await probe.recorded() == ["a"])
    }

    @Test
    func lookupIsCancellable() async throws {
        let registry = MetadataRegistry(sources: [CancellingSource()])
        let service = MetadataLookupService(registry: registry)
        let task = Task { try await service.lookup(MetadataLookupQuery(isbn: nil, title: "T", authors: [])) }
        task.cancel()
        try await Task.sleep(for: .milliseconds(20)) // let the task start
        do {
            _ = try await task.value
            Issue.record("expected cancellation")
        } catch is CancellationError {
            // expected
        }
    }
}

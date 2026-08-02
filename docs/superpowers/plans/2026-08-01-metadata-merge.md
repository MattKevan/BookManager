# Metadata Merge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** extend `MetadataEditorView` with a "Fetch Metadata…" button and a per-field Keep/Use-fetched review (including the cover), merging chosen values into the editor draft so Save commits metadata + cover together. Nothing is written before Save.

**Architecture:** A pure Core `MetadataMergePlan` (build display items with empty-defaults; apply choices → `BookEdit` + cover-chosen flag) — precedent `GridSelectionSemantics`. The editor gains the fetch button, a two-step review (candidate pick → per-field merge sheet), draft population + a pending-cover draft, and an extended `onSave(BookEdit, coverData:)`; `LibrarySession.saveEdit(_:coverData:for:)` applies the cover via `updateCover` after `updateBook` (best-effort; offline path skips covers).

**Tech Stack:** Swift 6.0 (strict concurrency), SwiftUI, Swift Testing, XcodeGen.

## Global Constraints

- macOS 26; Swift 6.0 with `SWIFT_STRICT_CONCURRENCY: complete`; `LibrarySession` is `@MainActor @Observable`.
- **No change-store format change**; the cover applies through the existing `updateCover` (enrichment, merged). `MetadataCandidate`/`MetadataLookupService` untouched.
- **No writes before Save**: the merge only populates the editor draft; Save is the sole commit point.
- Missing-fields semantics move to *user-controlled*: the merge defaults to "use fetched" for empty fields but the user can override any field (including overwriting populated ones) — by design.
- Existing 155-test non-perf suite stays green. **Verification commands MUST use `-skip-testing:BookManagerCoreTests/PerformanceTests`** (slow under load; timeout history).
- Tests: Swift Testing; `-derivedDataPath .build/DerivedData`; run `xcodegen generate --spec project.yml` before building new files; suite-level `-only-testing`.

---

### Task 1: `MetadataMergePlan` (Core, TDD)

**Files:**
- Create: `BookManagerCore/Enrichment/MetadataMergePlan.swift`
- Create: `BookManagerCoreTests/Enrichment/MetadataMergePlanTests.swift`

**Interfaces:**
- Consumes: `IndexedBook`, `MetadataCandidate`, `BookEdit`/`FieldEdit`, date formatting.
- Produces:
  - `MetadataMergeChoice { keep, useFetched }` (Sendable/Equatable).
  - `MetadataMergeItem.Field { title, authors, publisher, publicationDate, isbn, cover }` (String raw values).
  - `MetadataMergeItem: Identifiable, Sendable, Equatable { field, label, currentValue: String?, fetchedValue: String?, defaultChoice }` (`id = field.rawValue`).
  - `MetadataMergePlan: Sendable, Equatable { items: [MetadataMergeItem] }`.
  - `static func make(book: IndexedBook, candidate: MetadataCandidate) -> MetadataMergePlan`.
  - `static func apply(choices: [MetadataMergeItem.Field: MetadataMergeChoice], book: IndexedBook, candidate: MetadataCandidate) -> (edit: BookEdit, coverChosen: Bool)`.

- [ ] **Step 1: Write the failing tests**

Create `BookManagerCoreTests/Enrichment/MetadataMergePlanTests.swift`:

```swift
import Foundation
import Testing
@testable import BookManagerCore

@Suite
struct MetadataMergePlanTests {
    private func book(
        title: String = "Current Title",
        authors: [String] = ["Existing Author"],
        publisher: String? = "Current Press",
        date: Date? = nil,
        identifiers: [String: String] = [:]
    ) -> IndexedBook {
        IndexedBook(
            id: UUID(), title: title, authors: authors,
            publisher: publisher,
            publicationMilliseconds: date.map { Int64($0.timeIntervalSince1970 * 1_000) },
            identifiers: identifiers,
            modifiedMilliseconds: 1_000, isDeleted: false, snapshot: Data([1])
        )
    }

    private func candidate(
        title: String = "Fetched Title",
        authors: [String] = ["Fetched Author"],
        publisher: String? = "Fetched Press",
        date: Date? = nil,
        isbn: String? = "9780735221291",
        coverURL: URL? = nil
    ) -> MetadataCandidate {
        MetadataCandidate(
            id: "test-1", title: title, authors: authors,
            publisher: publisher, publicationDate: date, isbn: isbn,
            coverURL: coverURL, sourceName: "test"
        )
    }

    @Test
    func defaultsUseFetchedForEmptyFieldsOnly() throws {
        let plan = MetadataMergePlan.make(
            book: book(title: "", authors: [], publisher: nil),
            candidate: candidate()
        )
        let byField = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.field, $0.defaultChoice) })
        #expect(byField[.title] == .useFetched)
        #expect(byField[.authors] == .useFetched)
        #expect(byField[.publisher] == .useFetched)
        #expect(byField[.isbn] == .useFetched)
        // A populated book defaults to Keep.
        let full = MetadataMergePlan.make(book: book(), candidate: candidate())
        let fullByField = Dictionary(uniqueKeysWithValues: full.items.map { ($0.field, $0.defaultChoice) })
        #expect(fullByField[.title] == .keep)
        #expect(fullByField[.publisher] == .keep)
    }

    @Test
    func allKeepProducesEmptyEdit() throws {
        let book = book()
        let candidate = candidate()
        let result = MetadataMergePlan.apply(
            choices: [.title: .keep, .authors: .keep, .publisher: .keep,
                      .publicationDate: .keep, .isbn: .keep, .cover: .keep],
            book: book, candidate: candidate
        )
        #expect(result.edit.title == nil)
        #expect(result.edit.authors == nil)
        #expect(result.edit.publisher == .keep)
        #expect(result.edit.publicationDate == .keep)
        #expect(result.edit.identifiers == nil)
        #expect(result.coverChosen == false)
    }

    @Test
    func chosenFieldsFlowIntoTheEdit() throws {
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        let book = book()
        let candidate = candidate(title: "New Title", authors: ["New Author"], publisher: "New Press", date: date)
        let result = MetadataMergePlan.apply(
            choices: [.title: .useFetched, .authors: .useFetched, .publisher: .useFetched,
                      .publicationDate: .useFetched, .isbn: .useFetched, .cover: .useFetched],
            book: book, candidate: candidate
        )
        #expect(result.edit.title == "New Title")
        #expect(result.edit.authors == ["New Author"])
        #expect(result.edit.publisher == .set("New Press"))
        #expect(result.edit.publicationDate == .set(date))
        #expect(result.edit.identifiers?["isbn"] == "9780735221291")
        #expect(result.coverChosen == true)
    }

    @Test
    func isbnMergePreservesExistingIdentifiers() throws {
        let book = book(identifiers: ["google": "abc123"])
        let result = MetadataMergePlan.apply(
            choices: [.isbn: .useFetched],
            book: book, candidate: candidate()
        )
        let ids = result.edit.identifiers ?? [:]
        #expect(ids["isbn"] == "9780735221291")
        #expect(ids["google"] == "abc123")
    }

    @Test
    func coverWithoutURLForcesKeep() throws {
        let plan = MetadataMergePlan.make(book: book(), candidate: candidate(coverURL: nil))
        let cover = plan.items.first { $0.field == .cover }
        #expect(cover?.fetchedValue == nil)
        #expect(cover?.defaultChoice == .keep)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodegen generate --spec project.yml`, then `xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -derivedDataPath .build/DerivedData test -only-testing:BookManagerCoreTests/Enrichment/MetadataMergePlanTests`
Expected: FAIL — `MetadataMergePlan` doesn't exist.

- [ ] **Step 3: Implement `MetadataMergePlan`**

Create `BookManagerCore/Enrichment/MetadataMergePlan.swift`. Key details:
- Display values: title/authors (joined ", ")/publisher as-is; publicationDate via a short date format (e.g., `date.formatted(date: .abbreviated, time: .omitted)`); isbn as-is; cover: currentValue "Cover present"/nil (from `book.coverHash != nil`), fetchedValue nil unless the candidate has a `coverURL` (then "Cover available").
- Defaults: useFetched when the book's field is empty/nil; keep otherwise. Cover: keep unless the candidate has a coverURL.
- `apply(choices:book:candidate:)`: build the `BookEdit` — title when chosen useFetched (candidate.title), authors likewise, publisher `.set(candidate.publisher)` when chosen AND non-nil, publicationDate `.set` when chosen AND non-nil, identifiers: merge `["isbn": candidate.isbn]` over `book.identifiers` when chosen AND candidate.isbn non-nil; all other BookEdit fields `.keep`/nil. `coverChosen` = choice[.cover] == .useFetched && candidate.coverURL != nil.

- [ ] **Step 4: Run the tests to verify they pass, then the non-perf core suite**

Run the focused suite, then `xcodebuild ... test -skip-testing:BookManagerCoreTests/PerformanceTests`. Expected: green (155 + 5).

- [ ] **Step 5: Commit**

```bash
git add BookManagerCore/Enrichment/MetadataMergePlan.swift BookManagerCoreTests/Enrichment/MetadataMergePlanTests.swift
git commit -m "feat: metadata merge plan (per-field keep/use-fetched)"
```

---

### Task 2: Editor fetch + merge review (app)

**Files:**
- Modify: `BookManager/Views/MetadataEditorView.swift`
- Modify: `BookManager/Stores/LibrarySession.swift`
- Modify: `BookManager/Views/ContentView.swift` (the `onSave` call site)
- Create: `BookManager/Views/MetadataMergeReviewSheet.swift`

**Interfaces:**
- Consumes: `MetadataMergePlan` (Task 1), `MetadataLookupService`/candidates (existing), `ThumbnailCache` (current cover), best-effort bounded cover download, `LibraryRepository.updateCover` (existing).
- Produces: `LibrarySession.saveEdit(_:coverData:for:)`, `MetadataEditorView.onSave(BookEdit, Data?)`, `MetadataMergeReviewSheet`.

- [ ] **Step 1: Session — extended `saveEdit`**

In `LibrarySession`, change `saveEdit(_ edit: BookEdit, for id: UUID)` to `saveEdit(_ edit: BookEdit, coverData: Data?, for id: UUID)`:
- Keep the existing flow (read-only guard, `updateBook`, `saveOffline` on failure).
- After a successful `updateBook`: if `coverData != nil` and the repository is available → `try? await repository.updateCover(coverData: coverData!, for: id)`; on failure set `lastError = "Metadata saved; cover update failed: \(error.localizedDescription)"` (best-effort — the metadata save stands). The offline path (`saveOffline`) does NOT take cover data (cover requires the library).
- Update the existing call site in `ContentView` (`.sheet(item: $session.inspectorBook)`) to the new signature: `onSave: { edit, coverData in Task { await session.saveEdit(edit, coverData: coverData, for: book.id) }; session.inspectorBook = nil }`.

- [ ] **Step 2: Editor — fetch button, merge state, draft population**

In `MetadataEditorView`:
- Add a session parameter (or a `fetchCandidates: (UUID) async -> [MetadataCandidate]` closure — prefer passing the session: `let session: LibrarySession?` with a fetch method) — the editor is created in `ContentView` where the session is available; keep the existing `book`/`onSave`/`onCancel`.
- Add state: `@State private var mergeCandidates: [MetadataCandidate] = []`, `@State private var mergePlan: MetadataMergePlan?`, `@State private var mergeChoices: [MetadataMergeItem.Field: MetadataMergeChoice] = [:]`, `@State private var showCandidatePick = false`, `@State private var showMergeReview = false`, `@State private var pendingCoverData: Data?`, `@State private var isFetchingMetadata = false`.
- Add a "Fetch Metadata…" button in the footer (before Cancel): disabled while `isFetchingMetadata`; action: `Task { await fetchAndShowCandidates() }`.
- `fetchAndShowCandidates()`: `isFetchingMetadata = true`; call the session's lookup (reuse the existing service path — expose `LibrarySession.lookupMetadata(for:) async -> [MetadataCandidate]` or reuse `fetchMetadata`'s internals; simplest: a session method returning candidates without applying). Set `mergeCandidates`, `showCandidatePick = true`; reset `isFetchingMetadata`.
- Present the candidate pick (a small sheet listing candidates with title/authors/source; picking sets `mergePlan = MetadataMergePlan.make(book:candidate:)`, `mergeChoices = default choices`, `showMergeReview = true`; Skip closes).
- Present `MetadataMergeReviewSheet(plan:choices:currentCover:onChange:onConfirm:onCancel:)` — per-field rows (label, current value, fetched value, a Keep/Use-fetched picker bound to `mergeChoices`), the cover row with both thumbnails (current via `ThumbnailCache` from the book; fetched via a best-effort download of the candidate coverURL), Confirm/Cancel.
- On Confirm: `let (edit, coverChosen) = MetadataMergePlan.apply(choices:mergeChoices, book:candidate)`, populate the draft — title/authorsText/publisher/publicationDate (set `hasPublicationDate` when a date was chosen)/identifiersText (from the merged identifiers "type=value" lines) — and if `coverChosen && candidate.coverURL != nil` → download (bounded, best-effort) → `pendingCoverData`; close the sheets. The user can still tweak; Save passes `pendingCoverData` via `onSave(collectEdit(), pendingCoverData)`.
- `onSave` signature change: `let onSave: (BookEdit, Data?) -> Void`.

- [ ] **Step 3: `MetadataMergeReviewSheet`**

Create `BookManager/Views/MetadataMergeReviewSheet.swift` — a dumb view: `init(plan: MetadataMergePlan, choices: Binding<[MetadataMergeItem.Field: MetadataMergeChoice]>, currentCover: NSImage?, fetchedCover: NSImage?, onConfirm: () -> Void, onCancel: () -> Void)`; rows via `ForEach(plan.items)` (skip the cover row's picker when `fetchedValue == nil` — forced keep); cover row shows both images side by side; Confirm/Cancel footer. `.frame(minWidth: 420)`.

- [ ] **Step 4: Build and verify wiring**

Run: `xcodegen generate --spec project.yml`, then `xcodebuild ... build` → BUILD SUCCEEDED; non-perf core suite `... test -skip-testing:BookManagerCoreTests/PerformanceTests` → green (160).
Manual residual (human): real lookup from the editor, per-field choices, cover compare, Save commits both. Note in the report.

- [ ] **Step 5: Commit**

```bash
git add BookManager/Views/MetadataEditorView.swift BookManager/Views/MetadataMergeReviewSheet.swift BookManager/Stores/LibrarySession.swift BookManager/Views/ContentView.swift
git commit -m "feat: fetch and per-field merge review in the metadata editor"
```

---

## Self-Review

- **Spec coverage:** Req 1 (editor fetch button) → Task 2; Req 2 (per-field review incl. cover, empty-defaults) → Task 1 (plan) + Task 2 (sheet); Req 3 (draft merge + Save commits, no writes before Save) → Task 2 (draft population, extended `saveEdit`); Req 4 (non-candidate fields untouched) → Task 1 (only the six fields); Req 5 (inspector auto-apply unchanged) → no inspector changes.
- **Placeholder scan:** no TBDs; every step has concrete code or an exact command.
- **Type consistency:** `MetadataMergeChoice`/`MetadataMergeItem`/`MetadataMergePlan.make/apply` defined in Task 1, consumed in Task 2 with matching names; `saveEdit(_:coverData:for:)` defined in Task 2 Step 1, called in Step 2. No name drift.
- **Risks noted:** the editor's `onSave` signature change ripples to ContentView (one call site); the candidate pick reuses the enrichment candidate list (no new lookup code); cover download is best-effort/bounded (matches the enrichment precedent); the offline path ignores covers.

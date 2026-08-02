# Metadata Enrichment — Design

> **Status:** Approved 2026-08-01. The Calibre-adjacent feature after 4c (performance + accessibility, merged `1f77154`).
> **Goal:** fetch missing metadata and covers from OpenLibrary and Google Books — Calibre's metadata-source architecture (a source registry + scoring pipeline) without the plugin loader — applied per-book from the inspector, with high-confidence results auto-applied and ambiguous ones reviewed by the user. Covers download into the existing staged-cover pipeline.

## Verified research basis

- **OpenLibrary** (primary): Book Search (`/search.json`) with `title:`/`author:`/ISBN queries; Covers API (`https://covers.openlibrary.org/b/isbn/<isbn>-M.jpg`); no API key; identified requests (`User-Agent` + contact) get 3 req/s vs 1 req/s; usage rules: cache, batch via search, no bulk harvesting.
- **Google Books** (fallback): `volumes?q=isbn:/intitle:/inauthor:` with `volumeInfo` (title, authors, publisher, publishedDate, categories, imageLinks covers); usable without a key at low volume.
- **Calibre's pipeline**: `identify()` → `get_best()` (score candidates) → `get_covers()` → download, with a priority-ordered source registry + caching. This app adopts the *registry + scoring* (the seams) in-process; no runtime plugin loading (sandbox/MAS constraints — established in the plugin research).
- The app's existing cover pipeline: covers are stored as materialized `cover.jpg` per book folder, hash-checked, with `setCover` in the Automerge document. `BookEdit` (the metadata editor) does NOT include cover — a small `updateCover` repository method is needed for cover downloads.

## Requirements

1. **Source seam**: `MetadataSourceProviding` protocol (name, `search(_:)`, `coverURL(for:)`) + a priority-ordered `MetadataRegistry` (OpenLibrary, Google Books) — new sources are drop-in registrations, not code changes.
2. **Lookup service**: `MetadataLookupService` builds a query from a book (ISBN from identifiers, title, authors), queries sources in priority order (cancellable between sources), scores candidates (ISBN-exact = highest; normalized title+author overlap), caches results per normalized query (in-memory), and returns ranked candidates with provenance.
3. **Apply**: `LibraryRepository.updateCover(coverData:for:)` — writes a `setCover` Automerge change, materializes `cover.jpg` via `BookFolder`, upserts the catalog. Metadata applies through the existing `updateBook`/`BookEdit` path.
4. **UI**: a "Fetch Metadata…" action on the inspector; high-confidence single result → auto-apply (metadata + cover, with a confirmation-free but visible status); ambiguous/weak results → a review sheet listing candidates (title, authors, cover thumbnail, source) to pick or skip. Lookups are cancellable and debounced; failures surface as a status message, never a crash.
5. **Entitlement**: `com.apple.security.network.client` added (sandboxed outbound requests).
6. **No network in tests**: HTTP goes through an injected `MetadataHTTPClient` protocol; unit tests use a stub (no real OpenLibrary/Google Books calls).

## Architecture

### Core (BookManagerCore)

- `MetadataSourceProviding` (protocol, Sendable), `MetadataRegistry` (ordered sources), `MetadataCandidate` (title, authors, publisher, publicationDate?, isbn?, identifiers, coverURL?, sourceName), `MetadataLookupQuery` (isbn?, title, authors), `MetadataLookupService` (actor: query → ranked candidates; caches; cancellable via `Task.isCancelled`).
- `MetadataHTTPClient` (protocol: `data(from: URL) async throws -> Data`) — injected into sources; production impl wraps `URLSession`; tests use a stub. OpenLibrary + Google Books sources take the client + a `User-Agent` string.
- `LibraryRepository.updateCover(coverData:for:)` — cover change + materialize + catalog upsert (mirrors `createBook`'s cover handling).

### BookManager (app)

- Inspector "Fetch Metadata…" button → session method: build query → lookup (cancellable Task) → auto-apply or present the review sheet → apply metadata (`saveEdit`-style) + cover (`updateCover`) → refresh.
- Review sheet: candidate list (cover thumbnail via the candidate's coverURL → download on demand), "Apply"/"Skip".
- Entitlement added to `Config/BookManager.entitlements`.

## Data flow

Book → query → registry (OpenLibrary first, Google Books fallback; cache hit short-circuits) → ranked candidates → score: ISBN-exact auto-applies; else single-strong auto-applies, multiple/weak → review sheet → user choice → metadata via `updateBook` + cover via `updateCover` → catalog/UI refresh. All network calls through `MetadataHTTPClient`; all lookups cancellable; cache keyed by normalized (isbn?, title, first-author).

## Testing

- **Core** (stubbed HTTP): query construction (ISBN vs title/author); source priority; scoring (ISBN-exact > title+author); caching (second lookup short-circuits the stub); cancellation between sources; OpenLibrary/Google Books response decoding (stubbed JSON); `updateCover` round-trip (change written, cover.jpg materialized, catalog updated).
- **App**: build + manual residual — a real lookup against OpenLibrary (the headless session can't be trusted for live network; documented manual step).

## Out of scope

- Batch "fetch metadata for selection" (follow-up; the seam makes it trivial).
- On-disk lookup caching, retry/backoff, source health ranking.
- Editing/removing covers via the metadata editor (only enrichment writes covers).
- Anything beyond OpenLibrary + Google Books as sources.

## Acceptance criteria

- [ ] Fetching metadata for a book with an ISBN auto-applies high-confidence results (metadata + cover) with a visible status.
- [ ] Ambiguous results present a review sheet; picking a candidate applies it; Skip does nothing.
- [ ] A book without ISBN falls back to title+author matching.
- [ ] Covers download through `updateCover` and appear in the grid/inspector.
- [ ] Core suite green (142 + new); no change-store format change; no real network in tests.

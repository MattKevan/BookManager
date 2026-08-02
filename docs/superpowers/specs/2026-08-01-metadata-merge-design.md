# Metadata Merge (Fetch + Per-Field Review in the Editor) — Design

> **Status:** Approved 2026-08-01. Extends metadata enrichment (merged `72de5b1`) with a review-first merge inside `MetadataEditorView`.
> **Goal:** from the metadata edit form, fetch a candidate's metadata + cover and decide **per field** (Keep / Use fetched) before saving — nothing is written until the user hits Save.

## Requirements

1. `MetadataEditorView` gains a **"Fetch Metadata…"** button (beside Save/Cancel).
2. Fetch → candidate selection (reuse the existing candidate list) → a **per-field merge review**:
   - Rows for the fields candidates carry: **title, authors, publisher, publication date, ISBN, cover**.
   - Each row shows **current value vs fetched value** with a **Keep / Use fetched** choice; defaults are *Use fetched* when the current field is empty, *Keep* otherwise — every choice user-overridable.
   - The **cover row** shows the current cover thumbnail vs the fetched thumbnail; "Use fetched" is unavailable when the candidate has no cover.
3. **Confirm merges into the editor's draft** (form state + a pending cover) — the user can still tweak; **Save commits** (metadata via `updateBook`, cover via `updateCover`). No writes before Save.
4. Fields candidates don't carry (series, tags, rating, languages, comments) are untouched by the merge.
5. The inspector's existing auto-apply path stays unchanged; the editor path is always review-first.

## Architecture

### Core (BookManagerCore, pure + tested — precedent: `GridSelectionSemantics`)

`MetadataMergePlan`:

- `MetadataMergeChoice { keep, useFetched }` (Sendable/Equatable).
- `MetadataMergeItem: Identifiable { field: Field (title/authors/publisher/publicationDate/isbn/cover), label, currentValue: String?, fetchedValue: String?, defaultChoice }` (Sendable/Equatable, `id = field.rawValue`).
- `MetadataMergePlan.make(book: IndexedBook, candidate: MetadataCandidate) -> MetadataMergePlan` — builds the display items with empty-defaults (fetched value nil for the cover when the candidate lacks a coverURL; the item then forces Keep).
- `MetadataMergePlan.apply(choices: [Field: MetadataMergeChoice], book: IndexedBook, candidate: MetadataCandidate) -> (edit: BookEdit, coverChosen: Bool)` — the chosen set becomes a `BookEdit` (candidate title/authors/publisher/date when chosen; isbn merged over existing identifiers preserving other keys), plus whether the cover was chosen. No network, no formatting in Core beyond display strings.

### BookManager (app)

- `MetadataEditorView`:
  - "Fetch Metadata…" button → a `fetchMetadata` closure (or the session) returning candidates; the editor presents the existing candidate-pick list, then the new `MetadataMergeReviewSheet` for the chosen candidate.
  - The merge sheet's Confirm maps chosen values into the editor's draft `@State` (title, authorsText, publisher, publication date, identifiersText) + `@State pendingCoverData: Data?` (downloaded best-effort, bounded, when cover chosen).
  - `onSave` signature becomes `(BookEdit, coverData: Data?) -> Void`; Save passes the pending cover.
- `LibrarySession.saveEdit(_:coverData:for:)`: the existing flow plus — after `updateBook` succeeds, if `coverData != nil` → `updateCover` (best-effort: a cover failure sets `lastError`, the metadata save stands; the offline path skips covers).
- `ContentView` call-site updated for the new `onSave` signature.

## Data flow

Editor "Fetch Metadata…" → lookup (existing service) → candidates → pick → `MetadataMergePlan.make` → per-field Keep/Use fetched + cover compare → Confirm → draft fields + pending cover → (user tweaks) → Save → `BookEdit` via `collectEdit` + `updateBook`, cover via `updateCover` → refresh.

## Testing

- **Core** (`MetadataMergePlanTests`): defaults (empty → useFetched, populated → keep); all-keep → empty edit + cover not chosen; title/authors/publisher/date/isbn chosen → correct `BookEdit`; isbn merge preserves existing identifiers; cover item with and without a candidate coverURL; formatting (authors join, date, isbn).
- **App**: build + manual residual (real lookup, per-field interaction, cover compare, Save commits both).

## Out of scope

- Auto-apply from the editor (always review-first here).
- Adding fields to `MetadataCandidate` (series/tags/etc. remain unmergeable until a source provides them).
- On-disk cache, source health, batch fetch.

## Acceptance criteria

- [ ] The edit form's "Fetch Metadata…" fetches, and the review shows current-vs-fetched per field with Keep/Use fetched (defaults per empty/populated), including a cover row.
- [ ] Confirm populates the draft (no writes); Save commits the chosen metadata + cover; unchanged fields are not written.
- [ ] The cover applies via `updateCover` and appears in the grid/inspector.
- [ ] Core suite green (155 + new); no change-store format change.

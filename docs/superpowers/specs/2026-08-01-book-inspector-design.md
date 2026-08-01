# Right Inspector — Design

> **Status:** Approved 2026-08-01. Plan 2 of two (Plan 1 = Calibre data preservation, merged `dfa9945`).
> **Goal:** a right-side inspector panel showing the selected book's cover and full metadata — read-only, with an Edit path into the existing editor sheet — including a collapsible Calibre source-data section that surfaces the payload Plan 1 now preserves.

## Requirements

1. Selecting exactly one book auto-presents the inspector; a toolbar toggle shows/hides it; an empty selection leaves the panel open with a "Select a book" placeholder.
2. The inspector shows: cover, title, authors, series/index, rating, publisher, publication date, added date, languages, tags, identifiers, comments (plain text), and formats (kind + size).
3. A collapsible **Calibre Source Data** section shows, when present: custom-column values with their friendly names (from the preserved `calibre.customColumns` definitions), page count (`"0"` rendered as "unknown"), source UUID, title/author sort keys, original source path, source-modified date, conversion options, and original format names.
4. An "Edit Metadata…" button opens the existing `MetadataEditorView` sheet for the inspected book.
5. No Automerge schema bump: `rawMetadata` is already in the Automerge document; this plan only exposes it through the disposable catalog.

## Architecture

### Catalog (BookManagerCore/Persistence)

`IndexedBook` gains `rawMetadata: [String: String]?` (nullable, JSON-encoded TEXT column `rawMetadata` in the `book` table) via a **v3 GRDB migration**: `DatabaseMigrator.registerMigration("v3RawMetadata")` that drops and recreates the `book` table with the new column — the exact pattern `v2ExpandedBook` already uses (it drops `book` + `bookSearch`; v3 drops only `book`, leaving `bookSearch`/`bookFacet`/`bookFormatHash` untouched). The catalog is a disposable index rebuilt from the change store (`rebuildCatalog` clears and repopulates), so no data migration beyond the schema recreate is needed.

- `LocalCatalog.upsert` stores `book.rawMetadata` (JSON-encoded via `JSONCoding`, nil → NULL) and includes it in the `ON CONFLICT` update.
- `IndexedBook(row:)` decodes it (`(try? JSONCoding.decode([String: String].self, from: row["rawMetadata"] as String?))`).
- `IndexedBook ==` includes `rawMetadata` (the payload is metadata; equality should reflect it).
- `LibraryRepository.makeIndexedBook` fills it from `document.resolvedBook().rawMetadata` (the Automerge field, unchanged).

### Raw presenter (BookManagerCore, pure + tested)

A small value type `CalibreRawRow { label, value }` and a static mapper `CalibreRawPresenter.rows(from rawMetadata: [String: String]) -> [CalibreRawRow]`:

- Parses `calibre.customColumns` (JSON map `label → {name, datatype, isMultiple, display, editable, normalized}`) to resolve friendly names for `calibre.custom.<label>` values (and their `.extra`).
- Adds the scalar keys in a stable order: `calibre.pages` ("0" → "unknown"), `calibre.uuid`, `calibre.titleSort`, `calibre.authorSort`, `calibre.sourcePath`, `calibre.lastModified`, `calibre.conversionOptions` (summarized as "N format(s)"), `calibre.originalFormats` (formatted list).
- Unknown/JSON-decode failures degrade to a row with the raw key, never a crash.

### Inspector (BookManager app)

- `LibrarySession` gains `var inspectorPresented = false` (toolbar binding) and `onChange(of: selection)` — when `selection.count == 1` set `inspectorPresented = true` (auto-show).
- `ContentView` attaches `.inspector(isPresented: $session.inspectorPresented) { BookInspectorView(session: session) }` to the `NavigationSplitView` in `loadedBody` (macOS 26; the inspector is native right-panel).
- Toolbar: a toggle button (SF Symbol `sidebar.trailing`) bound to `inspectorPresented`; keep the existing Edit Metadata button.
- `BookInspectorView`:
  - `body`: cover (async via `ThumbnailCache.shared.thumbnail(for:repository:)`, `AsyncImage`-style with a Task), `Form`/`List` sections: Core Metadata (title, authors, series/index, rating, publisher, dates, languages, tags, identifiers, comments, formats), `DisclosureGroup("Calibre Source Data")` (rows from the presenter, hidden when the payload is empty).
  - Resolves the inspected book from `session.selection.first` + `session.books`; placeholder when nil.
  - "Edit Metadata…" button sets `session.inspectorBook` (existing sheet).

## Data flow

`repository.books()` → `IndexedBook(rawMetadata:)` from the catalog → `BookInspectorView` reads `session.books` for the selected id → cover via `ThumbnailCache`, metadata fields directly, raw section via `CalibreRawPresenter.rows`. No new file I/O, no new repository calls.

## Testing

- **Catalog v3** (mirror `LocalCatalogV2Tests`): a v2-created catalog migrates to v3 and `book` rows decode with `rawMetadata`; `upsert`/`read` round-trips a raw payload (non-nil and nil); equality includes the payload.
- **Presenter** (new `CalibreRawPresenterTests` in Core): friendly custom-column name resolution, `.extra` pairing, pages "0" → "unknown", stable ordering, malformed JSON degrades to raw-key rows.
- **UI**: build + manual verification (auto-show on single selection, toggle, placeholder, raw section content, Edit opens the sheet). UI-test automation remains environmental in this session.

## Out of scope

- Editing inside the inspector (the `MetadataEditorView` sheet stays the edit surface).
- Cover editing/adding.
- Any Automerge schema or change-store change.

## Acceptance criteria

- [ ] Selecting one book in table or grid shows the inspector with cover + metadata; the toolbar toggle hides/shows it; empty selection shows the placeholder.
- [ ] The Calibre Source Data section shows friendly custom-column names and values, pages (0 → "unknown"), and the Plan 1 keys, for a book imported from a Calibre library; it is absent for a non-Calibre book.
- [ ] Edit Metadata… opens the existing editor sheet for the inspected book.
- [ ] Core suite green (91 + new catalog/presenter tests); no Automerge/catalog-schema regression.

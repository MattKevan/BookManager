# Calibre Data Preservation — Design

> **Status:** Approved 2026-08-01. Plan 1 of two (Plan 2 = right inspector; spec follows in a later plan).
> **Goal:** nothing in a Calibre library is silently dropped on import, and modern (schema v27) Calibre libraries import at all.

## Verified research basis

The following was verified against authoritative sources (not inferred from this codebase):

- **kovidgoyal/calibre `resources/metadata_sqlite.sql`** (master) — the DDL Calibre uses to create `metadata.db`; ends with `pragma user_version=27`.
- **janeczku/calibre-web `cps/db.py`** — the tool that produces the non-standard databases (TEXT dates, `series_index` declared as `String`, link-table `extra`).

Key verified facts:

1. The real `books` table is `id, title, sort, timestamp, pubdate, series_index, author_sort, path, uuid, has_cover, last_modified`. There is **no** `flags`, `isbn`, or `lccn` column (ISBN/LCCN live in `identifiers`; the app's test fixture invents those columns — harmless, misleading).
2. `pubdate`/`timestamp` are `TIMESTAMP` columns; calibre-web's SQLAlchemy models store **ISO-8601 TEXT** there (`"2019-05-28 00:00:00+00:00"`, and a `DEFAULT_PUBDATE = datetime(101, 1, 1)` sentinel → `"0101-01-01 00:00:00+00:00"`). This is the root cause of the `could not decode Optional<Double>` crash already fixed in `ca7d83e`; the sentinel is a remaining edge (year 101 must map to nil).
3. Current Calibre creates **user_version 27**. The app's `CalibreSchema26` is pinned to 26 (`supportedUserVersion = 26`) and rejects everything else — modern libraries fail to import entirely.
4. v27 adds a real page-count table `books_pages_link (book, pages, algorithm, format, format_size, timestamp, needs_scan)`. The app's `calibre.pages` read targets a `books.pages` column that does not exist in real libraries — page counts are silently dropped today.
5. `conversion_options (id, format, book, data BLOB)` — per-book conversion settings, never read.
6. `annotations` has `searchable_text` (+ `timestamp REAL`); the app's payload drops both.
7. `custom_columns (id, label, name, datatype, mark_for_delete, editable, display, is_multiple, normalized)` — only `label` + values survive today; the friendly `name`, `datatype`, `display`, `editable`, `is_multiple` are dropped.
8. Multi-value custom-column link tables (`books_custom_column_<id>_link`) carry an `extra` column (e.g. the rating inside a rating+shelves column) — dropped today.
9. calibre-web declares `series_index` as `String`; a calibre-web-created table therefore has TEXT affinity, and the reader's `as Double?` would trap there (real Calibre tables are REAL affinity and coerce).

## Requirements

1. `CalibreReader.open` accepts schema versions 26 **and** 27; anything else still throws `unsupportedSchemaVersion`.
2. Importing a v26 or v27 library preserves, per book, in `rawMetadata` under namespaced keys: `books.uuid`, `books.sort`, `books.author_sort`, `books.last_modified`, `books.path`, page counts from `books_pages_link` (with algorithm/format), `conversion_options` (format → base64), original `data.name`/`data.path` per format, duplicate-type identifier values beyond the first per type, `annotations.searchable_text` + `timestamp`, multi-value link `extra`, and custom-column definitions for columns the book references.
3. The calibre-web date sentinel `"0101-01-01 00:00:00+00:00"` maps to `nil` (no publication date), not year 101.
4. `series_index` decodes from TEXT storage without trapping (calibre-web-created tables).
5. No Automerge schema bump and no catalog migration: `rawMetadata` stays flat `[String: String]`; structured payloads are JSON strings under namespaced keys — the established `calibre.annotations`/`calibre.lastReadPositions` pattern.
6. The existing 87-test core suite keeps passing; the text-date crash fix (`ca7d83e`) is not regressed.

## Architecture

### Reader (BookManagerCore/Calibre)

- Add `CalibreSchema27: CalibreSchemaAdapting` (alongside `CalibreSchema26`). The 26→27 delta is verified against calibre's upgrade path during implementation (expected: `books_pages_link` + triggers); the adapter shares the v26 query set and adds what v27 introduces. `CalibreReader.open` resolves the version and picks the adapter (already the existing pattern via `CalibreSchemaAdapting`).
- New/updated reader surface (version-agnostic where possible, guarded by `columns(in:)`/table existence like the existing `data.path` handling):
  - `fetchPageCounts` → `[(book: Int, pages: Int, algorithm: Int, format: String, formatSize: Int64)]` (empty when the table is absent).
  - `fetchConversionOptions` → `[(book: Int, format: String, data: Data)]` (empty when absent).
  - `fetchCustomValues` extended to also return the link-table `extra` for multi-value columns.
  - `fetchAnnotations` extended with `searchable_text` and `timestamp` keys.
  - `fetchIdentifiers` returns **all** rows (the first-per-type filter moves to the caller, which keeps the first in `identifiers` and stashes the rest).
  - `fetchCustomColumns` returns the full `custom_columns` row (name, datatype, display, editable, is_multiple, normalized).
- `CalibreBookRecord` gains a structured `sourceMetadata` bag (or the reader produces the extra raw keys directly); the mapping to `NewBookMetadata.rawMetadata` lives in `CalibreImportService` so the reader stays a pure reader.
- `date(fromText:)` treats dates before year 1000 as nil (covers the `0101-01-01` sentinel).
- `series_index` reads via a storage-class-tolerant double helper (mirrors `date(fromDatabaseValue:)`).

### Mapping (BookManagerCore/Import + Calibre)

`CalibreImportService` (or a small mapper next to it) assembles the new raw keys:

| Key | Value |
| --- | --- |
| `calibre.uuid` | `books.uuid` |
| `calibre.titleSort` | `books.sort` |
| `calibre.authorSort` | `books.author_sort` |
| `calibre.lastModified` | `books.last_modified` (ISO-8601 string) |
| `calibre.sourcePath` | `books.path` |
| `calibre.pages` | `books_pages_link` pages (preferred when the table exists); falls back to the legacy `books.pages` column read for variant libraries that have it |
| `calibre.conversionOptions` | JSON array `[{format, data(base64)}]` |
| `calibre.originalFormats` | JSON array `[{format, name, path?}]` from `data` |
| `calibre.extraIdentifiers` | JSON object of values beyond the first per type |
| `calibre.annotations` | existing payload extended with `searchable_text`, `timestamp` |
| `calibre.custom.<label>` | existing value capture, plus link-table `extra` where present |
| `calibre.customColumns` | JSON map `label → {name, datatype, isMultiple, display, editable}` for columns the book references |

`CalibreBookRecord`/`CalibreImportService` only add keys; existing keys and semantics are unchanged (books imported before this change keep working — the payload is opaque to the catalog).

### Out of scope (this plan)

- Preserving the original `metadata.opf` bytes (its content maps through the preserved DB fields; source fidelity for unmapped fields like translators is a future option).
- Library-level storage of the custom-column catalog (per-book `calibre.customColumns` keeps libraries portable; a library-level store is a later persistence change).
- The right inspector UI (Plan 2, separate plan; it will surface the now-preserved raw payload).

## Data flow

`CalibreReader.open` (v26/v27) → `summary()`/`books()` produce `CalibreBookRecord`s incl. the new fields → `CalibreImportService.importBooks` maps them into `NewBookMetadata.rawMetadata` → the existing repository pipeline writes the Automerge change + `raw_metadata.json` (no schema/catalog change). Errors keep the current per-book `.failed` semantics; a v27-only table that is missing degrades to an empty fetch, never a crash.

## Testing

- Fixture variants (extend `CalibreFixture`):
  - **v27 library** (`makeVariantLibrary(userVersion: 27, ...)`) with `books_pages_link`, `conversion_options`, and populated new columns — asserts `CalibreReader.open` succeeds and the new keys land.
  - **v26 library** with `books.uuid`/`sort`/`author_sort`/`last_modified`/`path` populated, duplicate identifiers, multi-value link `extra`, annotations `searchable_text` — asserts each key.
  - Existing **text-dates** variant extended with the `0101-01-01 00:00:00+00:00` sentinel (asserts nil) and a TEXT `series_index` (asserts no trap + correct value).
- Regression: the full core suite (87 tests) stays green; the v26 fixture assertions (`mapsFullMetadataMatrix`, etc.) are unchanged.
- The v27 fixture reproduces the current failure first (RED: `open` throws `unsupportedSchemaVersion(27)`), then passes (GREEN).

## Acceptance criteria

- [ ] A v27 library imports (previously rejected) with all books, formats, covers intact.
- [ ] Every key in the table above is present in `raw_metadata.json` for a v26 and a v27 import.
- [ ] A calibre-web-style library (TEXT dates, sentinel pubdate, TEXT `series_index`, link `extra`) imports without crashing, with the sentinel date as nil.
- [ ] Core suite green; no catalog/schema migration required.

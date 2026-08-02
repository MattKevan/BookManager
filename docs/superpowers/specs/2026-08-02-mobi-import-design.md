# MOBI/AZW3 Import → EPUB — Design

> **Status:** Approved 2026-08-02 (license/maintenance review gate passed: libmobi-swift CC0 over LGPL-3.0+ libmobi, self-contained SPM package; MobiVerse dropped — GPLv3 + shells out to Calibre).
> **Goal:** import MOBI, AZW, and AZW3 books as EPUB copies — parse with the vendored libmobi binding, rebuild a clean EPUB, and feed the existing staged-import pipeline so imported Kindle books land in the library exactly like EPUBs.

## Verified research basis

- **`awxkee/libmobi-swift`**: CC0-licensed Swift binding; **vendors the libmobi C sources** as a local `libmobic` C target (`HAVE_CONFIG_H`, `USE_XMLWRITER`, links system `z`) — no system install; API `Mobi(url:)`, `getCover()`, `getRawml()`, `dumpRawml(dst:)`. Maintenance: pushed 2026-02, not archived, small but usable (15 commits, 13 stars — re-verify on integration). The underlying **libmobi C is LGPL v3-or-later** — compliance: attribution notice in the app; personal use unaffected; if ever distributed, the LGPL relinkability obligation applies (documented, not code).
- **MobiVerse**: GPLv3 **and** shells out to bundled/system Calibre — not usable as a library or as a native-pipeline reference. Dropped.
- No Swift package converts EPUB→MOBI (Amazon converts EPUB on Send-to-Kindle; KindleGen dead) — out of scope.
- The app already has: ZIPFoundation, `OpfGenerator`, the staged `ImportService` pipeline, EPUB metadata extraction, cover handling, canonical paths.

## Requirements

1. MOBI, AZW, and AZW3 files are importable via **Add Books** and drop: the picker accepts `.mobi`/`.azw`/`.azw3`; on import the file converts to an EPUB and flows through the existing pipeline (metadata extraction, hashing, canonical folder, cover) — the library stores the EPUB.
2. **`MobiReader`** (Core): parses a MOBI → an extracted-content model: title/authors/cover/metadata (EXTH + rawml) and the chapter HTML markup. Tolerant of missing metadata (defaults), never crashes on malformed files.
3. **`MobiToEpubConverter`** (Core): builds a clean, deterministic EPUB (ZIPFoundation): normalized XHTML chapters from the MOBI rawml, spine + nav, images, cover, and an OPF with the mapped metadata. In-body images are NOT extracted: libmobi rewrites image links to `resourceNNNNN.<ext>` references, so converted EPUBs from illustrated books may carry dangling image references — image extraction is a documented follow-up, not part of this slice. Output is a valid, openable EPUB.
4. **Non-DRM only**: encrypted MOBI files are rejected with a clear "DRM-protected book" error (DRM removal is out of scope).
5. **LGPL compliance note** (docs, not code): libmobi C vendored as-is under LGPL-3.0+; attribution notice added to the app's about/notices.

## Architecture

- **Dependency**: `libmobi-swift` added via SPM (`project.yml` packages + a `BookManagerCore` dependency + `xcodegen generate`). Verify the C target builds inside the app's targets (C is unaffected by Swift strict-concurrency settings).
- **Core** (`BookManagerCore/MobiImport/`):
  - `MobiReader` — wraps the binding: `init(url:) throws` (throws a DRM error for encrypted books, a parse error otherwise), `func extract() throws -> MobiContent` where `MobiContent { title, authors, cover: Data?, chapters: [MobiChapter] }` and `MobiChapter { id, title?, html }`.
  - `MobiToEpubConverter` — `func convert(_ content: MobiContent) throws -> Data` (the EPUB bytes) using ZIPFoundation + an OPF builder (mirror the existing `OpfGenerator` conventions); deterministic (sorted entries, stable ids).
  - `ImportService` gains MOBI handling: when a dropped/picked source has a `.mobi`/`.azw`/`.azw3` extension, convert it to a temp EPUB, then run the existing EPUB import path; the import report notes the original source format.
- **App**: `ContentView`'s Add Books allowed content types gain `.mobi`/`.azw`/`.azw3` (UniformTypeIdentifiers — use `.data` with filename-extension checks, or declare the types); the import report label reflects the converted source.

## Data flow

MOBI file (picker/drop) → `ImportService` detects the extension → `MobiReader.extract()` (DRM check first) → `MobiToEpubConverter.convert()` → temp EPUB → the existing EPUB import pipeline (metadata extraction, staged copy, canonical folder, cover, catalog) → library book (EPUB format).

## Testing

- **Fixtures**: 1–2 small **public-domain** MOBI files committed under `BookManagerCoreTests/MobiImport/Fixtures/` with provenance notes (open test corpora; if none are readily available, the implementer generates one via a one-off writer and documents provenance — the fixture MUST be free to redistribute).
- **Reader** (`MobiReaderTests`): extracts expected metadata/cover/chapter count from a fixture; tolerant of a minimal MOBI (no cover, missing metadata); an encrypted fixture (if obtainable) → DRM error — else the DRM path is covered by an injected stub.
- **Converter** (`MobiToEpubConverterTests`): unzip the produced EPUB; assert the OPF (metadata, spine ids, manifest), the chapter XHTML files exist and contain the expected text, the cover is present, and the archive is deterministic (same input → same bytes).
- **Import end-to-end** (`MobiImportServiceTests`): import a fixture MOBI → the repository has the book with an EPUB format, correct title/authors/cover, and the report notes the MOBI source.
- Full non-perf suite stays green; the perf suite is skipped in verification runs (established convention).

## Out of scope

- EPUB→MOBI export; KFX/AZW4; DRM'd books; a general conversion seam (MOBI→EPUB is a specialized path — a general pipeline/seam only if more formats arrive); in-app reading (Readium is a separate future feature).

## Acceptance criteria

- [ ] A MOBI/AZW/AZW3 file imports through Add Books and becomes a library book with an EPUB format, correct metadata and cover.
- [ ] The produced EPUB is valid (opens in the app's EPUB path; converter tests assert structure).
- [ ] An encrypted MOBI is rejected with a clear DRM error, never a crash.
- [ ] LGPL attribution note added; fixtures are public-domain with provenance.
- [ ] Core suite green (163 + new); no change-store format change.

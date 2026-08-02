# MOBI/AZW3 Import → EPUB Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** import MOBI/AZW/AZW3 books as EPUB copies — parse with the vendored libmobi binding (`libmobi-swift`), rebuild a clean EPUB, and route through the existing staged-import pipeline.

**Architecture:** Add `libmobi-swift` via SPM (vendored C target). Core gains `MobiReader` (binding wrapper → `MobiContent` with DRM rejection) and `MobiToEpubConverter` (ZIPFoundation EPUB builder, deterministic). `ImportService` detects `.mobi`/`.azw`/`.azw3`, converts to a temp EPUB, and runs the existing EPUB import path. The app's Add Books content types gain the three extensions.

**Tech Stack:** Swift 6.0 (strict concurrency), SPM C target (libmobi LGPL-3.0+ via CC0 binding), ZIPFoundation (existing), Swift Testing, XcodeGen.

## Global Constraints

- macOS 26; Swift 6.0 with `SWIFT_STRICT_CONCURRENCY: complete` (C targets are unaffected by Swift concurrency settings).
- **No change-store format change**; the library stores the converted EPUB (source MOBI is consumed).
- **Non-DRM only**: encrypted MOBI → clear error, never a crash.
- Fixtures are public-domain MOBI files with provenance; LGPL attribution note added to the app's notices (docs/attribution, not code).
- Existing 163-test non-perf suite stays green. **Verification commands MUST use `-skip-testing:BookManagerCoreTests/PerformanceTests`** (slow under load; timeout history).
- Tests: Swift Testing; `-derivedDataPath .build/DerivedData`; run `xcodegen generate --spec project.yml` after changing `project.yml` or adding files; suite-level `-only-testing`.

---

### Task 1: Integrate `libmobi-swift` (SPM) + smoke test

**Files:**
- Modify: `project.yml` (add the package + dependency)
- Modify: `BookManagerCore/BookManagerCore.swift` or a new `MobiImport/MobiReader.swift` placeholder (see note)
- Create: `BookManagerCoreTests/MobiImport/MobiSmokeTests.swift`
- Create: `BookManagerCoreTests/MobiImport/Fixtures/` (a small public-domain MOBI)

**Interfaces:**
- Consumes: the `libmobi-swift` package (CC0 binding over vendored LGPL libmobi C).
- Produces: a working SPM dependency + a smoke test proving `Mobi(url:)`/`getRawml()`/`getCover()` parse a fixture.

- [ ] **Step 1: Obtain a public-domain MOBI fixture**

Find or generate one small public-domain MOBI (e.g., from libmobi's test corpus, an open test library, or generated via a one-off writer) and commit it under `BookManagerCoreTests/MobiImport/Fixtures/` with a `README.md` noting provenance and why it's free to redistribute. If no suitable file is obtainable, STOP and report BLOCKED with what was tried (do not commit a copyrighted book).

- [ ] **Step 2: Add the SPM package**

In `project.yml`:
```yaml
packages:
  # ... existing Automerge, GRDB, ZIPFoundation ...
  libmobi-swift:
    url: https://github.com/awxkee/libmobi-swift.git
    from: "1.0.0"
```
(If the package has no tagged releases or `from:` fails, use `revision:` with a known good commit hash.) Add `- package: libmobi-swift` to `BookManagerCore`'s `dependencies`. Run `xcodegen generate --spec project.yml`.

- [ ] **Step 3: Build + smoke test**

Create `BookManagerCoreTests/MobiImport/MobiSmokeTests.swift`:
```swift
import Foundation
import Testing
@testable import BookManagerCore

@Suite
struct MobiSmokeTests {
    @Test
    func parsesFixtureRawmlAndCover() throws {
        let url = try #require(Bundle.module.url(
            forResource: "fixture", withExtension: "mobi",
            subdirectory: "Fixtures"
        ))
        let mobi = try Mobi(url: url)
        let rawml = try mobi.getRawml()
        #expect(!rawml.isEmpty)
        // Cover may be absent in minimal fixtures — assert only when present.
        _ = try? mobi.getCover()
    }
}
```
(If the binding's `Mobi(url:)` is a struct/class in the `libmobi` module, `import libmobi` in the test; if the module name differs from the README, adapt.) Run the focused suite. Verify the C target compiles inside the app's targets (the full `xcodebuild build` must succeed — C code is compiled by clang, unaffected by Swift settings).

- [ ] **Step 4: Verify + commit**

Run: `xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -derivedDataPath .build/DerivedData build` → BUILD SUCCEEDED; the smoke test passes; non-perf suite green (163 + 1). Commit:
```bash
git add project.yml BookManagerCoreTests/MobiImport/ BookManagerCore/
git commit -m "feat: integrate libmobi-swift (MOBI parsing) with fixture smoke test"
```

---

### Task 2: `MobiReader` + content model (Core, TDD)

**Files:**
- Create: `BookManagerCore/MobiImport/MobiReader.swift`
- Create: `BookManagerCoreTests/MobiImport/MobiReaderTests.swift`

**Interfaces:**
- Consumes: the `libmobi` binding (Task 1), the fixture MOBI.
- Produces:
  - `MobiChapter { id: String, title: String?, html: String }` (Sendable/Equatable).
  - `MobiContent { title: String, authors: [String], cover: Data?, chapters: [MobiChapter] }` (Sendable/Equatable).
  - `MobiReader` — `init(url: URL) throws`, `func extract() throws -> MobiContent`; `MobiReaderError { drmProtected, unreadable(String) }` (Equatable) — DRM detection first (encrypted MOBI → `.drmProtected`).

- [ ] **Step 1: Write the failing tests**

`MobiReaderTests` (fixture-driven):
- `extractsMetadataCoverAndChapters` — from the fixture: non-empty title, authors, cover (if present), ≥1 chapter with non-empty html.
- `minimalMobiWithoutCoverOrMetadataDefaults` — a minimal fixture (or a stub-injected content path) with no cover/metadata → defaults (empty title/authors, no cover), no crash.
- `encryptedMobiThrowsDrmError` — if an encrypted fixture is obtainable, assert `.drmProtected`; otherwise cover the DRM branch via a small injectable seam (e.g., a `MobiParsing` protocol the reader uses, with a stub that throws the DRM error) — keep the seam minimal.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodegen generate --spec project.yml` (new files), then `xcodebuild ... test -only-testing:BookManagerCoreTests/MobiImport/MobiReaderTests`. Expected: FAIL — `MobiReader` doesn't exist.

- [ ] **Step 3: Implement `MobiReader`**

Wrap the binding: `init(url:)` opens `Mobi(url:)`; `extract()` calls `getCover()` (best-effort), `getRawml()` (the raw HTML markup), then decomposes the rawml into chapters. Chapter decomposition: the rawml is one HTML document with `<mbp:pagebreak>` (or `<hr>`/headings) separators — split on pagebreak markers, treat `<h1>`/`<h2>` content as the chapter title when present. Tolerate malformed markup (a single chapter containing the whole rawml if no separators). Title/authors come from the rawml `<dc:title>`/`<dc:creator>` metadata block when present, else empty defaults. DRM: the binding's open throws for encrypted files → map to `.drmProtected` (verify the binding's actual error shape on integration; if it can't distinguish DRM from parse errors, check the file's `DRM Offset`/EXTH flags from the raw bytes — libmobi exposes this via the C API; use what the binding exposes).

- [ ] **Step 4: Run the tests to verify they pass, then the non-perf core suite**

Run the focused suite, then `xcodebuild ... test -skip-testing:BookManagerCoreTests/PerformanceTests`. Expected: green (164 + reader tests).

- [ ] **Step 5: Commit**

```bash
git add BookManagerCore/MobiImport/MobiReader.swift BookManagerCoreTests/MobiImport/MobiReaderTests.swift
git commit -m "feat: MOBI reader — extract content model with DRM rejection"
```

---

### Task 3: `MobiToEpubConverter` (Core, TDD)

**Files:**
- Create: `BookManagerCore/MobiImport/MobiToEpubConverter.swift`
- Create: `BookManagerCoreTests/MobiImport/MobiToEpubConverterTests.swift`

**Interfaces:**
- Consumes: `MobiContent` (Task 2), `MobiChapter`, ZIPFoundation, an OPF builder (mirror `OpfGenerator`'s conventions).
- Produces: `MobiToEpubConverter.convert(_ content: MobiContent) throws -> Data` — the EPUB archive bytes, deterministic (same input → same bytes), valid structure.

- [ ] **Step 1: Write the failing tests**

`MobiToEpubConverterTests`:
- `producesValidEpubWithExpectedStructure` — convert a constructed `MobiContent` (2 chapters + cover + metadata); unzip the result (ZIPFoundation `Archive`); assert: `mimetype` is `application/epub+zip`; the OPF (`content.opf` or the app's convention) contains the title/authors, a spine with the chapter ids in order, and a manifest including each chapter + cover; the chapter XHTML files exist and contain the expected text; `cover.jpg` exists when cover data was given.
- `outputIsDeterministic` — converting the same content twice yields identical `Data`.
- `minimalContentProducesOpenableEpub` — a content with one empty-ish chapter still yields a parseable archive.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodegen generate --spec project.yml`, then `xcodebuild ... test -only-testing:BookManagerCoreTests/MobiImport/MobiToEpubConverterTests`. Expected: FAIL — the converter doesn't exist.

- [ ] **Step 3: Implement the converter**

Build the EPUB with ZIPFoundation: `mimetype` (stored, uncompressed, first), `META-INF/container.xml`, `content.opf` (mirror `OpfGenerator`'s metadata/spine/manifest conventions; stable ids `chap1…chapN`, `cover`), `toc.ncx` (or EPUB3 `nav.xhtml` — choose EPUB2 NCX for maximal reader compatibility, matching the app's existing OPF generation), per-chapter XHTML files (wrap the chapter html in a minimal XHTML document), and `cover.jpg` when present. Deterministic: sort manifest entries, use fixed timestamps in the ZIP entries (ZIPFoundation lets you set `date`), stable id order.

- [ ] **Step 4: Run the tests to verify they pass, then the non-perf core suite**

Run the focused suite, then `xcodebuild ... test -skip-testing:BookManagerCoreTests/PerformanceTests`. Expected: green.

- [ ] **Step 5: Commit**

```bash
git add BookManagerCore/MobiImport/MobiToEpubConverter.swift BookManagerCoreTests/MobiImport/MobiToEpubConverterTests.swift
git commit -m "feat: MOBI-to-EPUB converter (deterministic EPUB builder)"
```

---

### Task 4: Import integration + app content types (Core + app)

**Files:**
- Modify: `BookManagerCore/Import/ImportService.swift` (MOBI handling)
- Modify: `BookManager/Views/ContentView.swift` (Add Books content types)
- Create: `BookManagerCoreTests/MobiImport/MobiImportServiceTests.swift`
- Modify: `Config/...` or a notices file (LGPL attribution — check what exists; if none, add `BookManager/Resources/Notices.md`-style or an app-about note — keep it minimal and documented)

**Interfaces:**
- Consumes: `MobiReader`, `MobiToEpubConverter` (Tasks 2–3), the existing `ImportService` EPUB path.
- Produces: `.mobi`/`.azw`/`.azw3` sources import as converted EPUBs; the import report notes the original format.

- [ ] **Step 1: Write the failing end-to-end test**

`MobiImportServiceTests`:
```swift
@Test
func importsMobiAsEpub() async throws {
    let layout = // temp LibraryLayout (mirror ImportServiceTests harness)
    let service = ImportService(layout: layout)
    let repo = MemoryRepository() // or the real repository, per the existing ImportServiceTests pattern
    let mobiURL = try #require(Bundle.module.url(forResource: "fixture", withExtension: "mobi", subdirectory: "Fixtures"))
    let report = try await service.importFiles([mobiURL], into: repo)
    #expect(report.items.first?.status == .imported(...))
    // The created book's format is EPUB, with a non-empty title.
}
```
(Follow the existing `ImportServiceTests` harness — real repository or the existing memory double; pick what exists.)

- [ ] **Step 2: Run it to verify it fails**

Run: `xcodegen generate --spec project.yml`, then `xcodebuild ... test -only-testing:BookManagerCoreTests/MobiImport/MobiImportServiceTests`. Expected: FAIL — MOBI sources aren't handled (the import likely reports an unsupported-format error).

- [ ] **Step 3: Wire ImportService**

In `ImportService.importFiles`: detect a `.mobi`/`.azw`/`.azw3` source extension before the format-dispatch; for those, run `MobiReader.extract()` → `MobiToEpubConverter.convert()` → write the temp EPUB → continue the existing EPUB import path with the temp file (keep the original source path in the report's source label so the UI can show "imported from MOBI"). A DRM error → a clear `.failed("DRM-protected book")` item, never a crash.

- [ ] **Step 4: App content types**

In `ContentView`, Add Books allowed content types: add the three extensions (UniformTypeIdentifiers: use `.data` + a filename-extension pre-check in `ImportService`, or declare custom UTTypes in the app's Info.plist — choose the simplest that makes `.mobi`/`.azw`/`.azw3` selectable in the picker and droppable; `.data` with extension checks is the established app pattern).

- [ ] **Step 5: LGPL attribution**

Add a minimal attribution note (the app has no about view yet — add `BookManager/Resources/Notices.md` or an `ATTRIBUTIONS` constant shown nowhere yet, documented for the future about screen; the note covers libmobi LGPL-3.0+ and the CC0 binding).

- [ ] **Step 6: Build and verify**

Run: `xcodegen generate --spec project.yml` (new test file), `xcodebuild ... build` → BUILD SUCCEEDED; the end-to-end test passes; non-perf core suite green. Manual residual: pick a `.mobi` in Add Books and confirm the book lands as EPUB with metadata/cover.

- [ ] **Step 7: Commit**

```bash
git add BookManagerCore/Import/ImportService.swift BookManager/Views/ContentView.swift BookManagerCoreTests/MobiImport/MobiImportServiceTests.swift BookManager/Resources/Notices.md
git commit -m "feat: MOBI/AZW/AZW3 import as EPUB through the staged pipeline"
```

---

## Self-Review

- **Spec coverage:** Req 1 (importable via Add Books/drop) → Task 4; Req 2 (MobiReader) → Task 2; Req 3 (converter) → Task 3; Req 4 (DRM rejection) → Task 2 + Task 4 error mapping; Req 5 (LGPL note) → Task 4 Step 5.
- **Placeholder scan:** no TBDs; Task 1 Step 1's fixture BLOCKED instruction is explicit guidance (no copyrighted fixtures), and the DRM-detection seam note is guidance, not a placeholder.
- **Type consistency:** `MobiContent`/`MobiChapter`/`MobiReader`/`MobiReaderError` defined in Task 2, consumed in Tasks 3–4; `MobiToEpubConverter` defined in Task 3, consumed in Task 4; `MobiReader`/converter used by `ImportService` (Task 4) with matching names. No name drift.
- **Risks noted:** the C target's build inside the app (Task 1 gate); the binding's exact API/error shape may differ from the README (adapt on integration, documented); fixture availability (public-domain MOBI — BLOCKED protocol); DRM detection depends on what the binding exposes (EXTH DRM flags via the C API fallback); EPUB version choice (EPUB2 NCX for compatibility, matching the existing OPF conventions).

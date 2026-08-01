# Performance & Accessibility (Slice 4c) — Design

> **Status:** Approved 2026-08-01. Two plans executed in sequence: **Plan A (performance)** then **Plan B (accessibility)**; metadata enrichment follows as a separate slice (research done).
> **Goal:** the app stays responsive at 10,000 books (browsing, search, facets, rebuild, reconciliation) with a cancellable, progress-reporting rebuild, and satisfies the defined keyboard + VoiceOver flows (acceptance criterion 12).

## Verified context

- The catalog (`LocalCatalog`) is a disposable local SQLite index (Application Support), rebuilt from the Automerge change store. `upsert` writes one book per `database.write` transaction (book row + FTS5 + facets + hashes) — `rebuildCatalog`/`SyncEngine.ingest` run 10k per-book transactions today.
- `FolderReconciler` discovery scans the library root per book with a missing canonical folder (O(N×dirs)); content-hash checks already run only on divergent paths.
- The original slice list: browsing/sorting responsive at 10,000 generated books; search < 250 ms under normal test conditions; streaming imports; catalogue rebuild reports progress and is cancellable. Acceptance 12: keyboard + VoiceOver flows.
- 4b deferred: reconciler O(N×dirs) discovery → dedicated perf work (this slice).
- Core suite baseline: 131 tests / 25 suites (main `6ff71ef`).

## Requirements (Plan A — performance)

1. **Batch catalog writes.** `LocalCatalog.upsertBatch(_ books: [IndexedBook])` — N upserts in one SQLite transaction; `rebuildCatalog` and `SyncEngine.ingest` use it (10k transactions → 1).
2. **Reconciler folder index.** Build a short-ID → folder-URL map from ONE root scan per reconcile pass; per-book discovery is a lookup, not an enumeration (O(N×dirs) → O(N + dirs)). Behavior unchanged (existing reconciler tests stay green).
3. **Cancellable, progress-reporting rebuild.** `rebuildCatalog(progress:cancelled:)` — a `Double` progress callback (0…1) and a cancellation check between books; the Diagnostics rebuild flow shows progress and a Cancel button.
4. **10k benchmark suite.** `PerformanceTests` seeds the catalog with 10,000 books (directly — no folder materialization; the targets are catalog queries) and asserts generous CI-safe bounds: `allBooks` < 1s, `search` < 250ms, `facetCounts` < 1s, steady-state reconcile per-pass completes (folder-index path) at 10k. Rebuild end-to-end time is measured, not strictly asserted (documented manual measurement).

## Requirements (Plan B — accessibility)

1. **Cover grid accessibility.** Tiles expose `.accessibilityLabel(book.title)`, a hint, and actions (select/open); keyboard navigation (arrow keys move selection, Return opens, Delete trashes) via `.focusable()`/`.onKeyPress` — the grid is usable without a mouse (the table already has native keyboard/VoiceOver).
2. **Toolbar/icon audit.** Every icon-only button exposes a readable label (VoiceOver), incl. when the toolbar renders icon-only.
3. **Keyboard shortcuts audit.** Create/open/close exist (Cmd-N/O/W); add cheap missing ones (Cmd-F search focus, Cmd-E edit) where they don't collide.
4. **VoiceOver manual pass** (headless residual) — with any pure label-construction logic unit-tested.

## Out of scope

- Streaming-import memory profiling at scale (the Calibre import already iterates records; a follow-up if a real 10k Calibre library shows pressure).
- Anything beyond the reconciliation/catalog hot paths for perf; deep VoiceOver automation (manual pass).

## Acceptance criteria

- [ ] 10k-book catalog: `allBooks` < 1s, `search` < 250ms, `facetCounts` < 1s (CI-safe bounds in `PerformanceTests`).
- [ ] Rebuild of 10k books completes via one transaction batch; progress is reported monotonically and Cancel stops it.
- [ ] Reconciler discovery at 10k books is O(N + dirs) per pass (folder index).
- [ ] Cover grid is keyboard-navigable and VoiceOver-announces each tile; icon buttons announce labels; new shortcuts work.
- [ ] Core suite green (131 + new); no change-store format change; nothing silently deleted.

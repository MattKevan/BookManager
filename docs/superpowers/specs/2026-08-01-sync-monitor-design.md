# Sync Monitor & Reconciliation (Slice 4b) — Design

> **Status:** Approved 2026-08-01 (fork-never-overwrite conflict policy + basic trash-restore scope confirmed). Continues Slice 4a (multi-Mac sync core, merged `9246c74`).
> **Goal:** the library converges *continuously* — an always-on monitor ingests changes made by other Macs and reconciles the on-disk book folders to the merged CRDT metadata, with conflicts forked (never silently overwritten) and surfaced in diagnostics.

## Verified context (from 4a)

- 4a delivered: `SyncEngine` (fingerprint-diffed, idempotent ingest with snapshot-seeded documents + full-rebuild fallback, corrupt-vs-stuck quarantine discriminator, outbox drain, `fullRescan`), `SyncState`/`Outbox` (per-library), `LibraryRootCapabilities` (local/network/ubiquitous probe + `ensureDownloaded`), read-only-when-offline session wiring, quarantine-in-diagnostics, 119 tests / 23 suites.
- The change store is append-only, content-addressed (`.amchange`, unique filenames) — cloud-sync-safe by construction. The catalog (Application Support) is disposable and rebuilds from changes. Canonical book paths are *derived* from merged metadata (`f(title, authors)`) — so path convergence is a reconcile pass, not a CRDT field.
- 4a's out-of-scope list and deferred items route here: always-on monitor (FSEvents where reliable, periodic scans on network/cloud), folder/file reconciliation (canonical-path re-pointing, duplicate folders, same-name-different-content forking, trash/restore reconcile), ingest-on-open, `fullRescan` as the periodic backstop, and the parked stuck-valid-change regression test (final-review ruling: the scenario is reachable — crash between sequential writes, or cloud delivery presenting c2 before c1 — and must be locked by a test).
- Concurrency model (approved in 4a): metadata CRDT-convergent; folder moves last-writer-wins by HLC; file-content conflicts **fork, never overwrite** ("merge what you can, fork what you can't").

## Requirements (Slice 4b)

1. **Always-on Sync Monitor.** While a library is open, the app watches the library root, debounces bursts, and runs ingest + reconciliation on change. On network/cloud roots (probe: network mount or ubiquitous), FSEvents is unreliable → **periodic full reconciliation scans** (every ~60s + on app activation) are the primary correctness mechanism. The monitor pauses while the library is unavailable (read-only state).
2. **Ingest-on-open.** Opening a library runs one ingest + reconcile immediately (a mid-session library switch must not show stale data until Sync Now).
3. **Folder reconciliation.** After ingest, every catalog book's on-disk folder is re-pointed to its merged canonical path via journaled rename; canonical-path races adopt-or-fork; file-content conflicts fork to `<name> (conflict).<ext>`; missing folders stay surfaced in diagnostics (never fabricated); basic trash/restore reconciliation.
4. **Conflict visibility.** Every fork/adoption/rename is recorded in a reconciliation report and surfaced in Diagnostics alongside the existing quarantined-changes section.
5. **Regression lock.** The out-of-order-delivery protection (valid change awaiting a missing causal dependency is NOT quarantined and applies once its base arrives) gets the test 4a's final review mandated.
6. **No silent data loss, no change-store format change.** Reconciliation only moves/forks files; it never deletes book content or rewrites `.amchange` files.

## Architecture

### Core (BookManagerCore)

- **`FolderReconciler`** (actor): the reconciliation engine.
  - `reconcile() async throws -> ReconciliationReport` where `ReconciliationReport { renamed: [UUID], adopted: [UUID], conflictCopies: [URL], restoredFromTrash: [UUID], missingFolders: [UUID] }`.
  - Per non-deleted catalog book: expected path from `CanonicalPathBuilder.relativeDirectory(bookID, title, authors)`; compare to `book.relativePath`:
    - **Re-point**: expected ≠ actual → journaled `BookFolder.rename` (oldFormats/newFormats from the catalog's format records).
    - **Adopt-or-fork race**: expected folder also exists on disk → compare the format files' hashes against the catalog's expected content hashes; if they match, adopt (catalog → expected; the old folder is renamed to a `(conflict)` sibling — never deleted); if they don't match, keep the expected folder as the canonical one and fork the old folder to a `(conflict)` sibling, recording it.
    - **Missing**: neither actual nor expected folder exists → record in `missingFolders` (the existing missing-file diagnostics already surface this; nothing is fabricated).
  - Per deleted catalog book: folder must live in `.bookmanager/trash/<bookID>` — if it exists on disk outside trash, journaled `BookFolder.trash` it. Per non-deleted book: if a trash entry exists, `BookFolder.restore` it (basic cross-Mac trash/restore reconcile; full trash-edit semantics out of scope).
  - After any path change: `catalog.upsert` with the new `relativePath` (via `IndexedBookFactory` with the catalog's snapshot).
- **`SyncEventSource`** (protocol) + implementations:
  - `FSEventSource`: `FSEventStream` (CoreServices) on the library root, delivering a callback on change. Backed by the active security scope.
  - `PollingSource`: a repeating task at a fixed interval — used on network/cloud roots and by tests.
  - `FakeEventSource` (test target): fires on demand.
- **`LibraryMonitor`** (actor): owns the event source + debounce + periodic backstop.
  - `start(changeEvents:onChange:)`, `stop()`.
  - Coalesces bursts (debounce ~1s) into one `onChange` invocation.
  - Runs the periodic `fullRescan` (60s) as `onPeriodic` — the missed-events backstop the 4a design calls "periodic full reconciliation".
  - Pauses when told (read-only state); `stop()` on library close.

### BookManager (app)

- `LibrarySession`: creates the monitor in `activate` (after the first ingest+reconcile), stops it in `closeLibrary`; `syncNow()` is the monitor's change handler (drain + ingest + reconcile + refresh); `isSyncing` published state; the periodic handler calls `fullRescan` + reconcile; `reconciliationReport` published and reset on close; ingest-on-open wired in `activate`.
- `ContentView`: indicator states — "Synced" / "Syncing…" / "N pending" / "Library unavailable" (the 4a indicator extended); Sync Now stays as a manual affordance.
- `DiagnosticsView`: new **Reconciliation** section rendering `reconciliationReport` (renamed/adopted/conflict copies), alongside the existing Quarantined Changes section.

## Data flow

Monitor event (or periodic tick) → debounce → `syncNow` (drain outbox → `SyncEngine.ingest` → `FolderReconciler.reconcile` → `refreshAll`) → report published → Diagnostics. Monitor paused while `isLibraryUnavailable`; stopped on close. All file mutations journaled via `BookFolder`'s existing transaction journal; nothing deletes book content.

## Testing

- **Reconciler** (`FolderReconcilerTests`): re-point rename; adopt-on-race; fork-on-hash-race (folder and file level); missing-folder recording; trash-restore (deleted book's folder trashed; non-deleted book's trash entry restored); report contents.
- **Monitor** (`LibraryMonitorTests`): fake event source fires N times → debounced to one `onChange`; periodic tick fires `onPeriodic`; pause stops callbacks; stop cleans up.
- **Regression** (`SyncEngineTests` addition): the 4a-mandated stuck-valid-change test (dependent change without base → `quarantined.isEmpty`, file stays; base arrives → converges).
- Full core suite stays green (119 baseline → +new tests).

## Out of scope

- Performance acceptance at 10k books, accessibility completion, metadata enrichment (separate slices).
- Full cross-Mac trash-edit semantics (delete-on-other-Mac tombstones beyond the basic trash/restore reconcile), per-book placeholder download UX beyond `ensureDownloaded`.

## Acceptance criteria

- [ ] While a library is open, edits from another Mac appear without manual Sync Now (debounced monitor + periodic backstop).
- [ ] A book's folder re-points to its merged canonical path after a title edit from another Mac; canonical-path races and file-content conflicts fork (never overwrite) and appear in Diagnostics.
- [ ] Opening a library ingests + reconciles immediately; the monitor pauses while the library is unavailable and resumes on reconnect.
- [ ] Trash/restore basic reconciliation works (deleted book's folder trashed; restored book's folder back from trash).
- [ ] The stuck-valid-change regression test is in place and green.
- [ ] Core suite green (119 + new); no change-store format change; nothing silently deleted.

# Multi-Mac Sync Core (Slice 4a) — Design

> **Status:** Approved 2026-08-01 (design direction agreed: option B — CRDT metadata convergence + derived-path self-convergence + hash-detect/fork file conflicts; file/folder reconciliation deferred to 4b).
> **Goal:** the library converges correctly when opened from multiple Macs via a shared drive, NAS, iCloud Drive, or any cloud-synced folder — offline edits queue to a durable local outbox, unseen remote changes are ingested and merged by hybrid logical clock, and nothing is silently lost.

## Verified context (why this is sound)

- `ChangeStore.writeBookChange` writes one **unique, content-addressed file per change** (`<clock>-<digest>.amchange`, atomic write, hash-dedupe). Two devices never write the same file, so every sync target (SMB/NAS, iCloud Drive, Dropbox, OneDrive) transports the change store **conflict-free by construction**.
- `HybridLogicalClock` + `AutomergeBookDocument.apply` already order and merge same-field concurrent edits deterministically (acceptance criterion 9 is implemented at the document level; this slice proves it end-to-end).
- The GRDB catalog lives under Application Support (never in the synced folder) and rebuilds from the change store — the local index is disposable.
- The design doc's `Sync Monitor` / `Offline and Reconnection Behavior` / `Reliability and Recovery` sections and acceptance criteria 8–11 are the binding requirements.
- Research best practice: **two-layer sync** (merge structured data via CRDT; handle the file layer separately), **"merge what you can, fork what you can't"** — never silent last-writer-wins overwrite, keep both + surface when unsure; **not single-writer locking** (Calibre's model, wrong for this goal); **no experimental full-CRDT filesystem** (unnecessary — canonical paths are *derived* from merged metadata, so path conflicts self-resolve in 4b's reconcile).

## Requirements (Slice 4a — sync core)

1. **Read-only when offline; transient failures queue (approved amendment 2026-08-01).** When the library folder is *known* unreachable (probe fails at open/activation), the library stays browsable from the local catalog but **editing is disabled** with a clear “Library unavailable — read-only” state — books can't load offline anyway, so offline edits add no value and would diverge canonical folder paths (the path-divergence finding from Task 5's review, routed to 4b). A write that fails *mid-session* because the library became unreachable (NAS hiccup, cloud pause) is **staged to the durable outbox and drained on the next sync** — never silently lost. The UI shows “Library unavailable — read-only” or the pending count.
2. **Ingest unseen changes.** On open/event, diff the library change store against a local record of applied change fingerprints; apply unseen changes (causally-ready with retry); quarantine malformed changes instead of crashing; ingest is idempotent (re-applying is safe).
3. **Convergence.** Two simulated Macs editing offline and syncing through a shared root converge to identical metadata (acceptance 8) with same-field edits resolving by newest HLC (acceptance 9).
4. **Reconnection sequence.** Re-establish security-scoped access → ingest unseen → drain outbox into the library change store → re-apply → refresh catalog/UI.
5. **Cloud capability model.** Probe the library root (local / network mount / ubiquitous cloud folder); before reading library files on a cloud folder, check `NSURLIsUbiquitousItemKey` download status and request download when needed (placeholder content must never read as "file lost").
6. **No silent loss.** Any conflict or anomaly is either resolved deterministically (HLC) or surfaced (quarantine list, diagnostics); the change store is never deleted or rewritten.

## Architecture

### BookManagerCore (all new components, testable)

- **`SyncState`** (local, Application Support): records applied change fingerprints per library ID and the outbox manifest. Small JSON/plist files; corrupted state degrades to "empty" (never blocks). `Outbox` entries are the same `amchange` payloads, staged under `Application Support/Book Manager/Outbox/<libraryID>/…` in the same book/device/clock/digest shape as the library change store, so **draining is a file move**, not a rewrite.
- **`SyncEngine`** (actor, the heart): owns ingest + drain + quarantine.
  - `ingest(root:state:)`: enumerate the library change store, fingerprint-diff against `SyncState`, apply unseen changes per book with the existing dependency-ordered apply loop (reuse `rebuildCatalog`'s algorithm), upsert the catalog, record fingerprints; retry causally-blocked changes; move undecodable changes to `.bookmanager/quarantine/<timestamp>/` and record them.
  - `drain(outbox:state:)`: move outbox change files into the library change store (same target naming), then ingest.
  - `reconcileState`: a full fingerprint rescan (the design's "periodic full reconciliation" correctness base, at the change-store level; folder/file reconciliation is 4b).
- **`LibraryRootCapabilities`**: probe the root — `isNetworkMount` (statfs `MNT_LOCAL`), `isUbiquitous` / `downloadStatus` of files (`NSURLUbiquitousItemDownloadingStatusKey`), `isICloudDrive` path heuristic; `ensureDownloaded(_ url:)` helper used before reads.
- **Repository/session wiring**: `LibraryRepository` gains an outbox-aware write path — when a library write fails with an access error (unreachable), the session routes the edit to the `Outbox`; the outbox is keyed by library ID; the catalog upsert still happens locally so browsing reflects the edit.

### BookManager (app)

- `LibrarySession` gains: `pendingSyncCount` (outbox size) surfaced as a small status indicator (toolbar/sidebar); `isLibraryUnavailable` (read-only state, set by a lightweight reachability probe — the library root directory must be readable); `syncStatus` state ("synced" / "N pending" / "library unavailable"); reconnection is triggered on window activate (`reconnectIfNeeded()` = refresh availability + `syncNow`) plus a manual "Sync Now" affordance (the always-on monitor is 4b). `saveEdit` blocks edits while `isLibraryUnavailable` (clear message); a write failure while online routes to the transient outbox path.

## Data flow

Edit (online): session → repository → change store (as today) → catalog upsert. Edit (offline): session → outbox (local) → catalog upsert; indicator shows pending. Reconnect: re-establish scope → `SyncEngine.ingest` (remote changes) → `SyncEngine.drain` (outbox → change store) → re-ingest → refresh. The change store remains the single authoritative source; the outbox is only a transport queue; the catalog is disposable.

## Testing

- **Two-Mac convergence** (acceptance 8): two device IDs + two local outbox dirs + one shared root; both edit offline; drain+ingest; assert identical catalogs and identical canonical paths.
- **HLC same-field convergence** (acceptance 9): both edit the same field offline; assert the newest HLC wins on both.
- **Outbox durability**: write edits, "crash" (re-create state from disk), drain, assert all changes land.
- **Quarantine**: inject a corrupt change file; assert ingest survives, the file is quarantined, and diagnostics list it.
- **Idempotent ingest**: ingest twice; assert no duplication or error.
- **Capabilities**: unit-test the probe with a local dir; ubiquitous/network branches exercised by tests where feasible, else documented manual checks.
- Full core suite stays green (104 baseline).

## Out of scope (Slice 4b)

- Sync Monitor event sources (FSEvents/DispatchSource) and periodic full *file* reconciliation.
- Folder/file reconciliation: canonical-path re-pointing, duplicate folders, same-name-different-content disambiguation (fork + diagnostics), trash/restore reconcile.
- Network-filesystem fallback depth (non-atomic FS semantics beyond the existing journaling), placeholder download UX beyond ensure-downloaded.
- Performance acceptance (10k books), accessibility completion, metadata enrichment (separate future slice).

## Acceptance criteria (4a)

- [ ] Two simulated Macs converge to identical metadata and canonical paths after offline edits + reordered change delivery (acceptance 8).
- [ ] Same-field concurrent edits resolve deterministically to the newest HLC value on both Macs (acceptance 9).
- [ ] Edits are blocked with a clear message while the library is known unreachable (read-only); a transient mid-session write failure is staged to the outbox and drained on reconnection with nothing lost.
- [ ] A corrupt change file quarantines (ingest never crashes) and appears in diagnostics.
- [ ] Cloud folder reads never surface placeholder bytes as content: `ensureDownloaded` is called before library-file reads on ubiquitous roots.
- [ ] Core suite green (104 + new sync tests); no change-store format change.

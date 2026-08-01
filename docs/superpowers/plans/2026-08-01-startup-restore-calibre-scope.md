# Startup Restore + Calibre Security Scope Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the Calibre import permission failure (missing security-scoped access) and make the app reopen the last-opened library at launch, falling back to the welcome screen when it can't be found.

**Architecture:** Two independent changes. (1) The app session holds a `startAccessingSecurityScopedResource()` grant on the fileImporter URL for the whole Calibre wizard — the same pattern `activate()` already uses for library open/create. (2) `LibraryBookmarkStore` (BookManagerCore) gains a persisted `lastOpenedLibraryID` plus `resolveLastOpened()` (resolve bookmark → check folder exists → clear when gone), and `LibrarySession` persists the marker on every successful open and restores it on launch via a `.task` on the root view.

**Tech Stack:** Swift 6.0 (strict concurrency), SwiftUI, AppKit, Swift Testing (`import Testing`), XcodeGen (`project.yml`), macOS 26 sandboxed app with `com.apple.security.files.user-selected.read-write` and app-scope bookmarks.

## Global Constraints

- macOS 26 deployment target; Swift 6.0 with `SWIFT_STRICT_CONCURRENCY: complete`.
- App is sandboxed (`Config/BookManager.entitlements`): all reads of user-selected folders (libraries and Calibre sources) require an active security scope on the URL.
- Storage rule: the portable library's `.bookmanager/changes` is authoritative; SQLite indexes are disposable and stay under Application Support.
- Tests use Swift Testing (`@Suite`/`@Test`/`#expect`), run with `xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' test`.
- `LibrarySession` is `@MainActor @Observable` and lives in the app target (no unit-test target exists for it — its logic is kept thin; testable decisions live in BookManagerCore).

## Decisions

- **D1 — "Close Library" does NOT clear last-opened.** The marker is written only on a successful open; relaunch reopens the last-opened library even if it was closed via Cmd+Shift+W. Rationale: matches the literal "last opened" wording. (Alternative — clear on close — is a one-line change in `closeLibrary()` if the user prefers the welcome screen to stick.)
- **D2 — Library found but broken (open throws) → existing `.failed` UI**, not the welcome screen. "Not found" means the bookmark doesn't resolve or the folder is gone; a corrupt-but-present library should surface the error with the existing "Choose Another Library" button.
- **D3 — `resolveLastOpened()` clears the marker when the folder is missing** (self-healing; next launch starts at welcome). Known caveat: a library on a temporarily-disconnected network volume will be forgotten; accepted per the requirement.

---

## Execution Adaptation (found during setup)

An existing isolated worktree `feature/auto-reopen` (`.worktrees/auto-reopen`) already implements Task 2's feature — two unreviewed commits (`2afdd09` feat, `916d267` fix) on top of the same main commit the plan was written against. Its design is recency-based (`LibraryBookmarkStore.save(_:for:at:)` + `recentLibraries()` + `mostRecentlyOpenedLibraryID()`, tested) rather than the single-marker API sketched below; it also adds a Library menu (Open Recent, Cmd-O) and a `--ui-testing` launch guard so UI tests start from a deterministic welcome screen.

Execution decision: use this worktree as the execution workspace. Task 1 (Calibre security scope — new work, not present anywhere) is implemented per this plan on top of the branch. Task 2's requirements (reopen last-opened at launch; welcome when missing) are met by the existing commits, so Task 2 executes as a **review of the existing commits against this plan's Task 2 requirements** plus a fix loop on any findings — not a re-implementation. The existing choices map onto the Decisions section as: D1 kept (close does not clear recency), D2 implemented as welcome-with-explanation (better than the failure screen for the launch case), D3 not implemented (stale recency entries are kept and simply fail to reopen — acceptable for a recency list; out of scope for the user's requirement). The scratch UI-test file left in the worktree working tree is discarded.

---

### Task 1: Hold security-scoped access for the Calibre source library

**Files:**

- Modify: `BookManager/Stores/LibrarySession.swift` (`selectCalibreLibrary(at:)`, `importCalibre()`, `closeLibrary()`, add `calibreSourceSecurityURL` property, `stopCalibreAccess()`, `cancelCalibreImport()`)
- Modify: `BookManager/Views/CalibreImportView.swift` (add `.onDisappear`)

**Interfaces:**

- Consumes: nothing new (existing `CalibreReader.open(libraryURL:)`, `CalibreImportService.importBooks`).
- Produces: `func cancelCalibreImport()` (idempotent — stops the held scope and clears all `calibre*` session state), called from the wizard's `onDisappear`; `stopCalibreAccess()` private helper.

Root cause: `selectCalibreLibrary` reads the user's Calibre folder (snapshot copy of `metadata.db` + later per-book format copies during import) without `startAccessingSecurityScopedResource()`, so the sandbox denies the reads. The working open/create path (`activate`) does start the scope — that is the control case proving the fix.

- [x] **Step 1: Add the scope-holding property and helpers**

In `BookManager/Stores/LibrarySession.swift`, next to `private var activeSecurityURL: URL?`, add:

```swift
private var calibreSourceSecurityURL: URL?
```

Add private helper (place near `closeLibrary()`):

```swift
private func stopCalibreAccess() {
    calibreSourceSecurityURL?.stopAccessingSecurityScopedResource()
    calibreSourceSecurityURL = nil
}
```

- [x] **Step 2: Start the scope in `selectCalibreLibrary` before opening, and release it on every path that never shows the wizard**

Replace the current `selectCalibreLibrary(at:)` body:

```swift
    func selectCalibreLibrary(at url: URL) async {
        // The folder comes from SwiftUI's fileImporter and is security-scoped:
        // the sandbox denies every read of the source (including the
        // metadata.db snapshot copy inside CalibreReader.open) until the scope
        // is started. Hold it for the whole wizard — the import copies book
        // files from this folder later.
        stopCalibreAccess()
        if url.startAccessingSecurityScopedResource() {
            calibreSourceSecurityURL = url
        }
        defer {
            // The wizard never appears on the failure paths: release the scope.
            if calibreSummary == nil { stopCalibreAccess() }
        }
        let reader: CalibreReader
        do {
            reader = try CalibreReader.open(libraryURL: url)
        } catch {
            lastError = error.localizedDescription
            calibreSummary = nil
            calibreBooks = []
            calibreSourcePath = nil
            return
        }
        defer { try? reader.close() }
        do {
            let summary = try reader.summary()
            let books = try reader.books()
            calibreSummary = summary
            calibreBooks = books
            calibreSelectedIDs = Set(books.map(\.calibreID))
            calibreImportReport = nil
            calibreSourcePath = url.standardizedFileURL.path
        } catch {
            lastError = error.localizedDescription
            calibreSummary = nil
            calibreBooks = []
            calibreSourcePath = nil
        }
    }
```

- [x] **Step 3: Release the scope once the import completes reading the source**

In `importCalibre()`, inside the `do` block immediately after `calibreImportReport = try await service.importBooks(...)` succeeds, add:

```swift
            // The source is no longer read after the import completes; a
            // failed import keeps the scope so the wizard's retry can read it.
            stopCalibreAccess()
```

Release on success only: when `importBooks` throws, `calibreImportReport` stays nil, the wizard remains interactive with the summary shown, and a retry re-reads the source — the scope must still be held then. The failure path is cleaned up by `cancelCalibreImport()` on wizard disappear (Step 4) or `closeLibrary()`.

- [x] **Step 4: Add `cancelCalibreImport()` and wire `closeLibrary()`**

Add to `LibrarySession`:

```swift
    /// Stops the Calibre source's security-scoped access and clears all wizard
    /// state. Called when the wizard disappears (Cancel, Done, or Escape);
    /// idempotent.
    func cancelCalibreImport() {
        stopCalibreAccess()
        calibreSummary = nil
        calibreBooks = []
        calibreSelectedIDs = []
        calibreImportReport = nil
        calibreImportInProgress = false
        calibreSourcePath = nil
    }
```

In `closeLibrary()`, next to the existing `activeSecurityURL` stop, add:

```swift
        stopCalibreAccess()
```

(Keep the existing inline `calibre*` resets in `closeLibrary()`; they are now redundant with `cancelCalibreImport()` but harmless — do not bundle a refactor.)

- [x] **Step 5: Release the scope when the wizard sheet disappears**

In `BookManager/Views/CalibreImportView.swift`, attach to the root `VStack` (the one with `frame(minWidth:minHeight:)`):

```swift
        .onDisappear { session.cancelCalibreImport() }
```

- [x] **Step 6: Build and verify the fix manually**

Run: `./script/build_and_run.sh`

Expected:

1. Open or create a Book Manager library.
2. Click **Import from Calibre…** and pick a real Calibre library folder (e.g. under `~/Documents` or `~/Library`).
3. The summary (schema version, book count) appears — no "metadata.db couldn't be copied…" alert.
4. Import all books; the report shows them imported with no permission-style `.failed` rows, and the books exist in the library.
5. Cancel the wizard; then re-open it and repeat steps 2–4 (scope must not leak: repeated open/cancel cycles stay stable).

- [x] **Step 7: Commit**

```bash
git add BookManager/Stores/LibrarySession.swift BookManager/Views/CalibreImportView.swift
git commit -m "fix: hold security-scoped access on the Calibre source library during import"
```

---

### Task 2: Reopen the last-opened library at launch

**Files:**

- Modify: `BookManagerCore/Security/LibraryBookmarkStore.swift` (add `lastOpenedLibraryID`, `resolveLastOpened()`)
- Test: `BookManagerCoreTests/Security/LibraryBookmarkStoreTests.swift` (add three tests)
- Modify: `BookManager/Stores/LibrarySession.swift` (persist marker in `activate`, add `restoreLastOpened()`)
- Modify: `BookManager/App/BookManagerApp.swift` (`.task` restore)

**Interfaces:**

- Consumes: `LibraryBookmarkStore.resolve(_:)` (existing), `LibrarySession.openLibrary(at:)` (existing).
- Produces: `LibraryBookmarkStore.lastOpenedLibraryID: UUID?` (get/set, persisted under `"lastOpenedLibraryID"`), `LibraryBookmarkStore.resolveLastOpened() -> URL?`, `LibrarySession.restoreLastOpened() async`.

- [x] **Step 1: Write the failing tests**

Append to `BookManagerCoreTests/Security/LibraryBookmarkStoreTests.swift`:

```swift
    private func makeStore() -> LibraryBookmarkStore {
        let suite = "BookManagerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return LibraryBookmarkStore(defaults: defaults)
    }

    @Test
    func lastOpenedLibraryIDRoundTrips() {
        let store = makeStore()
        let id = UUID()
        #expect(store.lastOpenedLibraryID == nil)
        store.lastOpenedLibraryID = id
        #expect(store.lastOpenedLibraryID == id)
        store.lastOpenedLibraryID = nil
        #expect(store.lastOpenedLibraryID == nil)
    }

    @Test
    func resolveLastOpenedReturnsNilAndClearsWhenFolderMissing() throws {
        let store = makeStore()
        let libraryID = UUID()
        let folder = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        // Note: folder is deliberately NOT created.
        try store.save(folder, for: libraryID)
        store.lastOpenedLibraryID = libraryID

        #expect(store.resolveLastOpened() == nil)
        #expect(store.lastOpenedLibraryID == nil)
    }

    @Test
    func resolveLastOpenedReturnsURLWhenFolderExists() throws {
        let store = makeStore()
        let libraryID = UUID()
        let folder = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try store.save(folder, for: libraryID)
        store.lastOpenedLibraryID = libraryID

        let url = store.resolveLastOpened()
        #expect(url?.standardizedFileURL == folder.standardizedFileURL)
    }
```

- [x] **Step 2: Run the tests to verify they fail**

Run:

```bash
xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' test -only-testing:BookManagerCoreTests/LibraryBookmarkStoreTests
```

Expected: FAIL — `LibraryBookmarkStore` has no member `lastOpenedLibraryID` / `resolveLastOpened`.

- [x] **Step 3: Implement the persistence in `LibraryBookmarkStore`**

In `BookManagerCore/Security/LibraryBookmarkStore.swift`, add the key and the two members:

```swift
public struct LibraryBookmarkStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "librarySecurityBookmarks"
    private let lastOpenedKey = "lastOpenedLibraryID"

    // ... existing init/save/resolve unchanged ...

    /// The library most recently opened successfully; nil once cleared.
    public var lastOpenedLibraryID: UUID? {
        get { defaults.string(forKey: lastOpenedKey).flatMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue?.uuidString, forKey: lastOpenedKey) }
    }

    /// Resolves the last-opened library's security-scoped URL when its folder
    /// still exists. When the marker is absent, the bookmark no longer
    /// resolves, or the folder is gone, clears the marker and returns nil — the
    /// caller should show the welcome screen (Decision D3).
    public func resolveLastOpened() -> URL? {
        guard let id = lastOpenedLibraryID,
              let resolved = try? resolve(id),
              FileManager.default.fileExists(atPath: resolved.url.path) else {
            lastOpenedLibraryID = nil
            return nil
        }
        return resolved.url
    }
}
```

- [x] **Step 4: Run the tests to verify they pass**

Same command as Step 2. Expected: PASS (all three new tests + the existing one).

- [x] **Step 5: Persist the marker on every successful open**

In `BookManager/Stores/LibrarySession.swift`, inside `activate(url:create:)`, in the success path right after the existing `try bookmarks.save(url, for: repository.manifest.id)`, add:

```swift
            bookmarks.lastOpenedLibraryID = repository.manifest.id
```

- [x] **Step 6: Add `restoreLastOpened()` to the session**

Add to `LibrarySession` (place after `openLibrary(at:)`):

```swift
    /// Reopens the most recently used library at launch. When no library was
    /// ever opened, or the last one can no longer be found (Decision D3 has
    /// already cleared the marker), the session stays on the welcome screen.
    func restoreLastOpened() async {
        guard state == .welcome else { return }
        guard let url = bookmarks.resolveLastOpened() else { return }
        await openLibrary(at: url)
    }
```

Note: `openLibrary(at:)` → `activate` already starts the security scope on the resolved bookmark URL, validates the manifest, and rebuilds the catalog; a corrupt-but-present library lands in the existing `.failed` UI (Decision D2).

- [x] **Step 7: Trigger the restore at launch**

In `BookManager/App/BookManagerApp.swift`:

```swift
        WindowGroup {
            ContentView(session: session)
                .task { await session.restoreLastOpened() }
        }
```

- [x] **Step 8: Full test suite + manual verification**

Run all tests:

```bash
xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' test
```

Expected: all BookManagerCore + UI tests pass.

Manual (via `./script/build_and_run.sh`):

1. Create a library, add a book, quit (Cmd+Q).
2. Relaunch → the library opens automatically.
3. Close Library (Cmd+Shift+W) → welcome; relaunch → the library still reopens (D1).
4. Quit, move the library folder to the Trash, relaunch → welcome screen, no error alert.
5. Open/create another library, quit, relaunch → that library reopens (marker follows the most recent open).

- [x] **Step 9: Commit**

```bash
git add BookManagerCore/Security/LibraryBookmarkStore.swift \
        BookManagerCoreTests/Security/LibraryBookmarkStoreTests.swift \
        BookManager/Stores/LibrarySession.swift \
        BookManager/App/BookManagerApp.swift
git commit -m "feat: reopen the last-opened library at launch, welcome when missing"
```

---

## Self-Review

- **Spec coverage:** "open last opened library on starting up" → Task 2 Steps 5–7. "if library not found, show welcome screen" → Task 2 Steps 1–4, 6 (missing folder → `resolveLastOpened()` clears → welcome). Calibre permission error → Task 1 Steps 1–5 (root cause: missing `startAccessingSecurityScopedResource()` on the fileImporter URL; same grant is needed by the later per-book copies, so it is held for the whole wizard).
- **Placeholder scan:** no TBDs; every step carries concrete code or an exact command.
- **Type consistency:** `lastOpenedLibraryID` (UUID?) and `resolveLastOpened() -> URL?` are defined in Task 2 Step 3 and consumed in Steps 5–6 with matching names; `cancelCalibreImport()`/`stopCalibreAccess()` from Task 1 are used consistently in Task 1 Steps 4–5. `calibreSourceSecurityURL` is set in Step 2 and stopped in Steps 1/3/4. No name drift.

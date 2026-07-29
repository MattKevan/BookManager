# Book Manager Design Specification

## Summary

Book Manager is a native macOS ebook library manager inspired by Calibre. Version 1 targets macOS 26 or later and focuses on organising ebook files and metadata. It supports multiple portable library folders, with one library active at a time. A library can live on local storage, iCloud Drive, a network drive, or another user-selected location.

The app imports copies of existing Calibre libraries and never modifies the source. It also imports individual EPUB, PDF, and DJVU files. Books are stored in human-readable, Calibre-style author and title folders.

Version 1 is a library manager rather than an ebook reader. It opens books in the user's preferred external application.

## Goals

- Create, open, relocate, and switch between independent library folders.
- Store the complete portable library in a user-selected folder.
- Support reliable offline edits and automatic multi-Mac convergence.
- Import a copy of an existing Calibre library without modifying it.
- Preserve core Calibre metadata and retain unsupported metadata for future features.
- Import and manage EPUB, PDF, and DJVU files.
- Search, filter, sort, inspect, and edit book metadata.
- Keep files human-readable in Calibre-style author and title folders.
- Recover safely from interrupted imports, renames, deletes, and synchronization.
- Keep domain and synchronization logic portable enough for later Apple-platform clients.

## Non-goals for Version 1

- Built-in EPUB, PDF, or DJVU reading.
- Ebook format conversion.
- Physical ereader or device synchronization.
- Online metadata or cover downloading.
- A content server or browser-based catalogue.
- Concurrent shared-network editing by several users.
- Editing a Calibre library in place.
- Full first-class editing of Calibre custom columns.
- iPadOS or iOS interfaces.

The synchronization design must not prevent a later shared-network library mode, but that mode is outside version 1.

## Supported Environment

- macOS 26 or later.
- Swift 6 with strict concurrency.
- A sandboxed application using security-scoped bookmarks for persistent access to user-selected folders.
- Local disks, external disks, iCloud Drive folders, and mounted network volumes.

## Product Experience

### Main Window

The app has one main window and one active library at a time.

The sidebar contains:

- All Books
- Recently Added
- Authors
- Series
- Tags
- Formats
- Saved collections

The book browser supports:

- A sortable table view
- A cover-grid view
- Stable multi-selection
- Full-library search
- Filters derived from sidebar selections
- Contextual actions

The inspector edits:

- Title and title sort
- Ordered authors and author sort
- Series and series index
- Tags
- Rating
- Publisher
- Publication and added dates
- Languages
- Identifiers, including ISBN
- Comments or description
- Cover
- Available format files

The toolbar exposes:

- Add Books
- Edit Metadata
- Open Book
- Reveal in Finder
- Table/grid view switching
- Search

Core commands are also available through standard File, Edit, View, and Library menus, contextual menus, and keyboard shortcuts. Dragging supported ebook files into the browser starts an import. Quick Look is available when the system supports the selected format.

### Library Switching

The library switcher can:

- Create a library in a selected folder.
- Open an existing Book Manager library.
- Switch among recently opened libraries.
- Relocate a library after the user moves it.
- Remove a missing library from the recent list without deleting its files.

Opening a library validates its identity and schema before activating it. The app stores a security-scoped bookmark and the library UUID, not a path alone.

### Ordinary Book Import

The ordinary import flow:

1. Accepts selected or dropped EPUB, PDF, and DJVU files.
2. Copies source files into a staging directory inside the destination library.
3. Computes a content hash for every file.
4. Extracts embedded metadata where supported and falls back to the source filename.
5. Detects exact duplicates by content hash.
6. Flags likely duplicates by identifier or normalized title and author.
7. Lets the user review metadata and duplicate decisions.
8. Commits each book independently through the library repository.

An exact duplicate is never copied silently. A likely duplicate is never merged silently.

### Calibre Import

The Calibre import wizard:

1. Selects a Calibre library folder containing `metadata.db`.
2. Opens the database read-only and validates the expected schema.
3. Displays book and format counts before copying.
4. Allows all books or a subset to be selected.
5. Copies files and covers through the normal staging pipeline.
6. Commits books independently.
7. Records progress so an interrupted import can resume.
8. Produces a result report with imported, skipped, duplicate, and failed items.

The importer maps:

- Books
- Ordered authors
- Series and series index
- Tags
- Ratings
- Publisher
- Publication and added dates
- Languages
- Identifiers
- Comments
- Cover
- All available format files

Calibre custom columns and unsupported source values are stored in a namespaced raw metadata payload. Annotations and last-read positions are preserved in that raw payload when present, but version 1 does not display or edit them.

The supplied acceptance library uses Calibre database schema `user_version` 26 and contains 13 books and 13 format records. It is a read-only acceptance fixture and is not copied into the repository.

## Architecture

### Selected Approach

The synchronized authority is a portable CRDT operation log stored inside the library. A shared SQLite database is not used as the source of truth because iCloud file conflicts and network filesystem locking make multi-writer database access unsafe.

Each Mac builds a private SQLite catalogue from the operation log. The catalogue provides fast queries, sorting, filtering, and full-text search. It can be deleted and rebuilt without losing library data.

CloudKit is not required. The library remains an ordinary portable folder and the synchronization transport remains replaceable.

### Component Boundaries

#### SwiftUI App Shell

Owns the macOS scenes, root layout, commands, toolbar, settings, sheets, alerts, accessibility, and selection presentation. It does not manipulate library files directly.

#### Library Session

Owns the currently active library and exposes observable state to the UI. It coordinates activation, deactivation, pending status, and UI refreshes.

#### Library Repository

Provides the single high-level mutation API for:

- Creating books
- Editing metadata
- Adding, replacing, and removing formats
- Replacing covers
- Deleting and restoring books
- Importing books

Every mutation becomes an operation before derived state or files are changed.

#### CRDT Engine

Contains pure, platform-neutral Swift value types and reducers. It has no dependency on SwiftUI, SQLite, security-scoped bookmarks, or filesystem observation.

#### Operation Store

Validates and atomically writes immutable operation files. It enumerates unseen operations and quarantines malformed data.

#### Local Catalogue

Provides a protocol-backed SQLite implementation for:

- Materialized book records
- Search
- Sorting
- Facets for authors, series, tags, and formats
- Seen-operation tracking
- Diagnostics

The catalogue is stored in Application Support rather than in the synchronized library.

#### Filesystem Coordinator

Owns:

- Security-scoped access
- Library staging
- Path generation and normalization
- Journaled file transactions
- Calibre-style folder reconciliation
- Trash and restore
- Recovery

#### Sync Monitor

Observes changes in the selected library, ingests unseen operations, drains the local outbox, and periodically performs a full reconciliation to cover missed filesystem events.

#### Import Services

Separate services handle:

- File metadata extraction
- Content hashing
- Duplicate detection
- Ordinary imports
- Read-only Calibre database mapping

## Library Layout

An example library layout is:

```text
My Library/
├── David Epstein/
│   └── Range (a1b2c3d4)/
│       ├── Range - David Epstein.epub
│       ├── cover.jpg
│       └── metadata.opf
├── Ellen Lupton/
│   └── Type on Screen (e5f6a7b8)/
│       ├── Type on Screen - Ellen Lupton.pdf
│       ├── cover.jpg
│       └── metadata.opf
└── .bookmanager/
    ├── library.json
    ├── operations/
    │   └── <device-uuid>/
    │       └── <operation-id>.json
    ├── transactions/
    ├── trash/
    ├── recovery/
    └── quarantine/
```

`library.json` contains the library UUID, format version, creation time, and supported feature flags.

Each book has a permanent UUID. The eight-character short ID in its folder name is derived from that UUID and prevents collisions without exposing a mutable numeric database identifier.

`metadata.opf` is a generated, portable projection of the merged metadata. It is not the synchronization authority.

The app normalizes forbidden characters, reserved names, trailing whitespace, and path length consistently. A deterministic truncation rule preserves the short ID.

## Local Application State

Machine-local data is stored in the app's Application Support container:

```text
Book Manager/
├── device.json
├── libraries.json
├── Indexes/<library-uuid>.sqlite
└── Outbox/<library-uuid>/<operation-id>.json
```

- `device.json` contains the installation's device UUID and logical clock state.
- `libraries.json` contains recent-library identities and security-scoped bookmarks.
- `Indexes` contains rebuildable local catalogues.
- `Outbox` durably holds metadata operations created while a library folder is unavailable.

Book contents are never placed in Application Support.

## CRDT and Synchronization Model

### Operation Identity and Clock

Every operation contains:

- Schema version
- Unique operation UUID
- Library UUID
- Book UUID when book-scoped
- Device UUID
- Hybrid logical clock timestamp
- Operation kind
- Typed payload
- Optional content hash references

The hybrid logical clock consists of physical time, a logical counter, and device UUID tie-breaking. This provides deterministic ordering without trusting wall-clock time alone.

Operation filenames are unique and immutable. Writers create a temporary file, validate it, and rename it to its final name. Different devices never append to the same file.

### Merge Rules

- Scalar fields use last-write-wins registers.
- Ordered authors use a last-write-wins ordered value so display order is preserved.
- Ordered languages use a last-write-wins ordered value.
- Tags use an observed-remove set.
- Identifiers use independent last-write-wins values keyed by identifier type.
- Each ebook format uses a last-write-wins value keyed by normalized format.
- The cover uses a last-write-wins value.
- Unsupported Calibre metadata uses a last-write-wins namespaced payload.
- Deletion uses a tombstone.

Concurrent changes to different fields survive. When two devices change the same field, the operation with the newest hybrid logical clock wins.

When a cover or format replacement loses a merge, its file is retained in recovery until the user removes it. A stale replica cannot resurrect a tombstoned book.

Merge must be commutative, associative, and idempotent. Processing the same operation multiple times has no effect after its first application.

### Derived Files and Paths

Merged metadata determines the canonical human-readable path:

```text
Author/Title (short-id)/Title - Author.extension
```

Metadata edits may therefore require a folder or filename move. The filesystem coordinator records a transaction before moving anything, applies moves, regenerates `metadata.opf`, and marks the transaction complete.

Two devices can temporarily produce stale or duplicate paths while disconnected. After merging operations, both calculate the same canonical path. Extra folders are matched by book UUID and moved to recovery.

### Offline and Reconnection Behavior

When a library is unavailable:

- Its local catalogue remains browsable.
- Unavailable ebook files show an availability state.
- Metadata edits are written to the durable local outbox.
- File imports, deletes, restores, cover changes, and format changes pause because they require destination access.
- The UI distinguishes locally saved work from fully synchronized work.

When the library returns:

1. Security-scoped access is re-established.
2. Unseen library operations are ingested.
3. Local outbox operations are written to the library.
4. All operations are merged.
5. Files and sidecars are reconciled.
6. The local catalogue and UI are refreshed.

## Mutation Data Flow

A metadata edit follows:

```text
SwiftUI → Library Repository → Operation Store or Local Outbox
        → CRDT Reducer → Filesystem Reconciliation
        → Local Catalogue → Observable UI State
```

An import follows:

```text
Source Files → Library Staging → Hash and Metadata Extraction
             → Duplicate Review → Library Repository
             → Create Operation → Canonical Book Folder
             → Local Catalogue
```

No UI view writes operation, catalogue, or book files directly.

## Reliability and Recovery

### Transaction Safety

- Mutable file work is staged inside the destination library so same-volume atomic moves can be used when available.
- Every multi-step mutation has a transaction journal.
- A launch-time recovery pass completes or rolls back interrupted work.
- Operation processing is idempotent.
- Imports commit one book at a time.

Network filesystems that do not provide atomic rename guarantees use copy, hash verification, and journaled cleanup rather than assuming atomicity.

### Diagnostics

A diagnostics screen lists:

- Pending outbox operations
- Unavailable format files
- Import failures
- Malformed or unsupported operations
- Quarantined data
- Recovery folders
- Interrupted transactions
- Index health and rebuild status

Malformed operations are quarantined rather than blocking healthy books. Missing format files remain visible as repairable catalogue issues.

### Delete and Restore

Deleting a book:

1. Writes a tombstone operation.
2. Moves its canonical folder to `.bookmanager/trash`.
3. Removes it from normal catalogue results.

Restore writes a newer restore operation and returns the folder to its current canonical path. Emptying library trash is the only permanent deletion action and requires explicit confirmation.

## Concurrency Model

Library mutation, operation ingestion, catalogue writes, and filesystem transactions are isolated behind actors. Long-running imports stream results and do not hold the main actor. SwiftUI-observable presentation state is updated on the main actor.

Domain models crossing actor boundaries conform to `Sendable`. File and database implementations are hidden behind protocols so deterministic in-memory implementations can be used in tests.

## Error Presentation

Errors use actionable categories rather than raw system messages:

- Library unavailable
- Permission expired
- Unsupported library version
- Source file missing
- Destination out of space
- Duplicate book
- Import partially completed
- Operation quarantined
- File requires download
- Recovery required

Non-destructive warnings appear inline or in diagnostics. Blocking failures use a sheet or alert with a clear retry, reconnect, reveal, restore, or cancel action.

## Testing Strategy

### CRDT Tests

Tests cover:

- Commutativity, associativity, and idempotence
- Hybrid logical clock ties and clock skew
- Concurrent edits to the same field
- Concurrent edits to different fields
- Tag addition and removal
- Identifier merges
- Tombstone and restore ordering
- Concurrent format and cover replacements
- Duplicate and out-of-order operation delivery
- Randomized multi-device operation sequences

### Calibre Import Tests

A generated Calibre schema-version-26 fixture covers:

- Multiple authors with ordering
- Multiple formats
- Tags and series
- Ratings and publisher
- Dates and languages
- Identifiers and comments
- Covers
- Custom columns
- Unsupported metadata preservation

The supplied 13-book library is used read-only for local acceptance testing. The source must have the same modification timestamp and content hash after testing.

### Filesystem and Recovery Tests

Tests cover:

- Library creation and validation
- Path normalization and truncation
- Metadata-driven folder renames
- Filename collisions
- Interrupted import and rename transactions
- Non-atomic filesystem fallback
- Missing files
- Duplicate folders
- Trash and restore
- Malformed operation quarantine
- Complete local-index rebuild

### Synchronization Tests

Tests simulate:

- Two or more devices editing offline
- Different operation delivery orders
- Duplicate delivery
- Temporary library unavailability
- Durable outbox restart
- Reconnection
- Identical final catalogues and canonical paths

### UI and Accessibility Tests

UI tests cover:

- Creating, opening, relocating, and switching libraries
- Importing files
- Searching, filtering, and sorting
- Editing metadata
- Opening and revealing books
- Running and resuming a Calibre import
- Viewing diagnostics
- Deleting and restoring a book

All core actions must be keyboard-accessible and have meaningful accessibility labels. Browser rows, cover tiles, inspector groups, progress states, and diagnostics must be usable with VoiceOver and larger text settings.

### Performance Tests

- Browsing and sorting remain responsive with 10,000 generated books.
- Local search returns results within 250 milliseconds under normal test conditions.
- Large imports stream work rather than loading the entire source catalogue into memory.
- Catalogue rebuilding reports progress and remains cancellable.

## Acceptance Criteria

Version 1 is complete when:

1. A user can create, reopen, relocate, and switch between library folders selected through the macOS file picker.
2. Local, iCloud Drive, and mounted network locations retain access through security-scoped bookmarks.
3. Individual EPUB, PDF, and DJVU files import through a staged and recoverable flow.
4. The supplied Calibre source imports as a copy without source modification.
5. All 13 source books and 13 source format records are accounted for in the import report.
6. Core metadata, covers, and format files are mapped correctly, while unsupported data remains preserved.
7. Users can browse, search, filter, sort, edit, open, reveal, delete, and restore books.
8. Two simulated Macs converge to identical metadata and paths after offline edits and reordered operation delivery.
9. Same-field concurrent edits resolve deterministically to the newest hybrid logical clock value.
10. Interrupted mutations recover without silent data loss.
11. A lost or corrupt local SQLite catalogue can be rebuilt entirely from portable library data.
12. The application satisfies the defined keyboard and VoiceOver flows.

## Delivery Slices

The design is delivered as four testable vertical slices rather than one large implementation batch:

1. **Library foundation:** create/open libraries, security-scoped access, CRDT operations, local catalogue rebuilding, canonical paths, and a minimal table browser.
2. **Management workflows:** ordinary file import, metadata editing, search and facets, cover grid, external opening, trash, restore, and diagnostics.
3. **Calibre migration:** read-only schema-version-26 mapping, preview and selection, resumable copying, raw metadata preservation, and the import report.
4. **Multi-Mac hardening:** durable offline outbox, filesystem monitoring, reordered-operation convergence, recovery reconciliation, network-filesystem fallbacks, accessibility completion, and performance acceptance.

Each slice must leave the app runnable and its completed behavior covered by automated tests. Later slices may extend interfaces created by earlier slices but may not replace the portable operation log or rebuildable local catalogue architecture.

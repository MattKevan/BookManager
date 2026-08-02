# Device Support (Kindle MTP) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** let a Kindle Paperwhite (12th gen, MTP) appear in the app's sidebar like a Finder removable drive, browse the books on the device, import DRM-free books into the library, and send library books to the device (native-format copy in v1; full format conversion is a later feature behind the `FormatConverter` seam). Device support must be modular: `DeviceTransport` (how bytes move) × `DeviceProfile` (what a device is), so Nook/other Kindles/reMarkable 2 are new files, not shared-code edits.

**Architecture:** BookManagerCore gains a `Devices/` group: transport protocol + MTP implementation (library chosen by a hardware spike — primary `swift-mtp`/libmtp, fallback pure-Swift `MTPKit`), profile protocol + `KindlePaperwhite12Profile` (Amazon vendor `0x1949`, formats `[epub, pdf, azw3, txt]`, `Documents` folder), a registry that pairs detected devices with profiles, a scanner that lists device books (DRM flag via the existing `MobiReader`), a pure `SendPlan` format-matching layer, and send/import services over a `MockTransport` for tests. The app target gains a `DeviceManager` store, a Devices sidebar section, a device-books view, and send-to-device (toolbar, menu, drag-onto-device). Import-from-device reuses the existing `ImportService` pipeline (AZW/MOBI→EPUB conversion + DRM rejection) unchanged.

**Tech Stack:** Swift 6.0 (strict concurrency), macOS 26, SwiftUI + Observation (`@Observable`), Swift Testing, XcodeGen, SPM (MTP library per spike: `SwiftMTPAsync` product of CleanCocoa/swift-mtp, or MTPKit), libmobi via the existing `MobiReader`/`MobiToEpubConverter`.

## Global Constraints

- macOS 26; Swift 6.0 with `SWIFT_STRICT_CONCURRENCY: complete`. Transports are actors or Sendable structs; no shared mutable state across isolation domains.
- **No change-store format change**; no CRDT/GRDB schema changes. Device support is additive.
- **DRM is never stripped**: DRM'd device files show a lock badge in the device list and fail import with the existing "DRM-protected book" message.
- **Sandbox**: MTP/USB access requires adding `com.apple.security.device.usb` to `Config/BookManager.entitlements`. If the chosen library cannot enumerate/transfer inside the sandboxed app, escalate per the spike's BLOCKED protocol (documented fallbacks: MTPKit; temporary non-sandboxed debug build; report).
- Existing non-perf suite stays green. **Verification commands MUST use `-skip-testing:BookManagerCoreTests/PerformanceTests`** (established convention).
- Run `xcodegen generate --spec project.yml` after modifying `project.yml` or adding any file (sources are directory-globbed).
- Test command shape: `xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -derivedDataPath .build/DerivedData test -only-testing:BookManagerCoreTests/Devices/<Suite>`.
- New devices = new profile/transport files + a registry entry — never shared-code edits (verified by a stub profile alongside `KindlePaperwhite12Profile` in registry tests).

---

### Task 1: Device models + `DeviceTransport` protocol + `MockTransport` (Core, TDD)

**Files:**

- Create: `BookManagerCore/Devices/DeviceTransport.swift`
- Create: `BookManagerCoreTests/Devices/MockTransport.swift`
- Create: `BookManagerCoreTests/Devices/DeviceTransportTests.swift`

**Interfaces:**

- Consumes: nothing (Foundation only).
- Produces (locked for all later tasks):
  - `DeviceFile { name: String, path: String, size: Int64 }` — `Sendable, Equatable, Identifiable`; `var id: String { path }`.
  - `DeviceFolder { path: String }` — `Sendable, Equatable`.
  - `DeviceInfo { name: String, vendorID: UInt16?, productID: UInt16? }` — `Sendable, Equatable`.
  - `DeviceTransport` protocol (`Sendable`): `func connect() async throws -> DeviceInfo`; `func listFiles(in folder: DeviceFolder) async throws -> [DeviceFile]`; `func download(_ file: DeviceFile, to destination: URL) async throws`; `func upload(_ source: URL, to folder: DeviceFolder, as filename: String) async throws`; `func eject() async throws`; `func disconnect() async throws`.
  - `MockTransport` (test target): `actor MockTransport: DeviceTransport` with `static let deviceInfo = DeviceInfo(name: "Mock Kindle", vendorID: 0x1949, productID: 0x9023)`; `init()`; `func add(fileNamed: String, data: Data, in folder: DeviceFolder = DeviceFolder(path: "Documents"))`; `func fileData(named: String) -> Data?`; `func uploadedFiles() -> [String: Data]` (keys `"folder/name"`); `var ejected = false`; `func uploadError(_ error: Error)` — makes the next upload throw (for service failure-path tests).

- [ ] **Step 1: Write the failing tests**

`DeviceTransportTests.swift`:

```swift
import Foundation
import Testing
@testable import BookManagerCore

@Suite
struct DeviceTransportTests {
    @Test
    func mockConnectReturnsAmazonVendorInfo() async throws {
        let transport = MockTransport()
        let info = try await transport.connect()
        #expect(info.name == "Mock Kindle")
        #expect(info.vendorID == 0x1949)
    }

    @Test
    func mockListsSeededFilesInFolder() async throws {
        let transport = MockTransport()
        await transport.add(fileNamed: "Book.azw3", data: Data("x".utf8))
        await transport.add(fileNamed: "Other.epub", data: Data("y".utf8))

        let files = try await transport.listFiles(in: DeviceFolder(path: "Documents"))

        #expect(files.count == 2)
        #expect(files.contains { $0.name == "Book.azw3" && $0.size == 1 })
        #expect(files.contains { $0.name == "Other.epub" })
    }

    @Test
    func mockDownloadWritesBytesToDestination() async throws {
        let transport = MockTransport()
        let bytes = Data("hello".utf8)
        await transport.add(fileNamed: "Book.epub", data: bytes)

        let dest = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dest) }
        let file = try #require(try await transport.listFiles(in: DeviceFolder(path: "Documents")).first)
        try await transport.download(file, to: dest.appending(path: "Book.epub"))

        let written = try Data(contentsOf: dest.appending(path: "Book.epub"))
        #expect(written == bytes)
    }

    @Test
    func mockUploadStoresBytesUnderFolderName() async throws {
        let transport = MockTransport()
        let source = FileManager.default.temporaryDirectory.appending(path: "up.epub")
        try Data("content".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        try await transport.upload(source, to: DeviceFolder(path: "Documents"), as: "Up.epub")

        let uploaded = await transport.uploadedFiles()
        #expect(uploaded["Documents/Up.epub"] == Data("content".utf8))
    }

    @Test
    func mockEjectSetsFlag() async throws {
        let transport = MockTransport()
        try await transport.eject()
        #expect(await transport.ejected)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodegen generate --spec project.yml`, then `xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -derivedDataPath .build/DerivedData test -only-testing:BookManagerCoreTests/Devices/DeviceTransportTests`. Expected: FAIL — no such module member `MockTransport`/`DeviceTransport`.

- [ ] **Step 3: Implement the models, protocol, and mock**

`BookManagerCore/Devices/DeviceTransport.swift`:

```swift
import Foundation

public struct DeviceFile: Sendable, Equatable, Identifiable {
    public let name: String
    public let path: String
    public let size: Int64

    public init(name: String, path: String, size: Int64) {
        self.name = name
        self.path = path
        self.size = size
    }

    public var id: String { path }
}

public struct DeviceFolder: Sendable, Equatable {
    public let path: String
    public init(path: String) { self.path = path }
}

public struct DeviceInfo: Sendable, Equatable {
    public let name: String
    public let vendorID: UInt16?
    public let productID: UInt16?

    public init(name: String, vendorID: UInt16?, productID: UInt16?) {
        self.name = name
        self.vendorID = vendorID
        self.productID = productID
    }
}

public protocol DeviceTransport: Sendable {
    func connect() async throws -> DeviceInfo
    func listFiles(in folder: DeviceFolder) async throws -> [DeviceFile]
    func download(_ file: DeviceFile, to destination: URL) async throws
    func upload(_ source: URL, to folder: DeviceFolder, as filename: String) async throws
    func eject() async throws
    func disconnect() async throws
}
```

`BookManagerCoreTests/Devices/MockTransport.swift`:

```swift
import BookManagerCore
import Foundation

actor MockTransport: DeviceTransport {
    static let deviceInfo = DeviceInfo(name: "Mock Kindle", vendorID: 0x1949, productID: 0x9023)

    private var storage: [String: Data] = [:]
    private(set) var ejected = false
    private var forcedError: Error?

    func add(fileNamed name: String, data: Data, in folder: DeviceFolder = DeviceFolder(path: "Documents")) {
        storage["\(folder.path)/\(name)"] = data
    }

    func fileData(named name: String, in folder: DeviceFolder = DeviceFolder(path: "Documents")) -> Data? {
        storage["\(folder.path)/\(name)"]
    }

    func uploadedFiles() -> [String: Data] { storage }

    func uploadError(_ error: Error) { forcedError = error }

    func connect() async throws -> DeviceInfo { Self.deviceInfo }

    func listFiles(in folder: DeviceFolder) async throws -> [DeviceFile] {
        storage.keys
            .filter { $0.hasPrefix("\(folder.path)/") }
            .map { key in
                let name = String(key.dropFirst("\(folder.path)/".count))
                return DeviceFile(name: name, path: key, size: Int64(storage[key]?.count ?? 0))
            }
            .sorted { $0.name < $1.name }
    }

    func download(_ file: DeviceFile, to destination: URL) async throws {
        guard let data = storage[file.path] else { throw DeviceTransportError.fileNotFound(file.path) }
        try data.write(to: destination)
    }

    func upload(_ source: URL, to folder: DeviceFolder, as filename: String) async throws {
        if let forcedError { throw forcedError }
        let data = try Data(contentsOf: source)
        storage["\(folder.path)/\(filename)"] = data
    }

    func eject() async throws { ejected = true }
    func disconnect() async throws {}
}

enum DeviceTransportError: Error, Equatable {
    case fileNotFound(String)
}
```

(Define `DeviceTransportError` inside `MockTransport.swift` — it is a test-target type.)

- [ ] **Step 4: Run the tests to verify they pass**

Run the focused suite from Step 2. Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add BookManagerCore/Devices/DeviceTransport.swift BookManagerCoreTests/Devices/
git commit -m "feat: device transport protocol with mock transport for tests"
```

---

### Task 2: MTP spike — library integration + `MTPTransport` + USB entitlement (hardware-gated)

**Files:**

- Modify: `project.yml` (add the MTP package)
- Modify: `Config/BookManager.entitlements` (`com.apple.security.device.usb`)
- Create: `BookManagerCore/Devices/MTP/MTPTransport.swift` (includes `MTPTransportFactory`)
- Create: `BookManagerCoreTests/Devices/MTPTransportTests.swift` (compilation/contract smoke, no hardware)

**Interfaces:**

- Consumes: `DeviceTransport`/`DeviceInfo`/`DeviceFile`/`DeviceFolder` (Task 1); the chosen MTP library.
- Produces: `MTPTransport: DeviceTransport` and `public struct MTPTransportFactory { public init(); public func candidates() async throws -> [DeviceInfo]; public func makeTransport(for info: DeviceInfo) throws -> any DeviceTransport }` — used by the app's `DeviceManager` (Task 7).

- [ ] **Step 1: Add the package + entitlement**

Primary: `swift-mtp` (CleanCocoa). In `project.yml`:

```yaml
packages:
  # ... existing ...
  swift-mtp:
    url: https://github.com/CleanCocoa/swift-mtp.git
    branch: main   # if no tagged release resolves, pin a revision instead
```

Add to `BookManagerCore` dependencies: `- package: swift-mtp / product: SwiftMTPAsync`. This package **requires `brew install libmtp`** on the build machine and at runtime (system dylib) — install it and note the dependency in the commit message. If `swift-mtp` fails to build (e.g. Swift version floor above the toolchain), fall back to `MTPKit` (`.package(url: "https://github.com/5j54d93/MTPKit.git", from: "0.1.4")`, product `MTPKit`) and use its `MTPTransport.discover()`/`storages()`/`listChildren(of:in:)`/`download(_:to:)` API instead — the `DeviceTransport` conformance below stays the same shape; only the library calls inside change.

Add to `Config/BookManager.entitlements` (inside the top-level `<dict>`):

```xml
<key>com.apple.security.device.usb</key>
<true/>
```

Run `xcodegen generate --spec project.yml` and build: `xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -derivedDataPath .build/DerivedData build` → BUILD SUCCEEDED (package compiles; `MTPTransport.swift` doesn't exist yet, so gate is just the package + entitlement building).

- [ ] **Step 2: Write the smoke test (compilation contract, no hardware)**

`BookManagerCoreTests/Devices/MTPTransportTests.swift`:

```swift
import Foundation
import Testing
@testable import BookManagerCore

@Suite
struct MTPTransportTests {
    @Test
    func factoryShape() async throws {
        let factory = MTPTransportFactory()
        // No device attached in CI: candidates() must not throw and must not crash.
        let candidates = try? await factory.candidates()
        #expect(candidates != nil)
    }
}
```

Expected to compile and pass with no device attached (candidates → empty or throws a documented no-device error; if the library throws when no device is present, adapt the test to `try?` and assert no crash).

- [ ] **Step 3: Implement `MTPTransport`**

`BookManagerCore/Devices/MTP/MTPTransport.swift` — a single `Sendable` struct wrapping the library behind an actor for I/O isolation. With `SwiftMTPAsync` the mapping is:

- `MTP.initialize()` exactly once (guard with `try?` — the library throws `.alreadyInitialized` on double-init).
- `candidates()` → `MTPSession.detect()` → map each `DetectedDevice` to `DeviceInfo(name: <name>, vendorID: <vendorID raw>, productID: <productID raw>)` (adapt to the actual accessors on integration).
- `makeTransport(for info:)` → `MTPTransport` holding the info.
- `connect()` → `MTPSession(opening: &raw)`; return `DeviceInfo` from the session.
- `listFiles(in folder:)` → resolve the folder: take `session.defaultStorage!`, read `storage.contents()`, find the directory whose name equals `folder.path` (recursively from root if needed — Kindle exposes `Documents` at storage root); return its children as `[DeviceFile]` (skip directories; the scanner filters non-book files).
- `download(_:to:)` → resolve the file object (by path via `storage.resolvePath(_:)`) then `session.download(file, to: destination) { _, _ in .continue }`.
- `upload(_:to:as:)` → `storage.upload(from: source, ...)` (adapt: some libmtp versions require a parent object id — resolve the target folder's object id first and pass it).
- `eject()` → the library's release/eject call (adapt; if only `disconnect` exists, `eject()` = `disconnect()`).
- `disconnect()` → close the session.

With `MTPKit` the mapping is: `MTPTransport.discover()` → transport; `transport.storages()`; `transport.listChildren(of: nil, in: storageID)`; `transport.download(nodeID, to: url)`; upload via the kit's upload API; no explicit eject (disconnect only). Keep every library call inside this file.

- [ ] **Step 4: Build + hardware probe (the spike gate)**

Run: `xcodebuild ... build` → BUILD SUCCEEDED. Then, with the **actual Paperwhite plugged in** (USB, unlocked, "File transfer" MTP mode), probe via a temporary debug entry point (a `#if DEBUG` button on the welcome screen calling `MTPTransportFactory().candidates()` then `makeTransport().connect()` and logging `listFiles(in: Documents)`) OR a temporary `xcodebuild`-runnable snippet. Probe checklist — each item must succeed with a real listing/transfer:

1. `candidates()` returns ≥1 Amazon-vendor device.
2. `connect()` succeeds; `DeviceInfo.name` is non-empty.
3. `listFiles(in: DeviceFolder(path: "Documents"))` returns the books on the device (skip if the device storage name differs — adapt the folder resolution).
4. `download` a small book to `/tmp` and verify byte count > 0.
5. `upload` a 1 KB test file to Documents, then `listFiles` shows it; delete it via Finder/MTP after the probe.
6. `eject()`/`disconnect()` return cleanly.

Record results in the plan's task notes (or a `docs/superpowers/plans/` probe note). **If any checklist item fails with the primary library, switch to the fallback library and re-run the probe. If both fail, STOP and report BLOCKED** with what was tried (do not proceed to UI work on an unverified transport).

- [ ] **Step 5: Verify + commit**

Focused test green (Step 2), full build green. Commit:

```bash
git add project.yml Config/BookManager.entitlements BookManagerCore/Devices/MTP/ BookManagerCoreTests/Devices/MTPTransportTests.swift
git commit -m "feat: MTP transport (swift-mtp/libmtp) with USB entitlement — probe-verified against Paperwhite"
```

(Adjust the message to the library actually chosen.)

---

### Task 3: `DeviceProfile` + `KindlePaperwhite12Profile` + `DeviceRegistry` (Core, TDD)

**Files:**

- Create: `BookManagerCore/Devices/DeviceProfile.swift`
- Create: `BookManagerCore/Devices/DeviceRegistry.swift`
- Create: `BookManagerCoreTests/Devices/DeviceRegistryTests.swift`

**Interfaces:**

- Consumes: `DeviceInfo`, `DeviceFolder` (Task 1).
- Produces:
  - `DeviceProfile` protocol (`Sendable`): `var id: String`, `var displayName: String`, `var supportedFormats: [String]` (lowercase, **priority order**), `var bookFolder: DeviceFolder`, `func matches(_ info: DeviceInfo) -> Bool`.
  - `KindlePaperwhite12Profile` — `id "kindle-paperwhite-12"`, `displayName "Kindle Paperwhite"`, `supportedFormats ["epub", "pdf", "azw3", "txt"]`, `bookFolder DeviceFolder(path: "Documents")`, `matches` = `info.vendorID == 0x1949` (Amazon).
  - `DeviceRegistry { public init(profiles: [any DeviceProfile] = [KindlePaperwhite12Profile()]); public func resolve(_ info: DeviceInfo) -> (any DeviceProfile)? }` — first match wins.

- [ ] **Step 1: Write the failing tests**

`DeviceRegistryTests.swift`:

```swift
import Testing
@testable import BookManagerCore

@Suite
struct DeviceRegistryTests {
    @Test
    func resolvesAmazonVendorToPaperwhiteProfile() {
        let registry = DeviceRegistry()
        let info = DeviceInfo(name: "Kindle", vendorID: 0x1949, productID: 0x9023)
        let profile = registry.resolve(info)
        #expect(profile?.id == "kindle-paperwhite-12")
        #expect(profile?.supportedFormats == ["epub", "pdf", "azw3", "txt"])
        #expect(profile?.bookFolder == DeviceFolder(path: "Documents"))
    }

    @Test
    func unknownVendorIsNotResolved() {
        let registry = DeviceRegistry()
        let info = DeviceInfo(name: "Something Else", vendorID: 0x1234, productID: 0x0001)
        #expect(registry.resolve(info) == nil)
    }

    @Test
    func stubProfileResolvesAlongsideKindle() {
        // Modularity guard: a new device profile is a new file + registry entry.
        struct StubProfile: DeviceProfile {
            let id = "stub-device"
            let displayName = "Stub"
            let supportedFormats = ["epub"]
            let bookFolder = DeviceFolder(path: "Books")
            func matches(_ info: DeviceInfo) -> Bool { info.vendorID == 0xABCD }
        }
        let registry = DeviceRegistry(profiles: [KindlePaperwhite12Profile(), StubProfile()])
        let kindle = registry.resolve(DeviceInfo(name: "K", vendorID: 0x1949, productID: nil))
        let stub = registry.resolve(DeviceInfo(name: "S", vendorID: 0xABCD, productID: nil))
        #expect(kindle?.id == "kindle-paperwhite-12")
        #expect(stub?.id == "stub-device")
    }

    @Test
    func priorityGoesToFirstMatchingProfile() {
        struct CatchAll: DeviceProfile {
            let id = "catch-all"
            let displayName = "Catch"
            let supportedFormats = ["epub"]
            let bookFolder = DeviceFolder(path: "Books")
            func matches(_ info: DeviceInfo) -> Bool { true }
        }
        let registry = DeviceRegistry(profiles: [KindlePaperwhite12Profile(), CatchAll()])
        #expect(registry.resolve(DeviceInfo(name: "K", vendorID: 0x1949, productID: nil))?.id == "kindle-paperwhite-12")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodegen generate --spec project.yml`, then `xcodebuild ... test -only-testing:BookManagerCoreTests/Devices/DeviceRegistryTests`. Expected: FAIL — `DeviceRegistry`/`DeviceProfile` undefined.

- [ ] **Step 3: Implement profiles + registry**

`BookManagerCore/Devices/DeviceProfile.swift`:

```swift
import Foundation

public protocol DeviceProfile: Sendable {
    var id: String { get }
    var displayName: String { get }
    /// Lowercase file extensions, highest priority first (used by SendPlan).
    var supportedFormats: [String] { get }
    var bookFolder: DeviceFolder { get }
    func matches(_ info: DeviceInfo) -> Bool
}

public struct KindlePaperwhite12Profile: DeviceProfile {
    public let id = "kindle-paperwhite-12"
    public let displayName = "Kindle Paperwhite"
    public let supportedFormats = ["epub", "pdf", "azw3", "txt"]
    public let bookFolder = DeviceFolder(path: "Documents")

    public init() {}

    public func matches(_ info: DeviceInfo) -> Bool {
        info.vendorID == 0x1949 // Amazon
    }
}
```

`BookManagerCore/Devices/DeviceRegistry.swift`:

```swift
import Foundation

public struct DeviceRegistry: Sendable {
    private let profiles: [any DeviceProfile]

    public init(profiles: [any DeviceProfile] = [KindlePaperwhite12Profile()]) {
        self.profiles = profiles
    }

    public func resolve(_ info: DeviceInfo) -> (any DeviceProfile)? {
        profiles.first { $0.matches(info) }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Focused suite → PASS. Then the non-perf core suite: `xcodebuild ... test -skip-testing:BookManagerCoreTests/PerformanceTests` → green.

- [ ] **Step 5: Commit**

```bash
git add BookManagerCore/Devices/DeviceProfile.swift BookManagerCore/Devices/DeviceRegistry.swift BookManagerCoreTests/Devices/DeviceRegistryTests.swift
git commit -m "feat: device profiles and registry (Kindle Paperwhite 12)"
```

---

### Task 4: `DeviceBookScanner` (Core, TDD)

**Files:**

- Create: `BookManagerCore/Devices/DeviceBookScanner.swift`
- Create: `BookManagerCoreTests/Devices/DeviceBookScannerTests.swift`

**Interfaces:**

- Consumes: `DeviceTransport`, `DeviceFile`, `DeviceFolder` (Task 1); `MobiReader`/`MobiReaderError` (existing); `MetadataExtractor` (existing: `extract(from:kind:)`, `kind(for:)`); the existing test fixtures `fixture.mobi` (`Bundle.module`, subdirectory `"Fixtures"`) and `Fixtures.makeEPUB(named:)`; the DRM byte-patch technique from `MobiReaderTests.encryptedMobiThrowsDrmError`.
- Produces:
  - `DeviceBookRecord { file: DeviceFile, title: String, authors: [String], format: String, isDRM: Bool }` — `Sendable, Equatable, Identifiable`; `var id: String { file.id }`. `format` is the uppercase extension (e.g. `"AZW3"`, `"EPUB"`, `"KFX"`).
  - `DeviceBookScanner { public init(transport: any DeviceTransport); public func scan(in folder: DeviceFolder) async throws -> [DeviceBookRecord] }`.

- [ ] **Step 1: Write the failing tests**

`DeviceBookScannerTests.swift`:

```swift
import Foundation
import Testing
@testable import BookManagerCore

@Suite
struct DeviceBookScannerTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test
    func scansMobiWithMetadata() async throws {
        let transport = MockTransport()
        let mobiURL = try #require(Bundle.module.url(
            forResource: "fixture", withExtension: "mobi", subdirectory: "Fixtures"
        ))
        await transport.add(fileNamed: "Fixture.mobi", data: try Data(contentsOf: mobiURL))

        let records = try await DeviceBookScanner(transport: transport)
            .scan(in: DeviceFolder(path: "Documents"))

        #expect(records.count == 1)
        let record = try #require(records.first)
        #expect(!record.title.isEmpty)
        #expect(record.format == "MOBI")
        #expect(!record.isDRM)
    }

    @Test
    func marksDrmMobiWithLockFlag() async throws {
        let transport = MockTransport()
        let mobiURL = try #require(Bundle.module.url(
            forResource: "fixture", withExtension: "mobi", subdirectory: "Fixtures"
        ))
        // Mirror MobiReaderTests.encryptedMobiThrowsDrmError's byte patch.
        var data = try Data(contentsOf: mobiURL)
        data[4] = 1 // PalmDOC encryption_type — see the existing test for the exact offset used there
        await transport.add(fileNamed: "Locked.azw3", data: data)

        let records = try await DeviceBookScanner(transport: transport)
            .scan(in: DeviceFolder(path: "Documents"))

        let locked = try #require(records.first { $0.name() == "Locked.azw3" })
        #expect(locked.isDRM)
    }

    @Test
    func scansEpubWithExtractedMetadata() async throws {
        let transport = MockTransport()
        let epubURL = try Fixtures.makeEPUB(named: "scanned.epub")
        defer { try? FileManager.default.removeItem(at: epubURL) }
        await transport.add(fileNamed: "scanned.epub", data: try Data(contentsOf: epubURL))

        let records = try await DeviceBookScanner(transport: transport)
            .scan(in: DeviceFolder(path: "Documents"))

        let record = try #require(records.first)
        #expect(record.format == "EPUB")
        #expect(!record.title.isEmpty)
        #expect(!record.authors.isEmpty)
    }

    @Test
    func listsKfxByFilenameOnlyAndSkipsNonBooks() async throws {
        let transport = MockTransport()
        await transport.add(fileNamed: "Novel.kfx", data: Data("x".utf8))
        await transport.add(fileNamed: "notes.txt", data: Data("y".utf8))
        await transport.add(fileNamed: ".DS_Store", data: Data("z".utf8))
        await transport.add(fileNamed: "archive.zip", data: Data("w".utf8))

        let records = try await DeviceBookScanner(transport: transport)
            .scan(in: DeviceFolder(path: "Documents"))

        #expect(records.map(\.format).sorted() == ["KFX", "TXT"])
    }
}

// Helper so the test reads cleanly; DeviceBookRecord exposes `file`.
private extension DeviceBookRecord {
    func name() -> String { file.name }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodegen generate --spec project.yml`, then `xcodebuild ... test -only-testing:BookManagerCoreTests/Devices/DeviceBookScannerTests`. Expected: FAIL — `DeviceBookScanner` undefined.

- [ ] **Step 3: Implement the scanner**

`BookManagerCore/Devices/DeviceBookScanner.swift`:

```swift
import Foundation

public struct DeviceBookRecord: Sendable, Equatable, Identifiable {
    public let file: DeviceFile
    public let title: String
    public let authors: [String]
    public let format: String
    public let isDRM: Bool

    public init(file: DeviceFile, title: String, authors: [String], format: String, isDRM: Bool) {
        self.file = file
        self.title = title
        self.authors = authors
        self.format = format
        self.isDRM = isDRM
    }

    public var id: String { file.id }
}

public struct DeviceBookScanner: Sendable {
    private static let bookExtensions: Set<String> = ["mobi", "azw", "azw3", "epub", "pdf", "kfx", "prc", "txt"]

    private let transport: any DeviceTransport

    public init(transport: any DeviceTransport) {
        self.transport = transport
    }

    public func scan(in folder: DeviceFolder) async throws -> [DeviceBookRecord] {
        let files = try await transport.listFiles(in: folder)
            .filter { !$0.name.hasPrefix(".") && Self.isBookFile($0) }

        let scratch = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        var records: [DeviceBookRecord] = []
        for file in files {
            let ext = file.name.pathExtension.lowercased()
            let localURL = scratch.appending(path: file.name)
            switch ext {
            case "mobi", "azw", "azw3":
                try? await transport.download(file, to: localURL)
                do {
                    let content = try MobiReader(url: localURL).extract()
                    records.append(DeviceBookRecord(
                        file: file,
                        title: content.title.isEmpty ? stem(of: file.name) : content.title,
                        authors: content.authors,
                        format: ext.uppercased(),
                        isDRM: false
                    ))
                } catch MobiReaderError.drmProtected {
                    records.append(DeviceBookRecord(
                        file: file, title: stem(of: file.name), authors: [],
                        format: ext.uppercased(), isDRM: true
                    ))
                } catch {
                    records.append(DeviceBookRecord(
                        file: file, title: stem(of: file.name), authors: [],
                        format: ext.uppercased(), isDRM: false
                    ))
                }
            case "epub", "pdf":
                try? await transport.download(file, to: localURL)
                let kind = MetadataExtractor.kind(for: localURL)
                let extracted = kind.flatMap { try? MetadataExtractor.extract(from: localURL, kind: $0) }
                records.append(DeviceBookRecord(
                    file: file,
                    title: (extracted.map { $0.title.isEmpty ? stem(of: file.name) : $0.title }) ?? stem(of: file.name),
                    authors: extracted?.authors ?? [],
                    format: ext.uppercased(),
                    isDRM: false
                ))
            default: // kfx, prc, txt — filename-only listing (KFX shown as unsupported by the UI)
                records.append(DeviceBookRecord(
                    file: file, title: stem(of: file.name), authors: [],
                    format: ext.uppercased(), isDRM: false
                ))
            }
        }
        return records
    }

    private static func isBookFile(_ file: DeviceFile) -> Bool {
        bookExtensions.contains(file.name.pathExtension.lowercased())
    }

    private func stem(of name: String) -> String {
        URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
    }
}
```

(Note: `extract(from:kind:)` throws for unreadable files — the `try?` + flatMap keeps the scanner tolerant: unreadable files still list by filename. Verify the exact `MobiReader`/`MetadataExtractor` signatures on integration and adapt the call sites only if the existing tests differ from the above.)

- [ ] **Step 4: Run the tests to verify they pass**

Focused suite → PASS. Then non-perf core suite → green.

- [ ] **Step 5: Commit**

```bash
git add BookManagerCore/Devices/DeviceBookScanner.swift BookManagerCoreTests/Devices/DeviceBookScannerTests.swift
git commit -m "feat: device book scanner with DRM flag"
```

---

### Task 5: `SendPlan` + `FormatConverter` seam (Core, TDD)

**Files:**

- Create: `BookManagerCore/Devices/FormatConverter.swift`
- Create: `BookManagerCore/Devices/SendPlan.swift`
- Create: `BookManagerCoreTests/Devices/SendPlanTests.swift`

**Interfaces:**

- Consumes: `DeviceProfile` (Task 3), `BookFormatRecord` (existing, `kind` is the uppercase format string).
- Produces:
  - `FormatConverter` protocol (`Sendable`): `func canConvert(from sourceFormat: String, to targetFormat: String) -> Bool`; `func convert(_ source: URL, from sourceFormat: String, to targetFormat: String) async throws -> URL`.
  - `IdentityConverter: FormatConverter` — `canConvert` always `false`; `convert` throws `DeviceSendError.conversionUnsupported(from:to:)` (define `DeviceSendError` here; used by Task 6 too).
  - `SendOutcome: Sendable, Equatable` — `.copy(format: String)`, `.convert(from: String, to: String)`, `.noCompatibleFormat`.
  - `SendPlan { public init(profile: any DeviceProfile, converter: any FormatConverter); public func outcome(for formats: [BookFormatRecord]) -> SendOutcome }` — copy if any stored format matches a supported format (profile priority order); else convert if the converter can produce a supported format from a stored one; else `.noCompatibleFormat`.

- [ ] **Step 1: Write the failing tests**

`SendPlanTests.swift`:

```swift
import Foundation
import Testing
@testable import BookManagerCore

@Suite
struct SendPlanTests {
    private let profile = KindlePaperwhite12Profile() // ["epub", "pdf", "azw3", "txt"]

    private func format(_ kind: String) -> BookFormatRecord {
        BookFormatRecord(kind: kind, filename: "f.\(kind.lowercased())", contentHash: "h", size: 1)
    }

    private struct FakeConverter: FormatConverter {
        let conversions: [(from: String, to: String)]
        func canConvert(from sourceFormat: String, to targetFormat: String) -> Bool {
            conversions.contains { $0.from == sourceFormat && $0.to == targetFormat }
        }
        func convert(_ source: URL, from sourceFormat: String, to targetFormat: String) async throws -> URL {
            source
        }
    }

    @Test
    func copyPicksHighestPrioritySupportedFormat() {
        let plan = SendPlan(profile: profile, converter: IdentityConverter())
        let outcome = plan.outcome(for: [format("PDF"), format("EPUB")])
        #expect(outcome == .copy(format: "epub"))
    }

    @Test
    func copyFallsBackToLowerPriorityFormat() {
        let plan = SendPlan(profile: profile, converter: IdentityConverter())
        #expect(plan.outcome(for: [format("AZW3")]) == .copy(format: "azw3"))
    }

    @Test
    func djvuOnlyIsNoCompatibleFormat() {
        let plan = SendPlan(profile: profile, converter: IdentityConverter())
        #expect(plan.outcome(for: [format("DJVU")]) == .noCompatibleFormat)
    }

    @Test
    func converterIsConsultedWhenNoDirectCopy() {
        let fake = FakeConverter(conversions: [("azw3", "epub")])
        let plan = SendPlan(profile: profile, converter: fake)
        #expect(plan.outcome(for: [format("AZW3")]) == .copy(format: "azw3")) // direct copy wins
        let epubOnly = SendPlan(profile: DeviceProfileStub(supported: ["epub"]), converter: fake)
        #expect(epubOnly.outcome(for: [format("AZW3")]) == .convert(from: "azw3", to: "epub"))
    }

    private struct DeviceProfileStub: DeviceProfile {
        let supported: [String]
        var id: String { "stub" }
        var displayName: String { "Stub" }
        var supportedFormats: [String] { supported }
        var bookFolder: DeviceFolder { DeviceFolder(path: "Books") }
        func matches(_ info: DeviceInfo) -> Bool { false }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodegen generate --spec project.yml`, then `xcodebuild ... test -only-testing:BookManagerCoreTests/Devices/SendPlanTests`. Expected: FAIL — undefined symbols.

- [ ] **Step 3: Implement the seam + plan**

`BookManagerCore/Devices/FormatConverter.swift`:

```swift
import Foundation

public protocol FormatConverter: Sendable {
    func canConvert(from sourceFormat: String, to targetFormat: String) -> Bool
    func convert(_ source: URL, from sourceFormat: String, to targetFormat: String) async throws -> URL
}

/// v1: no conversions. The full format-conversion feature (EPUB→MOBI/AZW3, …)
/// plugs in behind this protocol without touching device code.
public struct IdentityConverter: FormatConverter {
    public init() {}
    public func canConvert(from sourceFormat: String, to targetFormat: String) -> Bool { false }
    public func convert(_ source: URL, from sourceFormat: String, to targetFormat: String) async throws -> URL {
        throw DeviceSendError.conversionUnsupported(from: sourceFormat, to: targetFormat)
    }
}

public enum DeviceSendError: Error, Equatable {
    case conversionUnsupported(from: String, to: String)
}
```

`BookManagerCore/Devices/SendPlan.swift`:

```swift
import Foundation

public enum SendOutcome: Sendable, Equatable {
    case copy(format: String)
    case convert(from: String, to: String)
    case noCompatibleFormat
}

public struct SendPlan: Sendable {
    private let profile: any DeviceProfile
    private let converter: any FormatConverter

    public init(profile: any DeviceProfile, converter: any FormatConverter) {
        self.profile = profile
        self.converter = converter
    }

    public func outcome(for formats: [BookFormatRecord]) -> SendOutcome {
        let present = formats.map { $0.kind.lowercased() }
        for target in profile.supportedFormats {
            if present.contains(target.lowercased()) { return .copy(format: target) }
        }
        for source in present {
            for target in profile.supportedFormats where target != source {
                if converter.canConvert(from: source, to: target) {
                    return .convert(from: source, to: target)
                }
            }
        }
        return .noCompatibleFormat
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Focused suite → PASS. Non-perf core suite → green.

- [ ] **Step 5: Commit**

```bash
git add BookManagerCore/Devices/FormatConverter.swift BookManagerCore/Devices/SendPlan.swift BookManagerCoreTests/Devices/SendPlanTests.swift
git commit -m "feat: send plan format matching with conversion seam"
```

---

### Task 6: `DeviceSendService` + `DeviceImportService` + `SendReport` (Core, TDD)

**Files:**

- Create: `BookManagerCore/Devices/SendReport.swift`
- Create: `BookManagerCore/Devices/DeviceSendService.swift`
- Create: `BookManagerCore/Devices/DeviceImportService.swift`
- Create: `BookManagerCoreTests/Devices/DeviceServicesTests.swift`

**Interfaces:**

- Consumes: `DeviceTransport`, `DeviceFile`, `DeviceFolder` (Task 1), `DeviceProfile` (Task 3), `SendPlan`/`SendOutcome`/`FormatConverter`/`DeviceSendError` (Task 5).
- Produces:
  - `SendRequest { title: String, sourceURL: URL, format: String }` (`Sendable`) — `format` is the lowercase extension.
  - `SendStatus: Sendable, Equatable` — `.sent(format: String)`, `.converted(from: String, to: String)`, `.noCompatibleFormat`, `.failed(String)`.
  - `SendItem: Sendable, Identifiable` — `{ id: UUID, title: String, status: SendStatus }`.
  - `SendReport: Sendable` — `{ items: [SendItem] }` with `var sent: [SendItem]`, `var noCompatible: [SendItem]`, `var failed: [SendItem]`, `var summary: String` (mirrors `ImportReport`).
  - `DeviceSendService { public init(transport: any DeviceTransport); public func send(_ requests: [SendRequest], profile: any DeviceProfile, converter: any FormatConverter) async -> [SendItem] }` — per request: if `profile.supportedFormats` contains the format → upload (`.sent`); else if the converter can produce a supported format → convert + upload (`.converted`); else `.noCompatibleFormat`; upload/convert errors → `.failed`. Filename: sanitized `"<title>.<ext>"` (strip `/` and `:`).
  - `DeviceImportService { public init(transport: any DeviceTransport); public func download(_ files: [DeviceFile], to directory: URL) async throws -> [URL] }` — downloads each file into `directory` as its name.

- [ ] **Step 1: Write the failing tests**

`DeviceServicesTests.swift`:

```swift
import Foundation
import Testing
@testable import BookManagerCore

@Suite
struct DeviceServicesTests {
    private let profile = KindlePaperwhite12Profile()

    private func makeFile(_ name: String, bytes: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: name)
        try bytes.write(to: url)
        return url
    }

    private struct ConvertingConverter: FormatConverter {
        func canConvert(from sourceFormat: String, to targetFormat: String) -> Bool {
            sourceFormat == "mobi" && targetFormat == "epub"
        }
        func convert(_ source: URL, from sourceFormat: String, to targetFormat: String) async throws -> URL {
            let out = FileManager.default.temporaryDirectory
                .appending(path: "\(UUID().uuidString).\(targetFormat)")
            try Data("converted".utf8).write(to: out)
            return out
        }
    }

    // MARK: - Send

    @Test
    func sendsSupportedFormatToDocuments() async throws {
        let transport = MockTransport()
        let service = DeviceSendService(transport: transport)
        let epub = try makeFile("book.epub", bytes: Data("epub".utf8))
        defer { try? FileManager.default.removeItem(at: epub) }

        let items = await service.send(
            [SendRequest(title: "Book Title", sourceURL: epub, format: "epub")],
            profile: profile, converter: IdentityConverter()
        )

        #expect(items.count == 1)
        #expect(items[0].status == .sent(format: "epub"))
        let uploaded = await transport.uploadedFiles()
        #expect(uploaded.keys.contains { $0 == "Documents/Book Title.epub" })
        #expect(uploaded["Documents/Book Title.epub"] == Data("epub".utf8))
    }

    @Test
    func reportsNoCompatibleFormatForDjvu() async throws {
        let transport = MockTransport()
        let service = DeviceSendService(transport: transport)
        let djvu = try makeFile("book.djvu", bytes: Data("djvu".utf8))
        defer { try? FileManager.default.removeItem(at: djvu) }

        let items = await service.send(
            [SendRequest(title: "Old Scan", sourceURL: djvu, format: "djvu")],
            profile: profile, converter: IdentityConverter()
        )

        #expect(items[0].status == .noCompatibleFormat)
        #expect(await transport.uploadedFiles().isEmpty)
    }

    @Test
    func convertsViaConverterWhenFormatUnsupported() async throws {
        let transport = MockTransport()
        let service = DeviceSendService(transport: transport)
        let mobi = try makeFile("book.mobi", bytes: Data("mobi".utf8))
        defer { try? FileManager.default.removeItem(at: mobi) }

        let items = await service.send(
            [SendRequest(title: "Converted Book", sourceURL: mobi, format: "mobi")],
            profile: profile, converter: ConvertingConverter()
        )

        #expect(items[0].status == .converted(from: "mobi", to: "epub"))
        let uploaded = await transport.uploadedFiles()
        #expect(uploaded.keys.contains { $0 == "Documents/Converted Book.epub" })
    }

    @Test
    func reportsUploadFailuresPerItem() async throws {
        let transport = MockTransport()
        await transport.uploadError(DeviceTransportError.fileNotFound("x"))
        let service = DeviceSendService(transport: transport)
        let epub = try makeFile("book.epub", bytes: Data("epub".utf8))
        defer { try? FileManager.default.removeItem(at: epub) }

        let items = await service.send(
            [SendRequest(title: "Fails", sourceURL: epub, format: "epub")],
            profile: profile, converter: IdentityConverter()
        )

        guard case .failed = items[0].status else {
            Issue.record("expected failure, got \(items[0].status)")
            return
        }
        #expect(SendReport(items: items).summary.contains("1 failed"))
    }

    // MARK: - Import

    @Test
    func downloadsSelectedFilesToDirectory() async throws {
        let transport = MockTransport()
        await transport.add(fileNamed: "A.azw3", data: Data("aaa".utf8))
        await transport.add(fileNamed: "B.epub", data: Data("bbb".utf8))

        let service = DeviceImportService(transport: transport)
        let files = try await transport.listFiles(in: DeviceFolder(path: "Documents"))
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let urls = try await service.download(files, to: dir)

        #expect(urls.count == 2)
        #expect(try Data(contentsOf: dir.appending(path: "A.azw3")) == Data("aaa".utf8))
        #expect(try Data(contentsOf: dir.appending(path: "B.epub")) == Data("bbb".utf8))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodegen generate --spec project.yml`, then `xcodebuild ... test -only-testing:BookManagerCoreTests/Devices/DeviceServicesTests`. Expected: FAIL — undefined symbols.

- [ ] **Step 3: Implement report + services**

`BookManagerCore/Devices/SendReport.swift`:

```swift
import Foundation

public enum SendStatus: Sendable, Equatable {
    case sent(format: String)
    case converted(from: String, to: String)
    case noCompatibleFormat
    case failed(String)
}

public struct SendItem: Sendable, Identifiable {
    public let id: UUID
    public let title: String
    public let status: SendStatus

    public init(id: UUID = UUID(), title: String, status: SendStatus) {
        self.id = id
        self.title = title
        self.status = status
    }
}

public struct SendReport: Sendable {
    public let items: [SendItem]

    public init(items: [SendItem]) { self.items = items }

    public var sent: [SendItem] {
        items.filter { if case .sent = $0.status { return true }; return false }
    }
    public var noCompatible: [SendItem] {
        items.filter { if case .noCompatibleFormat = $0.status { return true }; return false }
    }
    public var failed: [SendItem] {
        items.filter { if case .failed = $0.status { return true }; return false }
    }
    public var summary: String {
        "\(sent.count) sent, \(noCompatible.count) no compatible format, \(failed.count) failed"
    }
}
```

`BookManagerCore/Devices/DeviceSendService.swift`:

```swift
import Foundation

public struct SendRequest: Sendable {
    public let title: String
    public let sourceURL: URL
    public let format: String // lowercase extension

    public init(title: String, sourceURL: URL, format: String) {
        self.title = title
        self.sourceURL = sourceURL
        self.format = format
    }
}

public struct DeviceSendService: Sendable {
    private let transport: any DeviceTransport

    public init(transport: any DeviceTransport) {
        self.transport = transport
    }

    public func send(
        _ requests: [SendRequest],
        profile: any DeviceProfile,
        converter: any FormatConverter
    ) async -> [SendItem] {
        var items: [SendItem] = []
        for request in requests {
            do {
                let format = request.format.lowercased()
                if profile.supportedFormats.contains(format) {
                    try await transport.upload(
                        request.sourceURL,
                        to: profile.bookFolder,
                        as: Self.filename(for: request, format: format)
                    )
                    items.append(SendItem(title: request.title, status: .sent(format: format)))
                } else if let target = profile.supportedFormats.first(where: {
                    converter.canConvert(from: format, to: $0)
                }) {
                    let converted = try await converter.convert(request.sourceURL, from: format, to: target)
                    try await transport.upload(
                        converted,
                        to: profile.bookFolder,
                        as: Self.filename(for: request, format: target)
                    )
                    items.append(SendItem(title: request.title, status: .converted(from: format, to: target)))
                } else {
                    items.append(SendItem(title: request.title, status: .noCompatibleFormat))
                }
            } catch {
                items.append(SendItem(title: request.title, status: .failed(error.localizedDescription)))
            }
        }
        return items
    }

    static func filename(for request: SendRequest, format: String) -> String {
        let base = request.title
            .replacingOccurrences(of: "/", with: " ")
            .replacingOccurrences(of: ":", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return base.isEmpty ? "book" : "\(base).\(format)"
    }
}
```

`BookManagerCore/Devices/DeviceImportService.swift`:

```swift
import Foundation

public struct DeviceImportService: Sendable {
    private let transport: any DeviceTransport

    public init(transport: any DeviceTransport) {
        self.transport = transport
    }

    public func download(_ files: [DeviceFile], to directory: URL) async throws -> [URL] {
        var urls: [URL] = []
        for file in files {
            let destination = directory.appending(path: file.name)
            try await transport.download(file, to: destination)
            urls.append(destination)
        }
        return urls
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Focused suite → PASS. Non-perf core suite → green.

- [ ] **Step 5: Commit**

```bash
git add BookManagerCore/Devices/SendReport.swift BookManagerCore/Devices/DeviceSendService.swift BookManagerCore/Devices/DeviceImportService.swift BookManagerCoreTests/Devices/DeviceServicesTests.swift
git commit -m "feat: device send and import services with reports"
```

---

### Task 7: App — `DeviceManager` + sidebar Devices section + `DeviceBooksView` (browse/import/eject)

**Files:**

- Create: `BookManager/Stores/DeviceManager.swift`
- Create: `BookManager/Views/DeviceBooksView.swift`
- Modify: `BookManager/Stores/LibrarySession.swift` (device selection + accessors)
- Modify: `BookManager/Views/SidebarView.swift` (Devices section + selection)
- Modify: `BookManager/Views/ContentView.swift` (detail switch + device import report trigger)

**Interfaces:**

- Consumes: `DeviceRegistry`, `DeviceTransport`, `DeviceProfile`, `DeviceInfo`, `DeviceBookScanner`, `DeviceBookRecord`, `DeviceImportService`, `MTPTransportFactory` (Tasks 1–6), `LibrarySession.importFiles(urls:)`, `ImportReport` (existing).
- Produces (app target):
  - `DeviceManager` — `@MainActor @Observable final class`, owned by `LibrarySession` as `let devices = DeviceManager()`:
    - `struct ConnectedDevice: Identifiable { let id: UUID; let name: String; let info: DeviceInfo; let profile: any DeviceProfile; let transport: any DeviceTransport }`
    - `private(set) var devices: [ConnectedDevice]`; `private(set) var selectedDeviceID: UUID?`; `private(set) var deviceBooks: [DeviceBookRecord]`; `private(set) var isScanning = false`; `private(set) var isListing = false`; `private(set) var deviceError: String?`
    - `func scanForDevices() async` — enumerate `MTPTransportFactory().candidates()`, keep profiles the registry resolves, connect new ones, drop disconnected; clears `selectedDeviceID` if its device vanished.
    - `func select(_ id: UUID?) async` — set `selectedDeviceID`; when non-nil, `refreshBooks()`.
    - `func refreshBooks() async` — scanner over the selected device's transport in `profile.bookFolder`.
    - `func download(_ files: [DeviceFile]) async throws -> [URL]` — temp dir + `DeviceImportService`.
    - `func eject(_ id: UUID) async` — `transport.eject()`, remove from `devices`, clear selection.
  - `LibrarySession` gains `var selectedDeviceID: UUID? { get set }` (delegating to `devices.selectedDeviceID`) and `func selectDevice(_ id: UUID?)` (clears `selectedFacet` when a device is chosen). `let devices = DeviceManager()`.
  - `DeviceBooksView` — table (Title, Author, Format, Size), DRM lock badge (`Image(systemName: "lock")` when `isDRM`), "unsupported" caption when `format == "KFX"`, toolbar: **Import Selected**, **Import All**, **Refresh**, **Eject**; empty state (`ContentUnavailableView`) and error state.

- [ ] **Step 1: Implement `DeviceManager`**

`BookManager/Stores/DeviceManager.swift`:

```swift
import BookManagerCore
import Foundation
import Observation

@MainActor
@Observable
final class DeviceManager {
    struct ConnectedDevice: Identifiable {
        let id: UUID
        let name: String
        let info: DeviceInfo
        let profile: any DeviceProfile
        let transport: any DeviceTransport
    }

    private(set) var devices: [ConnectedDevice] = []
    private(set) var selectedDeviceID: UUID?
    private(set) var deviceBooks: [DeviceBookRecord] = []
    private(set) var isScanning = false
    private(set) var isListing = false
    private(set) var deviceError: String?

    private let registry = DeviceRegistry()
    private let factory = MTPTransportFactory()

    func scanForDevices() async {
        isScanning = true
        defer { isScanning = false }
        do {
            let candidates = try await factory.candidates()
            var fresh: [ConnectedDevice] = []
            for info in candidates {
                guard registry.resolve(info) != nil else { continue }
                if let existing = devices.first(where: { $0.info == info }) {
                    fresh.append(existing)
                } else {
                    let transport = try factory.makeTransport(for: info)
                    let connected = try await transport.connect()
                    guard let profile = registry.resolve(connected) else { continue }
                    fresh.append(ConnectedDevice(
                        id: UUID(), name: connected.name, info: connected,
                        profile: profile, transport: transport
                    ))
                }
            }
            devices = fresh
            if let selected = selectedDeviceID, !devices.contains(where: { $0.id == selected }) {
                selectedDeviceID = nil
                deviceBooks = []
            }
        } catch {
            deviceError = error.localizedDescription
        }
    }

    func select(_ id: UUID?) async {
        selectedDeviceID = id
        deviceBooks = []
        if id != nil { await refreshBooks() }
    }

    func refreshBooks() async {
        guard let id = selectedDeviceID,
              let device = devices.first(where: { $0.id == id }) else { return }
        isListing = true
        defer { isListing = false }
        do {
            deviceBooks = try await DeviceBookScanner(transport: device.transport)
                .scan(in: device.profile.bookFolder)
        } catch {
            deviceError = error.localizedDescription
        }
    }

    func download(_ files: [DeviceFile]) async throws -> [URL] {
        guard let id = selectedDeviceID,
              let device = devices.first(where: { $0.id == id }) else {
            throw DeviceManagerError.noDeviceSelected
        }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try await DeviceImportService(transport: device.transport).download(files, to: directory)
    }

    func eject(_ id: UUID) async {
        guard let device = devices.first(where: { $0.id == id }) else { return }
        do {
            try await device.transport.eject()
            devices.removeAll { $0.id == id }
            if selectedDeviceID == id { selectedDeviceID = nil; deviceBooks = [] }
        } catch {
            deviceError = error.localizedDescription
        }
    }
}

enum DeviceManagerError: Error {
    case noDeviceSelected
}
```

- [ ] **Step 2: Wire `LibrarySession` + `SidebarView`**

`LibrarySession` — add alongside the existing facet state:

```swift
// Device support
let devices = DeviceManager()
var selectedDeviceID: UUID? {
    get { devices.selectedDeviceID }
    set { devices.selectedDeviceID = newValue }
}
func selectDevice(_ id: UUID?) {
    if id != nil { selectedFacet = nil }
    selectedDeviceID = id
}
```

`SidebarView` — add a Devices section above "All Books" and switch the List selection binding to a sidebar-item enum:

```swift
enum SidebarItem: Hashable {
    case allBooks
    case facet(LibrarySession.FacetSelection)
    case device(UUID)
}
```

The `List(selection:)` binding maps: get → `.device(id)` if `session.selectedDeviceID != nil`, else `.facet(f)` if `session.selectedFacet != nil`, else `.allBooks`; set → `.device(id)` → `session.selectDevice(id)`; `.facet(f)` → `session.selectDevice(nil); session.selectFacet(f)`; `.allBooks` → `session.selectDevice(nil); session.selectFacet(nil)`. Existing rows retag: All Books → `SidebarItem.allBooks`; each `FacetRow` → `.facet(LibrarySession.FacetSelection(type:value:))`. New section:

```swift
if !session.devices.devices.isEmpty {
    Section("Devices") {
        ForEach(session.devices.devices) { device in
            Label(device.name, systemImage: "externaldrive")
                .tag(SidebarItem.device(device.id))
        }
    }
}
```

- [ ] **Step 3: Detail switch + device import in `ContentView`**

In `loadedBody`'s `NavigationSplitView` detail:

```swift
Group {
    if session.selectedDeviceID != nil {
        DeviceBooksView(session: session)
    } else {
        browser
    }
}
```

`DeviceBooksView` (new file) — full view:

```swift
struct DeviceBooksView: View {
    @Bindable var session: LibrarySession
    @State private var selection = Set<String>() // DeviceBookRecord ids

    var body: some View {
        Group {
            if let error = session.devices.deviceError, session.devices.deviceBooks.isEmpty {
                ContentUnavailableView {
                    Label("Couldn't Read Device", systemImage: "externaldrive.badge.exclamationmark")
                } description: { Text(error) } actions: {
                    Button("Scan Again") { Task { await session.devices.scanForDevices() } }
                }
            } else if session.devices.deviceBooks.isEmpty {
                ContentUnavailableView {
                    Label("No Books on Device", systemImage: "books.vertical")
                } description: {
                    Text(session.devices.isListing ? "Reading the device…" : "Send books from your library, or copy them onto the Kindle another way.")
                }
            } else {
                Table(session.devices.deviceBooks, selection: $selection) {
                    TableColumn("Title") { record in
                        HStack(spacing: 6) {
                            if record.isDRM { Image(systemName: "lock").foregroundStyle(.secondary) }
                            Text(record.title)
                            if record.format == "KFX" {
                                Text("unsupported").font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                    TableColumn("Author") { Text(record.authors.joined(separator: ", ")) }
                    TableColumn("Format") { Text(record.format) }
                    TableColumn("Size") { Text(ByteCountFormatter.string(fromByteCount: record.file.size, countStyle: .file)) }
                }
            }
        }
        .navigationTitle(session.devices.devices.first { $0.id == session.selectedDeviceID }?.name ?? "Device")
        .toolbar {
            ToolbarItemGroup {
                Button("Import Selected") { importSelected() }
                    .disabled(selection.isEmpty || session.devices.isListing)
                Button("Import All") { importAll() }
                    .disabled(session.devices.deviceBooks.isEmpty)
                Button {
                    if let id = session.selectedDeviceID { Task { await session.devices.refreshBooks() } }
                } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                Button {
                    if let id = session.selectedDeviceID { Task { await session.devices.eject(id) } }
                } label: { Label("Eject", systemImage: "eject") }
            }
        }
    }

    private func importFiles(_ files: [DeviceFile]) {
        Task {
            do {
                let urls = try await session.devices.download(files)
                await session.importFiles(urls: urls)
            } catch {
                session.devices.deviceError = error.localizedDescription
            }
        }
    }

    private func importSelected() {
        let files = session.devices.deviceBooks
            .filter { selection.contains($0.id) }
            .map(\.file)
        importFiles(files)
    }

    private func importAll() {
        importFiles(session.devices.deviceBooks.map(\.file))
    }
}
```

(`DeviceFile`/`DeviceBookRecord` need `import BookManagerCore` — already imported by the view file header. `session.devices.deviceError` is `private(set)` — add a `var` setter access or an app-internal `func reportError(_:)` on `DeviceManager`; simplest: change `deviceError` to `var deviceError: String?` with an internal setter (it is `@Observable` so mutation is fine).)

In `ContentView`, after `session.importFiles(urls:)` flows, the existing `showImportReport` sheet already presents when `session.importReport != nil` — device imports reuse it; set `showImportReport = session.importReport != nil` inside the device import completion (the `DeviceBooksView.importFiles` path above already calls `session.importFiles`; flip the sheet via the existing `@State showImportReport` in `ContentView` by observing `session.importReport` — add `.onChange(of: session.importReport) { _, new in if new != nil { showImportReport = true } }` to the root view).

Also wire **scan-on-activation**: in `ContentView`'s existing `onReceive(NSApplication.didBecomeActiveNotification)`, add `Task { await session.devices.scanForDevices() }` next to `reconnectIfNeeded()`.

- [ ] **Step 4: Build + verify**

Run: `xcodegen generate --spec project.yml` (new app files), `xcodebuild ... build` → BUILD SUCCEEDED. Manual: run the app with the Paperwhite connected → device row appears in the sidebar after activation/scan; selecting it lists the device's books (DRM badge on Amazon-purchased AZW3/KFX). Commit only after build + a successful manual browse against the real device (spike already proved transport).

- [ ] **Step 5: Commit**

```bash
git add BookManager/Stores/DeviceManager.swift BookManager/Views/DeviceBooksView.swift BookManager/Stores/LibrarySession.swift BookManager/Views/SidebarView.swift BookManager/Views/ContentView.swift
git commit -m "feat: device sidebar section with browse and import UI"
```

---

### Task 8: App — send to device (toolbar, menu, drag, report)

**Files:**

- Modify: `BookManager/Views/ContentView.swift` (Send toolbar button/menu, device-row drop, send-report sheet)
- Modify: `BookManager/Stores/LibrarySession.swift` (`sendSelectionToDevice()`, `sendFiles(urls:)`)
- Modify: `BookManager/Views/BookTableView.swift` / `BookManager/Views/CoverGridView.swift` (drag-out)
- Create: `BookManager/Views/SendReportView.swift`

**Interfaces:**

- Consumes: `SendRequest`, `DeviceSendService`, `SendReport`, `SendItem`, `SendStatus`, `IdentityConverter` (Tasks 5–6), `DeviceManager` (Task 7), `BookFolder.formatFileURL(relativePath:filename:)` + `IndexedBook.formats`/`relativePath` (existing).
- Produces: `LibrarySession.sendSelectionToDevice() async` and `LibrarySession.sendFiles(urls: [URL]) async` — both build `[SendRequest]`, call `session.devices.send(...)` (add `func send(_ requests: [SendRequest]) async` on `DeviceManager` that runs `DeviceSendService(transport:).send(requests, profile:converter: IdentityConverter())` and stores `sendReport`), and set `devices.sendReportPresented = true`.

- [ ] **Step 1: Add `send` to `DeviceManager` + session methods**

`DeviceManager` additions:

```swift
private(set) var sendReport: SendReport?
var sendReportPresented = false

func send(_ requests: [SendRequest]) async {
    guard let id = selectedDeviceID,
          let device = devices.first(where: { $0.id == id }) else { return }
    let service = DeviceSendService(transport: device.transport)
    sendReport = SendReport(items: await service.send(
        requests, profile: device.profile, converter: IdentityConverter()
    ))
    sendReportPresented = true
}
```

`LibrarySession` additions:

```swift
func sendSelectionToDevice() async {
    guard let repository else { return }
    let folder = BookFolder(layout: .init(root: repository.root))
    let selectedBooks = books.filter { selection.contains($0.id) }
    var requests: [SendRequest] = []
    for book in selectedBooks {
        // Best stored format per book, in profile priority order, resolved to its file URL.
        for format in devices.selectedDevice?.profile.supportedFormats ?? [] {
            guard let record = book.formats.first(where: { $0.kind.lowercased() == format }) else { continue }
            let url = folder.formatFileURL(relativePath: book.relativePath, filename: record.filename)
            if FileManager.default.fileExists(atPath: url.path) {
                requests.append(SendRequest(title: book.title, sourceURL: url, format: format))
                break
            }
        }
    }
    await devices.send(requests)
}

func sendFiles(urls: [URL]) async {
    var requests: [SendRequest] = []
    for url in urls {
        let format = url.pathExtension.lowercased()
        guard !format.isEmpty else { continue }
        requests.append(SendRequest(
            title: url.deletingPathExtension().lastPathComponent,
            sourceURL: url, format: format
        ))
    }
    await devices.send(requests)
}
```

(`devices.selectedDevice` — add a computed `var selectedDevice: ConnectedDevice?` to `DeviceManager`.)

- [ ] **Step 2: Toolbar button + menu + report sheet in `ContentView`**

Toolbar (in `loadedBody`'s existing `ToolbarItemGroup`, before Diagnostics):

```swift
if session.devices.devices.isEmpty {
    EmptyView()
} else if session.devices.devices.count == 1 {
    Button {
        Task { await session.sendSelectionToDevice() }
    } label: { Label("Send to Device", systemImage: "arrow.up.doc") }
    .disabled(session.selection.isEmpty)
} else {
    Menu {
        ForEach(session.devices.devices) { device in
            Button(device.name) {
                Task {
                    await session.devices.select(device.id)
                    await session.sendSelectionToDevice()
                }
            }
        }
    } label: { Label("Send to Device", systemImage: "arrow.up.doc") }
    .disabled(session.selection.isEmpty)
}
```

Send-report sheet next to the import-report sheet:

```swift
.sheet(isPresented: $session.devices.sendReportPresented) {
    if let report = session.devices.sendReport {
        SendReportView(report: report) { session.devices.sendReportPresented = false }
    }
}
```

Device-row drop support in `SidebarView` (each device row gets):

```swift
.onDrop(of: [.fileURL], isTargeted: nil) { providers in
    handleDrop(providers, deviceID: device.id)
}
```

with a helper that loads URLs (same `loadURL(from:)` pattern as `ContentView.handleDrop`) then `Task { await session.devices.select(device.id); await session.sendFiles(urls: urls) }`. Put `loadURL(from:)` on `LibrarySession` (or duplicate the small `withCheckedContinuation` helper in `SidebarView`) — prefer moving it to `LibrarySession` as `static func loadURL(from: NSItemProvider) async -> URL?` and reuse in both views.

- [ ] **Step 3: Drag-out from library rows**

`BookTableView` and `CoverGridView`: give each book row/cell `.onDrag { NSItemProvider(object: url as NSURL) }` providing the book's primary format file URL (first `book.formats` record resolved via `BookFolder` with the session's layout — add `func formatFileURL(for book: IndexedBook) -> URL?` to `LibrarySession` returning the first existing format file). This makes library rows draggable onto the sidebar device row; dropping on a device triggers `sendFiles`.

- [ ] **Step 4: `SendReportView`**

New file mirroring `ImportReportView`:

```swift
struct SendReportView: View {
    let report: SendReport
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Send to Device").font(.headline).padding()
            List {
                Text(report.summary).font(.subheadline).foregroundStyle(.secondary)
                if !report.sent.isEmpty {
                    Section("Sent") { ForEach(report.sent, id: \.id) { row($0, icon: "checkmark.circle", color: .green) } }
                }
                if !report.noCompatible.isEmpty {
                    Section("No compatible format") { ForEach(report.noCompatible, id: \.id) { row($0, icon: "exclamationmark.circle", color: .orange) } }
                }
                if !report.failed.isEmpty {
                    Section("Failed") { ForEach(report.failed, id: \.id) { row($0, icon: "xmark.circle", color: .red) } }
                }
            }
            HStack { Spacer(); Button("Done") { onDone() }.buttonStyle(.borderedProminent).padding() }
        }
        .frame(minWidth: 480, minHeight: 320)
    }

    private func row(_ item: SendItem, icon: String, color: Color) -> some View {
        HStack {
            Image(systemName: icon).foregroundStyle(color)
            Text(item.title)
        }
    }
}
```

- [ ] **Step 5: Build + manual verify**

Run: `xcodebuild ... build` → BUILD SUCCEEDED. Manual against the real device: select a library EPUB → Send to Device → it appears in the device list; drag a table row onto the device row in the sidebar → copied; a DJVU-only book → "No compatible format" in the report; eject works.

- [ ] **Step 6: Commit**

```bash
git add BookManager/Views/ContentView.swift BookManager/Stores/LibrarySession.swift BookManager/Stores/DeviceManager.swift BookManager/Views/BookTableView.swift BookManager/Views/CoverGridView.swift BookManager/Views/SendReportView.swift BookManager/Views/SidebarView.swift
git commit -m "feat: send books to device (toolbar, menu, drag-and-drop) with report"
```

---

### Task 9: Full verification + docs

**Files:**

- Modify: `README.md` (Slices section — add device support as implemented)
- No code changes unless a test surfaces a gap.

- [ ] **Step 1: Full suite**

Run: `xcodegen generate --spec project.yml` then `xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -derivedDataPath .build/DerivedData test -skip-testing:BookManagerCoreTests/PerformanceTests` → all green (existing + new `Devices/` suites).

- [ ] **Step 2: Real-device E2E checklist**

With the Paperwhite connected, walk: (1) launch → device appears in sidebar; (2) click device → books listed, DRM badges correct; (3) import a DRM-free sideloaded book → lands in library as EPUB with metadata; (4) import an Amazon DRM'd book → fails with "DRM-protected book", badge shown; (5) select a library EPUB → Send to Device → appears on device; (6) drag a book onto the device row → copied; (7) a DJVU-only book → "No compatible format"; (8) Eject → row disappears; device safe to unplug. Note any failures and fix before committing.

- [ ] **Step 3: README slice note**

Add to the Slices section:

```
5. **Device support** — implemented (Kindle Paperwhite MTP: sidebar device, browse, import DRM-free, send native formats; modular DeviceTransport × DeviceProfile; FormatConverter seam for full conversion)
```

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: device support slice note; full suite green"
```

---

## Self-Review

- **Spec coverage:** sidebar/Finder behavior + selection → Tasks 7–8; browse device books + DRM badge + KFX note → Task 4 (scanner) + Task 7 (view); import off device via existing pipeline → Task 6 (`DeviceImportService`) + Task 7 (reuses `session.importFiles` + `ImportReportView`); send to device (toolbar, menu, drag) → Task 8; `SendPlan` native-format matching + no-compatible reporting → Tasks 5–6, 8; `FormatConverter` seam for later full conversion → Task 5 (protocol + `IdentityConverter`), exercised in Tasks 5–6 tests; modular device support (`DeviceTransport` × `DeviceProfile` + registry) → Tasks 1, 3, 2 (MTP), stub-profile modularity test → Task 3; eject → Tasks 2 (transport), 7 (UI); USB entitlement → Task 2; detection on activation + manual scan → Task 7; error handling (per-file failures, connection errors) → Tasks 6–7; testing (MockTransport, fixtures incl. DRM path, manual E2E) → Tasks 1, 4, 6, 9.
- **Placeholder scan:** no TBDs. Task 2's library-API calls are adapt-on-integration guidance (the spike's whole point — the package is chosen and probed there); every other task has complete code. The "mirror MobiReaderTests byte patch" reference points at existing repo code with the offset noted.
- **Type consistency:** `DeviceTransport`/`DeviceFile`/`DeviceFolder`/`DeviceInfo` (Task 1) are consumed unchanged in Tasks 2–7; `DeviceProfile`/`KindlePaperwhite12Profile`/`DeviceRegistry` (Task 3) in Tasks 5–8; `DeviceBookRecord`/`DeviceBookScanner` (Task 4) in Task 7; `SendOutcome`/`SendPlan`/`FormatConverter`/`IdentityConverter`/`DeviceSendError` (Task 5) in Tasks 6, 8; `SendRequest`/`SendItem`/`SendStatus`/`SendReport`/`DeviceSendService`/`DeviceImportService` (Task 6) in Tasks 7–8; `DeviceManager`/`ConnectedDevice` (Task 7) in Task 8. No name drift (`DeviceImportService.download`, `DeviceSendService.send`, `sendFiles`, `sendSelectionToDevice` all match their definitions).
- **Risks noted:** MTP library choice and sandbox viability are gated by the Task 2 hardware probe (primary swift-mtp/libmtp with a Homebrew system dependency; fallback pure-Swift MTPKit; BLOCKED protocol if both fail); Kindle storage/folder naming quirks adapt inside `MTPTransport` only; `MetadataExtractor`/`MobiReader` signatures verified on integration; the app target has no unit tests, so `DeviceManager` orchestration is thin by design with all logic in tested core services.

# Device Support: Kindle (MTP) — Design

> **Status:** Approved 2026-08-02 (approach A: driver/transport separation; v1 = native-format copy, full format conversion is a later feature with a defined seam).
> **Goal:** connect a Kindle Paperwhite (12th gen, MTP) so it appears in the sidebar like a removable drive in Finder; click it to browse the books on the device; import DRM-free books into the library; send library books to the device (native formats in v1, full conversion later); eject. The device layer must be modular enough that Nook, other Kindle models, reMarkable 2, etc. are new files, not shared-code edits.

## Verified research basis

- **MTP is the transport for modern Kindles**: Paperwhite 12 (2024), Colorsoft, Scribe since fw 5.16.3, and 2024+ models expose MTP (Media Transfer Protocol), not USB mass storage. Kindle firmware since 2022 natively reads **EPUB** (so send-to-device is mostly a copy for the Paperwhite). Older Kindles (Keyboard → Oasis ≤2023) are USB mass-storage volumes under `/Volumes` with a `documents/` folder — a different, simpler transport (later).
- **Calibre's MTP driver uses libmtp** (Python bindings) with hardcoded Kindle vendor/product IDs and a `Documents` target folder; formats `['epub', 'azw3', 'mobi', 'pdf']`. libmtp is the battle-tested reference; a Swift wrapper (`CleanCocoa/swift-mtp`) exists via SPM. Fallback: `MTPKit` (5j54d93) — pure Swift, speaks MTP directly through `IOUSBHost` (no C deps, sandbox-friendly). Both are community-maintained; **the plan's step 0 is a spike** — one MTP transport implementation behind the protocol, library choice validated against a real Paperwhite (build, enumerate, transfer) before UI work. If neither works in the sandbox with `com.apple.security.device.usb`, escalate (documented fallbacks: non-sandboxed debug build; libmtp via bundled dylib).
- **DRM**: already solved for import — `MobiReader` detects `encryption_type != 0` in record 0 and throws `MobiReaderError.drmProtected`; `ImportService.message(for:)` maps it to "DRM-protected book". `MobiToEpubConverter` (AZW/MOBI→EPUB) already exists and is reused unchanged for copy-off-device.
- **No Swift EPUB→MOBI writer exists** (libmobi-swift is read-only; KindleGen dead; Send-to-Kindle converts server-side). Full conversion is therefore a **later feature**, with the `FormatConverter` seam defined now so it lands without touching device code.
- **App constraints**: sandboxed (user-selected read-write + app-scope bookmarks) → MTP/USB needs the `com.apple.security.device.usb` entitlement. Swift 6 strict concurrency — transports must be Sendable/actor-safe. Existing patterns to reuse: staged `ImportService` pipeline, `BookFolder`, `CalibreImportView` wizard→report UI, `LibrarySession` as the single `@MainActor @Observable` store, `NavigationSplitView` sidebar.

## Requirements

1. **Sidebar like Finder**: a Devices section at the top of the sidebar lists connected devices; each row shows a drive icon + name; selecting a device switches the detail area to a device-books browser; ejecting/removing removes the row.
2. **Browse the device**: the device view lists the books on the device (title, author, format, size), with a **lock badge on DRM'd files** and an "unsupported" note for KFX. Refresh + Eject buttons.
3. **Copy off device** ("Import Selected"/"Import All"): DRM-free books download and flow through the existing `ImportService` pipeline (AZW/MOBI → EPUB conversion, metadata, dedupe, canonical folder); DRM'd books fail with the existing clear "DRM-protected book" message. Report reuses `ImportReportView`.
4. **Send to device**: select books → "Send to Device" (toolbar button + menu command) or **drag library rows onto the device row in the sidebar**. `SendPlan` picks the best format the device accepts (Paperwhite: EPUB > PDF > AZW3) and copies to `Documents`. Books with no compatible format (e.g. DJVU-only) get an explicit "no compatible format" row in a send report. v1 copies native formats only.
5. **Conversion seam**: `FormatConverter` protocol at the send boundary. v1 ships identity (copy). The later full-conversion feature implements EPUB→MOBI etc. behind this seam without touching device code.
6. **Modular device support**: `DeviceTransport` (how bytes move) × `DeviceProfile` (what a device is, incl. vendor/product matching, supported formats, Documents folder). `DeviceRegistry` pairs detected devices with profiles. New devices = new transport/profile files + registry entries. Old-Kindle USBMS = `VolumeTransport` + a profile, later.

## Architecture

- **Dependency**: MTP library via SPM (`project.yml` packages + `BookManagerCore` dependency + `xcodegen generate`), chosen by the step-0 spike (primary: `swift-mtp`/libmtp; fallback: `MTPKit`). Isolated entirely inside `MTPTransport`.
- **Core** (`BookManagerCore/Devices/`):
  - `DeviceTransport.swift` — protocol + models: `DeviceFile { name, path, size, format, isDRM? }`, `DeviceFolder`; async `listFiles`, `download(_:to:)`, `upload(_:to:as:)`, `eject`, `disconnect`; connection info (name, free space when available).
  - `MTP/MTPTransport.swift` — the spike-validated MTP implementation (library seam; one file).
  - `DeviceProfile.swift` — protocol + `KindlePaperwhite12Profile` (vendor `0x1949`, formats `[epub, azw3, pdf, txt]`, `Documents` target folder, storage-name matching).
  - `DeviceRegistry.swift` — detection: enumerate USB/MTP devices, match against known profiles → connected-device descriptions.
  - `DeviceBookScanner.swift` — walks the device's book folder → `[DeviceBookRecord]`; uses `MobiReader` (metadata + DRM flag) for AZW/MOBI, `MetadataExtractor` for EPUB/PDF, filename fallback; KFX listed with unsupported note; ignores dot-files/.sdr sidecars.
  - `SendPlan.swift` — pure function: input (book, stored formats, device profile) → copy, or "no compatible format"; format priority per profile.
  - `FormatConverter.swift` — protocol + `IdentityConverter` (v1).
  - `MockTransport` in the test target.
- **App**:
  - `Stores/DeviceManager.swift` — `@MainActor @Observable`; owns registry + live connections; detection on app activation (existing `didBecomeActive` hook), a low-frequency timer while running, and a manual "Scan for Devices" sidebar action. IOKit push detection = polish, not v1.
  - `Views/DeviceBooksView.swift` — table, DRM badge, Import Selected/All, Refresh, Eject; selection + import/send reports.
  - `SidebarView.swift` — Devices section (top), selection model gains a `.device(UUID)` case.
  - `ContentView.swift` — detail switch (library browser ↔ device view), "Send to Device" toolbar/menu wiring, device-row drop handling.
  - `BookTableView.swift` / `CoverGridView.swift` — add `.onDrag` file-URL export so library rows can be dragged onto a device row (rows currently only accept drops).
- **Entitlements**: add `com.apple.security.device.usb` to `Config/BookManager.entitlements`.

## Data flow

- **Import off device**: `DeviceManager` (selection) → `MTPTransport.download` each selected file to a temp dir → `session.importFiles(urls:)` (existing pipeline: DRM check → AZW/MOBI→EPUB conversion → staged import → catalog) → `ImportReportView`.
- **Send to device**: selection → repository/`BookFolder` resolve stored format files → `SendPlan` matches against the profile's formats (identity copy in v1) → `MTPTransport.upload` to `Documents` → send report (copied / failed / no compatible format).
- **Detection**: USB arrival (enumeration on activation/timer/manual) → `DeviceRegistry` pairs device ↔ profile → `DeviceManager` publishes a `ConnectedDevice` → sidebar row → click → `DeviceBookScanner` lists books.

## Error handling

- Connection failures surface as an error/retry state on the device row, never a crash.
- Per-file failures land in the import/send reports (import already has this; send report mirrors it).
- Mid-transfer failures: report the failure; best-effort cleanup of any partially uploaded file; never delete device files in v1 (no delete-from-device).

## Testing

- `MockTransport` (in-memory Documents folder) drives `DeviceManager`/send/import logic and UI state without hardware.
- `SendPlanTests`: format priority (EPUB > PDF > AZW3), no-compatible-format cases (DJVU-only), missing-file cases.
- `DeviceBookScannerTests`: reuse existing MOBI fixtures (incl. the DRM-path fixture/stub) + a small EPUB fixture; asserts title/author/format/size/DRM flag; ignores `.sdr` and dot-files.
- `DeviceRegistryTests`: profile matching (vendor/product), unknown-device rejection.
- `MTPTransport` integration: spike checklist against a real Paperwhite (detect → list → download → upload → eject), documented as a manual verification step in the plan.
- Full non-perf suite stays green; perf suite skipped in verification runs (established convention).

## Out of scope

- Full format conversion (EPUB→MOBI/AZW3 etc.) — later feature; `FormatConverter` seam defined now.
- KFX import; DRM'd book import (rejected with clear message, lock badge in device list).
- Old-Kindle USBMS transport (`VolumeTransport`) — later, via the same protocols.
- IOKit push detection; device capacity display; send dedupe (same book already on device); delete-from-device; device covers (placeholder in v1); `.sdr` sidecar handling; Nook/reMarkable profiles (later, same seams).

## Acceptance criteria

- [ ] A connected Paperwhite appears in the sidebar Devices section (detection on activation + manual scan) and selecting it shows the device's books with DRM badges.
- [ ] Import Selected/All copies DRM-free books into the library through the existing pipeline (AZW/MOBI→EPUB); DRM'd books fail with "DRM-protected book"; report shown.
- [ ] Send to Device (toolbar + menu) and drag-onto-device copy the selected books' best native format (EPUB/PDF) to `Documents`; DJVU-only books report "no compatible format".
- [ ] `FormatConverter` seam exists (identity v1) and is documented as the landing point for full conversion.
- [ ] New devices require new profile/transport files + registry entries — no shared-code edits (verified by a stub `VolumeTransport`/profile in tests).
- [ ] Entitlement added; sandboxed build + real-device E2E checklist passes.
- [ ] Core suite green; no change-store format change.

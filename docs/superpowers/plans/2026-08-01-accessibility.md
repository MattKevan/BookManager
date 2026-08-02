# Accessibility (Slice 4c, Plan B) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** acceptance criterion 12 — keyboard + VoiceOver flows. The cover grid becomes fully accessible (VoiceOver labels/actions + keyboard navigation without a mouse), every icon-only toolbar button announces a readable label, and the cheap missing keyboard shortcuts are added.

**Architecture:** App-layer only. `CoverTile` gains accessibility labels/hints/actions; the grid gains `@FocusState`-driven keyboard navigation (arrows move selection, Return opens, Delete trashes) with a `focusable()` wrapper per tile; `ContentView`/`BookManagerApp` gain the missing shortcuts (Cmd-F search focus, Cmd-E edit). Verification is build + a manual VoiceOver/keyboard pass (headless residual, as in prior slices).

**Tech Stack:** Swift 6.0, SwiftUI (macOS 26), AppKit (`NSEvent`), XcodeGen.

## Global Constraints

- macOS 26 deployment target; Swift 6.0 with `SWIFT_STRICT_CONCURRENCY: complete`; `LibrarySession` is `@MainActor @Observable`.
- **No Core changes** — this is purely the app layer; the 142-test core suite stays green.
- The table view already has native keyboard/VoiceOver — do NOT alter it. The grid's keyboard nav must coexist with the existing mouse selection semantics (click replaces, ⌘ toggles, ⇧ range, marquee — unchanged).
- Existing keyboard shortcuts (Cmd-N create, Cmd-O open, Cmd-Shift-W close) stay; new ones must not collide (Cmd-F and Cmd-E are free).
- UI-test automation is environmental in this session (headless); the VoiceOver/keyboard verification is a documented manual residual.
- Build/test conventions: `xcodebuild ... -derivedDataPath .build/DerivedData build`; no new files expected (verify before adding any — if a helper type is needed, keep it in the existing view files).

---

### Task 1: Cover grid accessibility + keyboard navigation

**Files:**
- Modify: `BookManager/Views/CoverGridView.swift` (and its `CoverTile`)

**Interfaces:**
- Consumes: `CoverTile`'s existing tap handlers (`session.selectInGrid(book)`, `session.open(id:)`, `session.delete(ids:)`), `session.selection`, `@FocusState`.
- Produces: accessible + keyboard-navigable grid tiles.

- [ ] **Step 1: Read the current `CoverGridView.swift` and design the accessibility additions**

The file has `CoverGridView` (ScrollView + LazyVGrid + marquee + frame preference key) and a private `CoverTile` (whole-tile tap VStack with `.contentShape`, cover, labels, hover). Add:

1. **Per-tile accessibility** (attach to the tile's `VStack`):
   - `.accessibilityLabel(book.title)` (the cover image is otherwise unlabeled).
   - `.accessibilityHint("Double-click to open")`.
   - `.accessibilityAddTraits(.isButton)`.
   - `.accessibilityAction { Task { await session?.open(id: book.id) } }` (VoiceOver "activate" opens).
2. **Keyboard navigation** (the grid is usable without a mouse):
   - In `CoverGridView`: `@FocusState private var focusedID: UUID?`; each tile gets `.focusable()` + `.focused($focusedID, equals: book.id)`; on `.onChange(of: focusedID)` sync `session.selection = [id]` (single selection follows focus, per macOS conventions).
   - A container-level key handler for the focused tile: `.onKeyPress` (macOS 14+) on the grid — Left/Right move focus ±1 in `session.books` order; Up/Down move ±(estimated column count: `Int(max(1, (gridWidth / 140).rounded(.down)))` where 140 ≈ the adaptive minimum item width — compute from the ScrollView width via `GeometryReader` if needed); Return activates (`open(id:)`); Delete (`.delete`) trashes the focused book (`session.delete(ids: [id])`).
   - Focus starts on the first tile when the user presses an arrow key while nothing is focused (macOS convention: first keypress navigates from nothing).
   - Keep all existing mouse gestures unchanged.

Implementation note: `onKeyPress` phases/keys — verify the correct `KeyEquivalent` values (`.leftArrow`, `.rightArrow`, `.upArrow`, `.downArrow`, `.return`, `.delete`) compile on the macOS 26 SDK; if `.delete` is ambiguous with backspace, match the Delete key per the SDK. Do NOT use `.onKeyPress` if it requires focusability plumbing that fights the marquee gesture — fall back to `NSEvent`-based key handling in the grid's `onKeyDown` via a focused container if cleaner. The requirement is: arrow keys move selection, Return opens, Delete trashes — delivered by whatever clean mechanism works.

- [ ] **Step 2: Build and verify wiring**

Run: `xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -derivedDataPath .build/DerivedData build` → BUILD SUCCEEDED. Full core suite stays green (`... test -only-testing:BookManagerCoreTests` → 142 tests).
Manual residual for the human: VoiceOver announces tile titles and can activate; arrow keys move selection in the grid, Return opens, Delete trashes; mouse semantics unchanged. Note in the report.

- [ ] **Step 3: Commit**

```bash
git add BookManager/Views/CoverGridView.swift
git commit -m "feat: accessible and keyboard-navigable cover grid"
```

---

### Task 2: Toolbar labels + keyboard shortcuts audit

**Files:**
- Modify: `BookManager/Views/ContentView.swift`
- Modify: `BookManager/App/BookManagerApp.swift` (commands)

**Interfaces:**
- Consumes: the existing toolbar (`Label`-based buttons), `session.searchText`, `session.inspectorBook`, `session.selection`, `@FocusState` on the search field (if `.searchFocused` is available on macOS 26).
- Produces: announced toolbar labels; Cmd-F (search focus) + Cmd-E (edit selected) shortcuts.

- [ ] **Step 1: Audit toolbar labels**

Read `ContentView.swift`'s toolbar: every button already uses `Label` (text + icon) — verify each announces correctly when the toolbar renders icon-only (VoiceOver reads the label text; if any button lacks a text label, add `.help()` and confirm the label text is non-empty). Also verify `DiagnosticsView`/`BookInspectorView` buttons use labels (they do — but confirm). Report anything that needed fixing.

- [ ] **Step 2: Add the missing shortcuts**

- **Cmd-F (search focus):** attach `@FocusState private var searchFocused: Bool` in `ContentView`, bind it to the `.searchable` via `.searchFocused($searchFocused)` (verify this modifier exists on the macOS 26 SDK; if not, use a `@State` flag + `NSEvent`-free approach — e.g., make the search field focusable via `.defaultFocus` only if simple — otherwise DOCUMENT the limitation and skip Cmd-F, per "where they don't collide / cheap"). Add a `CommandGroup` or keyboard shortcut on the search action: `Button("Find") { searchFocused = true }.keyboardShortcut("f", modifiers: .command)` in `BookManagerApp` commands (in the `.commands` builder, e.g. `CommandGroup(replacing: .textEditing)` or a dedicated spot that doesn't collide with system Find).
- **Cmd-E (edit selected):** a command button that, with exactly one selected book, sets `session.inspectorBook` to that book (mirror `editSelection()`), `.keyboardShortcut("e", modifiers: .command)` in `BookManagerApp` commands.

- [ ] **Step 3: Build and verify wiring**

Run: `xcodebuild ... build` → BUILD SUCCEEDED; core suite 142 green. Manual residual: Cmd-F focuses search, Cmd-E opens the editor for the single selection, toolbar icons announce labels in VoiceOver. Note in the report.

- [ ] **Step 4: Commit**

```bash
git add BookManager/Views/ContentView.swift BookManager/App/BookManagerApp.swift
git commit -m "feat: toolbar label audit, Cmd-F search focus, Cmd-E edit shortcut"
```

---

## Self-Review

- **Spec coverage:** grid accessibility (labels/hints/actions) → Task 1; keyboard nav (arrows/Return/Delete) → Task 1; toolbar/icon label audit → Task 2; shortcuts (Cmd-F, Cmd-E) → Task 2; VoiceOver manual pass → residual in both tasks.
- **Placeholder scan:** no TBDs; Task 1/2 include explicit fallbacks where an SDK modifier may not exist (documented, not placeholders).
- **Type consistency:** `focusedID`/`searchFocused`/`focusedBookID` names are task-local; no cross-task interfaces.
- **Risks noted:** `onKeyPress` vs `NSEvent` fallback for grid keys; `.searchFocused` availability; grid adaptive columns estimate for Up/Down (140pt minimum) — all have documented fallbacks; mouse selection semantics must not regress (the existing reconciler/grid tests don't cover the view, so the manual pass is the guard).

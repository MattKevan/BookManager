# Browser Navigation Redesign: 3-Column Facet Browsing

**Date:** 2026-08-03
**Status:** Approved design (pending spec review)

## Problem

The sidebar currently mixes top-level navigation (All Books, Devices) with the
full flat lists of every author, series, tag, and format — all competing for
sidebar space and pushing devices down the list. Facet browsing needs a
dedicated column so the sidebar becomes pure navigation.

## Goals

- Sidebar = navigation only: Library (All Books, Authors, Series, Tags,
  Formats) + Devices (name + eject button, Finder-style).
- Facet browsing moves to a native 3-column `NavigationSplitView`:
  category → value list → book detail.
- Middle column disappears for All Books and device views (2-column layout).
- Category clicked with no value selected shows all books (no empty state).
- Filter field in the middle column narrows the value list as you type.
- Counts migrate from the sidebar to the middle column.

## Approach

**Chosen: Approach 1 — single `NavigationSplitView` with a dynamic middle
column.** The alternative (two parallel layouts swapped on selection) adds
structure duplication and a hard cutover; a hand-rolled `HSplitView` loses
native sidebar styling, collapse animation, and column persistence. Native
`NavigationSplitView` gives all of that for the least code. macOS target is
26.0, so column-visibility control is fully available.

## Design

### 1. Navigation structure

`ContentView.loadedBody` becomes a single `NavigationSplitView(columnVisibility:)`
with three columns:

- **Sidebar** (always visible): `SidebarView`
- **Middle column** (conditional): new `FacetListView`, present only when a
  facet category is the active sidebar selection
- **Detail** (always visible): existing device view / browser

`columnVisibility` is bound to session state:

- `.all` when `session.selectedCategory != nil`
- `.doubleColumn` when All Books or a device is selected

Collapse/expand is automatic and animated.

### 2. State model (`LibrarySession`)

Replace `selectedFacet: FacetSelection?` with two pieces of state:

- `selectedCategory: FacetType?` — sidebar selection (nil = All Books)
- `selectedFacetValue: String?` — middle-column selection (nil = no value)

Selection semantics:

- Clicking a sidebar category sets `selectedCategory`; if the category
  **changed**, clear `selectedFacetValue`. Clicking the already-active
  category keeps it selected (clear via All Books) — Finder/Music sidebar
  semantics.
- Clicking a value in the middle column sets `selectedFacetValue`. Clicking
  the already-selected value toggles it off, back to all books (preserves
  today's `selectFacet` toggle semantics).
- Clicking All Books clears both.
- Selecting a device clears the category (existing `selectDevice` already
  clears the facet); selecting a category clears the device selection.
- `refreshBooks()`: category + value both set → filtered books; otherwise →
  all books (or search). This preserves option-A behavior: category selected
  with no value shows everything.

The `FacetSelection` struct may be removed or repurposed; `FacetType` already
exists in `BookManagerCore`.

### 3. Sidebar (`SidebarView`)

- **Library** section: All Books, Authors, Series, Tags, Formats — no counts.
- **Devices** section (only when devices are attached): each row = device
  name + eject button, Finder-style. Eject calls the existing
  `session.devices.eject(id)`; the device disappears from the sidebar.
  Drag-to-send onto device rows stays.
- Single selection — exactly one of {device, category, All Books} active at a
  time. Selection model collapses to a single enum (`allBooks` /
  `category(FacetType)` / `device(UUID)`), replacing the current
  facet/device dual-state bridging.

### 4. Middle column (`FacetListView`)

- Search field at the top filtering the value list as you type.
- List of values **with counts** (counts migrate here from the sidebar).
- Single selection, matching current facet semantics.
- Data sources: existing `session.authors` / `series` / `tags` / `formats`
  arrays, filtered by the local search text.

### 5. Detail

Unchanged: table/grid browser + search (shows all books when a category is
selected but no value), and the existing `DeviceBooksView` for devices.
Toolbar logic stays as-is — library actions already hide in device mode.

### 6. Edge cases

- Ejecting the **selected** device → falls back to All Books (2 columns),
  mirroring the current deselect path in `DeviceManager.performEject`.
- Sidebar selection collapses to a single enum, simplifying the bridging that
  `SidebarView`'s binding currently does.

## Files touched

- `BookManager/Views/ContentView.swift` — 3-column split view + visibility
- `BookManager/Views/SidebarView.swift` — navigation-only sidebar + eject
- `BookManager/Views/FacetListView.swift` — new middle-column view
- `BookManager/Stores/LibrarySession.swift` — state model change

## Out of scope

- No changes to device transfer, inspector, search-in-detail, or toolbar
  actions.
- No multi-select facets (stays single-select, as today).

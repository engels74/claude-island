# Chunk 2: Project Manager

Pinned and recent project directories with a settings UI and full integration into the session launcher.

## Overview

Provides a managed list of project directories (pinned and recent) that feeds into the launcher's directory picker. Projects auto-populate from session history and can be manually pinned, reordered, and removed from a settings menu.

## Dependencies

- Chunk 1 (Tmux Session Launcher) -- the launcher panel exists and has a minimal directory picker that this chunk upgrades

## ProjectEntry Model

```swift
struct ProjectEntry: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    let path: String           // Absolute path
    var displayName: String    // Last path component
    var lastUsedAt: Date       // Updated on every session launch in this directory
    var isPinned: Bool         // true = pinned section
    var pinnedAt: Date?        // Sort order within pinned section
}
```

### Why a Single List With `isPinned` Flag

- A project can move between pinned and recent without duplication
- Pinning a recent project flips the flag, preserves `lastUsedAt`
- Unpinning moves it back to recent automatically
- Simpler persistence -- one array

### Storage

- Stored in `AppSettings` as JSON-encoded `[ProjectEntry]`
- Key: `"projects"`

## ProjectStore

### Type

`@MainActor @Observable` class. UI-facing state that SwiftUI views bind to directly.

### Public API

```swift
var pinnedProjects: [ProjectEntry]     // Computed, filtered + sorted by pinnedAt
var recentProjects: [ProjectEntry]     // Computed, filtered + sorted by lastUsedAt descending

func recordUsage(path: String)         // Called on SessionStart, updates or creates entry
func pin(id: UUID)                     // Sets isPinned = true, pinnedAt = now
func unpin(id: UUID)                   // Sets isPinned = false, clears pinnedAt
func remove(id: UUID)                  // Removes entirely
func addPinned(path: String)           // Manually add new pinned project
```

### Auto-Population

- `SessionStore` calls `ProjectStore.recordUsage(path:)` when processing `SessionStart` events -- this runs AFTER the session state update, as a side effect
- If path exists in list: update `lastUsedAt` to now (regardless of pinned status)
- If not: create new entry with `isPinned: false`, `lastUsedAt: now`
- Pruning runs after every `recordUsage` call: if non-pinned entries exceed 20, remove the entry with the oldest `lastUsedAt` (least recently used, not earliest created)

### Persistence

- Loads from `AppSettings` on init
- Writes back to `AppSettings` on every mutation
- No debouncing -- mutations are infrequent

### Integration Points

- `SessionStore` calls `recordUsage` on `SessionStart`
- `SessionLauncherView` reads `pinnedProjects` and `recentProjects` for directory picker
- `NotchMenuView` reads and writes for settings panel

## Projects Settings Menu

### Location

New row in `NotchMenuView`: folder icon + "Projects" label + chevron. Positioned after "Hooks" and before existing divider.

### Expanded View

#### Pinned Section

- Header: "Pinned" in small gray label
- Each row: filled star icon (yellow) + directory name (bold) + full path (gray, truncated)
- Swipe left or hover reveals: "Unpin" and "Remove" buttons
- Drag to reorder (reorders `pinnedAt` timestamps)
- Empty state: "No pinned projects" in gray text

#### Recent Section

- Header: "Recent" in small gray label
- Each row: clock icon + directory name (bold) + full path (gray) + relative time ("2h ago", "3d ago")
- Swipe left or hover reveals: "Pin" and "Remove" buttons
- Sorted by `lastUsedAt` descending (most recent first)
- No drag reorder -- always sorted by recency

#### Bottom Action

- "Add Project..." button with folder-plus icon
- Opens `NSOpenPanel` for directory selection
- Selected directory added as pinned project

### Visual Style

- Matches existing settings sections (same font sizes, spacing, colors)
- Rows ~36px tall, compact but readable
- Smooth expand/collapse animation

## Directory Picker in Launcher (Upgraded)

Replaces the Chunk 1 minimal picker (home dir + Browse).

### Layout

- Below session name field in launcher panel
- Max height: 200px, then scrolls internally
- Sections with small gray headers: "Pinned", "Recent"

### Row Rendering

- Pinned: filled star icon + directory name + dimmed path
- Recent: clock icon + directory name + dimmed path
- Selected row: highlighted background (`#0a84ff` at 15% opacity) + subtle left border accent
- Pre-selected on open: last used directory if in list, otherwise first pinned, otherwise home

### Keyboard Navigation

- Arrow keys move highlight when directory list is focused (via Tab from name field)
- Up/Down wraps around
- Section headers skipped
- Enter with directory highlighted submits entire form
- Typing does NOT filter -- prompt field is the only text input

### Browse Row

- Always last, after all recent entries
- Folder-open icon + "Browse..." text
- Arrow key to it + Enter opens `NSOpenPanel`
- After selecting: fills picker selection, focus returns to directory list
- Browsed directory auto-added to recents

### Empty Project List

- Fresh install: show just "Browse..." and home directory as a single entry
- After first session: recents auto-populate

## New Files

- `ProjectEntry.swift` -- Model
- `ProjectStore.swift` -- Observable store
- `ProjectsSettingsView.swift` -- Settings section
- `DirectoryPickerView.swift` -- Reusable picker for launcher

## Modified Files

- `SessionLauncherView.swift` -- Replace minimal directory picker with `DirectoryPickerView`
- `SessionStore.swift` -- Call `ProjectStore.recordUsage(path:)` in `processHookEvent` after session state update when event is `SessionStart`
- `NotchMenuView.swift` -- Add Projects settings section (expandable row, after Hooks)
- `AppDelegate.swift` -- Initialize `ProjectStore` singleton, make accessible to views
- `AppSettings.swift` -- Add `projects` key following existing pattern: private `Keys` enum entry + static computed property. Stored as JSON-encoded `[ProjectEntry]` via `UserDefaults`

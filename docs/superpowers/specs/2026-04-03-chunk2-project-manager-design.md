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
    let path: String           // Absolute path, normalized (no trailing slash)
    var displayName: String    // Last path component
    var lastUsedAt: Date       // Updated on every session launch in this directory
    var isPinned: Bool         // true = pinned section
    var pinnedAt: Date?        // Sort order within pinned section
}
```

All field types have automatic `Codable` conformance (UUID, String, Date, Bool, Date?). No custom encoding needed. `Equatable` and `Sendable` are auto-synthesized since all fields are value types.

### Why a Single List With `isPinned` Flag

- A project can move between pinned and recent without duplication
- Pinning a recent project flips the flag, preserves `lastUsedAt`
- Unpinning moves it back to recent automatically
- Simpler persistence -- one array

### Storage

- Stored in `AppSettings` as JSON-encoded `[ProjectEntry]` via `UserDefaults`
- Key: `"projects"`
- Follows the exact pattern of `AppSettings.moduleLayoutConfig` in `Settings.swift` (lines 228-240): `JSONEncoder`/`JSONDecoder` with `defaults.data(forKey:)` / `defaults.set(data, forKey:)`
- Getter returns `[ProjectEntry]` (empty array on decode failure, not nil)

## ProjectStore

### Type

`@Observable final class` with `static let shared` and `private init()`. Follows the exact pattern of `ClaudeSessionMonitor`, `ChatHistoryManager`, `SessionMetadataManager` -- no `@MainActor` annotation (no existing `@Observable` class in the codebase uses it).

### Public API

```swift
var pinnedProjects: [ProjectEntry]     // Computed, filtered + sorted by pinnedAt
var recentProjects: [ProjectEntry]     // Computed, filtered + sorted by lastUsedAt descending

func recordUsage(path: String)         // Called on SessionStart, updates or creates entry
func pin(id: UUID)                     // Sets isPinned = true, pinnedAt = now
func unpin(id: UUID)                   // Sets isPinned = false, clears pinnedAt
func remove(id: UUID)                  // Removes entirely
func addPinned(path: String)           // Manually add new pinned project
func pruneInvalidPaths()               // Removes non-pinned entries whose paths no longer exist on disk
```

### Path Validation in `recordUsage(path:)`

Before creating or updating an entry:
- Reject empty strings and non-absolute paths (must start with `/`)
- Normalize: strip trailing `/` (e.g., `/Users/foo/bar/` -> `/Users/foo/bar`)
- Do NOT resolve symlinks -- store the path as reported by the session
- Derive `displayName` from `URL(fileURLWithPath: normalizedPath).lastPathComponent`
- Deduplicate by normalized path (not by raw string)

### Auto-Population

- `ClaudeSessionMonitor.handleHookEvent()` calls `ProjectStore.shared.recordUsage(path: event.cwd)` when the hook event name is `"SessionStart"` -- this keeps the existing architectural direction (MainActor code calling ProjectStore) rather than introducing a novel SessionStore-to-ProjectStore actor crossing
- If path exists in list: update `lastUsedAt` to now (regardless of pinned status)
- If not: create new entry with `isPinned: false`, `lastUsedAt: now`
- Pruning runs after every `recordUsage` call: if non-pinned entries exceed 20, remove the entry with the oldest `lastUsedAt` (least recently used, not earliest created)

### Path Validity on Display

- On app launch, call `pruneInvalidPaths()` which removes non-pinned entries whose directories no longer exist (`FileManager.default.fileExists(atPath:)`)
- Pinned entries with missing paths are preserved but displayed dimmed with "Not found" subtitle
- No runtime revalidation (paths don't change during a session)

### Persistence

- Loads from `AppSettings` on init
- Writes back to `AppSettings` on every mutation
- No debouncing -- mutations are infrequent (session starts, user actions)

### Integration Points

- `ClaudeSessionMonitor` calls `recordUsage` when hook event is `"SessionStart"`
- `SessionLauncherView` reads `pinnedProjects` and `recentProjects` for directory picker
- `NotchMenuView` reads and writes for settings panel

## Projects Settings Menu

### Location

New row in `NotchMenuView`: folder icon + "Projects" label + chevron. Positioned after "Hooks" row (line ~133) and before `AccessibilityRow` (line ~135). Follows `TokenTrackingRow` expansion pattern (lines 657-840): `@State isExpanded`, button toggles visibility, chevron rotates, content animates with `.spring(response: 0.3, dampingFraction: 0.8)`.

### Menu Height

The expanded Projects section could add significant content height. Since `NotchMenuView` is inside a `ScrollView` (line 40), content scrolls naturally. However, verify that the `openedSize` base height of 500px (NotchViewModel line ~125) plus existing expanded sections provides enough visible area. If the Projects section is expanded while other sections are also expanded, the ScrollView handles overflow -- no `openedSize` change needed unless the window itself clips the scroll.

### Expanded View

#### Pinned Section

- Header: "Pinned" in small gray label
- Each row: filled star icon (yellow) + directory name (bold) + full path (gray, truncated)
- **Hover-to-reveal actions** (NOT swipe -- `.swipeActions` only works with `List`, and the notch uses `ScrollView` + `LazyVStack`): on hover, "Unpin" and "Remove" buttons fade in on the right side. This matches existing hover patterns in `NotchMenuView` (e.g., `MenuRow` hover states, lines 640-652).
- **Drag to reorder**: use `.draggable` + `.dropDestination` pattern from `ModuleLayoutSettingsView` (lines 54-213). This works on `VStack` rows without requiring `List`. Reorder updates `pinnedAt` timestamps.
- Missing/invalid paths: show dimmed with "Not found" subtitle, actions still available (remove, unpin)
- Empty state: "No pinned projects" in gray text

#### Recent Section

- Header: "Recent" in small gray label
- Each row: clock icon + directory name (bold) + full path (gray) + relative time
- Relative time format: reuse `SessionPhaseHelpers.timeAgo(_:now:)` (already exists in `Utilities/SessionPhaseHelpers.swift`, lines 47-54) which produces `"2h"`, `"3d"` etc. -- consistent with session row time display
- **Hover-to-reveal**: "Pin" and "Remove" buttons on hover
- Sorted by `lastUsedAt` descending (most recent first)
- No drag reorder -- always sorted by recency

#### Bottom Action

- "Add Project..." button with folder-plus icon
- Opens `NSOpenPanel` for directory selection (see NSOpenPanel section below)
- Selected directory added as pinned project

### NSOpenPanel Handling

**NSOpenPanel has never been used in this codebase.** The notch panel is at `.mainMenu + 3` and the launcher panel at `.mainMenu + 4`. NSOpenPanel at default window level would appear BEHIND both panels.

**Workaround:**
1. Before showing `NSOpenPanel`, temporarily order out (hide) the calling panel
2. Present `NSOpenPanel` as a standalone modal via `panel.begin { response in ... }`
3. On completion (regardless of OK/Cancel), re-show the calling panel and apply the selection
4. Configure `NSOpenPanel`: `canChooseDirectories = true`, `canChooseFiles = false`, `allowsMultipleSelection = false`

This applies to both the "Add Project..." button in settings and the "Browse..." option in the launcher directory picker.

### Visual Style

- Matches existing settings sections (same font sizes, spacing, colors)
- Rows ~36px tall, compact but readable
- Smooth expand/collapse animation following `TokenTrackingRow` pattern

## Directory Picker in Launcher (Upgraded)

Replaces the Chunk 1 minimal picker (home dir + Browse).

### Interface Contract with SessionLauncherView

The `DirectoryPickerView` should be a standalone SwiftUI view with:
- `@Binding var selectedPath: String` -- the currently selected directory path
- `projectStore: ProjectStore` -- for reading pinned/recent data
- `onSubmit: () -> Void` -- called when Enter is pressed with a selection
- `@FocusState` integration for Tab-based focus chain from the launcher

This clean interface allows Chunk 1's minimal picker to be replaced without restructuring the launcher view.

### Layout

- Below session name field in launcher panel
- Max height: 200px, then scrolls internally
- Sections with small gray headers: "Pinned", "Recent"

### Row Rendering

- Pinned: filled star icon + directory name + dimmed path
- Recent: clock icon + directory name + dimmed path
- Selected row: highlighted background (`#0a84ff` at 15% opacity) + subtle left border accent
- Pre-selected on open: `AppSettings.lastUsedDirectory` if in the project list, otherwise first pinned, otherwise home

### Keyboard Navigation

- Arrow keys move highlight when directory list is focused (via Tab from name field)
- Up/Down wraps around
- Section headers skipped
- Enter with directory highlighted submits entire form
- Typing does NOT filter -- prompt field is the only text input

### Browse Row

- Always last, after all recent entries
- Folder-open icon + "Browse..." text
- Arrow key to it + Enter opens `NSOpenPanel` (using the workaround described above -- order out launcher panel first)
- After selecting: fills picker selection, focus returns to directory list, launcher panel re-shows
- Browsed directory auto-added to recents via `ProjectStore.recordUsage(path:)`

### Empty Project List

- Fresh install: show just "Browse..." and home directory as a single entry
- After first session: recents auto-populate

## New Files

- `ProjectEntry.swift` -- Model (Codable, Identifiable, Sendable, Equatable)
- `ProjectStore.swift` -- `@Observable final class`, `static let shared`, manages project list
- `ProjectsSettingsView.swift` -- Expandable settings section (following TokenTrackingRow pattern)
- `DirectoryPickerView.swift` -- Reusable picker for launcher (Binding-based interface)

## Modified Files

- `SessionLauncherView.swift` -- Replace minimal directory picker with `DirectoryPickerView`, pass `ProjectStore.shared`
- `ClaudeSessionMonitor.swift` -- In `handleHookEvent()`, after `SessionStore.shared.process()`, call `ProjectStore.shared.recordUsage(path: event.cwd)` when `event.event == "SessionStart"`
- `NotchMenuView.swift` -- Add Projects expandable settings section (after Hooks row, before AccessibilityRow)
- `Settings.swift` -- Add `projects` key to private `Keys` enum + `static var projects: [ProjectEntry]` computed property using `JSONEncoder`/`JSONDecoder` pattern (matching `moduleLayoutConfig`)

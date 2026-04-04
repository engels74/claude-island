# Chunk 3: Keyboard Shortcuts & Session Actions

Global hotkeys, per-session shortcuts, session row overflow menu, and customizable visible actions.

## Overview

Adds system-wide keyboard shortcut support for opening the launcher and jumping directly to specific sessions. Extends session rows with an overflow menu containing additional actions, with user-customizable visible button slots.

## Dependencies

- Chunk 1 (Tmux Session Launcher) -- the launcher panel must exist for the global shortcut to open it
- Chunk 2 (Project Manager) -- the "Pin Project" action in the overflow menu writes to ProjectStore

## Global Hotkey Infrastructure

### How It Works

Uses `CGEvent` tap for system-wide key interception. This lets us consume the event so it doesn't trigger anything else. Requires accessibility permissions (`AXIsProcessTrusted`), which the app already requests.

### HotkeyManager

`@MainActor @Observable` class. Manages all registered shortcuts and dispatches actions.

#### Internals

- Creates a `CGEvent` tap on init (mach port + `CFRunLoopSource`)
- Maintains a dictionary: `[KeyCombo: HotkeyAction]`
- On each key event: checks for match, consumes and fires action if found, passes through if not

#### Lifecycle

- Created by `AppDelegate` on launch
- Loads saved shortcuts from `AppSettings`
- Installs `CGEvent` tap
- Tears down tap on app termination

#### Accessibility Check

- `AXIsProcessTrusted()` returns false if permission not granted
- `CGEvent` tap silently fails without it
- Show warning in Shortcuts settings if accessibility isn't granted, link to System Settings

### KeyCombo Model

```swift
struct KeyCombo: Hashable, Codable, Sendable {
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags  // .command, .shift, .option, .control
    var displayString: String             // "Cmd+Shift+2"
}
```

### HotkeyAction Enum

```swift
enum HotkeyAction: Codable, Sendable {
    case openLauncher
    case focusSession(sessionID: String)
}
```

## Key Recorder Component

Reusable SwiftUI view for capturing key combinations.

### Appearance

- Rounded rect field, ~120px wide
- Idle: shows current combo (e.g., "Cmd+Shift+N") or "Record..." in gray placeholder
- Recording: pulsing blue border, text shows "Press keys..."
- Modifier symbols: standard macOS glyphs (Command, Control, Option, Shift)

### Interaction

- Click field to start recording
- Press any key combo (must include at least one modifier)
- Combo captured and displayed immediately
- Escape cancels recording
- Small X button clears current shortcut

### Validation

- Must have at least one modifier (Command, Control, Option, Shift)
- Reserved system shortcut check -- the following are blocked with a "Reserved" shake animation:
  - macOS system: Cmd+Q, Cmd+H, Cmd+M, Cmd+Tab, Cmd+Space, Cmd+`, Cmd+W, Cmd+N, Cmd+Shift+Q
  - Clipboard: Cmd+C, Cmd+V, Cmd+X, Cmd+A, Cmd+Z, Cmd+Shift+Z
  - Mission Control: Ctrl+Up, Ctrl+Down, Ctrl+Left, Ctrl+Right
  - Principle: any combo that `CGEvent` tap cannot reliably intercept (system-level shortcuts consumed before our tap)
- Cannot conflict with another registered HotkeyAction -- shows "Already used for [action]" with reassign option
- On conflict reassign: clears old binding, assigns to new one

### Implementation

- `NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged])` while recording
- Captures `keyCode` and `modifierFlags`
- Converts to `KeyCombo` and validates
- Calls back with result

### Where It Appears

- Shortcuts settings: inline in each shortcut row
- Per-session overflow "Assign Shortcut": small popover with recorder + Save/Cancel

## Per-Session Shortcuts

### Binding Model

- Stored in `AppSettings` as `[String: KeyCombo]` (sessionID to key combo)
- `HotkeyManager` registers as `.focusSession(sessionID:)` actions
- When session ends or is deleted, binding auto-removed

### What Happens When Fired

1. `HotkeyManager` dispatches `.focusSession(sessionID:)`
2. Session exists: `NotchViewModel.status = .opened`, `contentType = .chat(session)`, input field focused via `@FocusState`
3. Session no longer exists: shortcut silently unregistered from `HotkeyManager` AND removed from `AppSettings.sessionShortcuts`, key combo does nothing

### Cleanup of Orphaned Bindings

- On app launch: `HotkeyManager` loads saved shortcuts from `AppSettings`, cross-references with `SessionStore.sessions`. Any binding whose `sessionID` has no matching session is removed immediately.
- On `SessionEvent.sessionEnded`: `SessionStore` notifies `HotkeyManager.removeShortcut(forSession:)` which unregisters the combo and removes from `AppSettings`
- On session delete (from overflow menu): same cleanup path via `sessionEnded` event

### Assignment Flow

1. Click `...` on session row -> "Assign Shortcut"
2. Popover appears anchored to row
3. Key recorder + "Save" + "Cancel"
4. Save: `HotkeyManager.register(combo, action: .focusSession(session.sessionID))`
5. Popover dismisses

### Reassignment

- If session has existing shortcut, recorder shows current combo
- Recording new one replaces it
- X button clears entirely

## Session Row Overflow Menu

### The `...` Button

- 4th button in row, rightmost position
- Renders as horizontal ellipsis icon matching existing button style
- Click opens dropdown anchored below-left of button

### Full Action Set

| Action | Icon | Description | Default Visible |
|---|---|---|---|
| Chat | speech bubble | Open chat view | Yes (slot 1) |
| Focus | terminal arrow | Switch to tmux pane | Yes (slot 2) |
| Archive | box/tray | End session in Claude Island | Yes (slot 3) |
| Copy Attach | clipboard | Copy `tmux attach -t <name>` to clipboard | No (overflow) |
| Delete | trash | Kill tmux session + remove from list | No (overflow) |
| Pin Project | star | Add session cwd to pinned projects | No (overflow) |
| Assign Shortcut | keyboard | Open key recorder | No (overflow) |

### Overflow Dropdown Rendering

- Dark background matching notch aesthetic, rounded corners
- Each row: icon + label
- Divider before destructive actions
- Delete in red text
- Delete triggers inline confirmation: "Are you sure?" with "Delete" (red) + "Cancel"

### Copy Attach Behavior

- Copies: `tmux attach-session -t <session-name>`
- Brief "Copied!" toast on row (fades after 1.5s)
- Uses `NSPasteboard` directly

### Delete vs Archive

- Archive: mark session as ended in Claude Island (existing, doesn't touch tmux)
- Delete: kill tmux session AND remove from Claude Island. Confirmation required.

## Customizable Visible Actions

### Settings

- New row in `NotchMenuView`: "Session Actions" with chevron
- Expands to reorderable list of all 7 actions
- Top 3 are visible quick buttons, rest go to overflow
- Drag handles for reordering
- `...` overflow button always present, can't be removed/reordered
- Changes apply immediately

### Storage

- Ordered action list in `AppSettings` as `[SessionActionType]` enum array
- Default: `[.chat, .focus, .archive, .copyAttach, .delete, .pinProject, .assignShortcut]`

## Shortcuts Settings Menu

### Location

New row in `NotchMenuView`: keyboard icon + "Shortcuts" label + chevron. After "Projects".

### Expanded View

#### Global Section

- Header: "Global" in small gray label
- Single row: "New Session" + key recorder
- Help text: "Opens the session launcher from anywhere"

#### Sessions Section

- Header: "Sessions" in small gray label
- One row per active binding: session name + key recorder
- Only active bindings listed (sessions without shortcuts not shown)
- Re-record or clear with X
- Session ends -> row disappears
- Empty state: "No session shortcuts assigned" + help text about overflow menu

## New Files

- `HotkeyManager.swift` -- CGEvent tap + dispatch
- `KeyCombo.swift` -- Model
- `KeyRecorderView.swift` -- Reusable recorder component
- `ShortcutsSettingsView.swift` -- Settings section
- `SessionActionOverflowMenu.swift` -- Dropdown menu
- `SessionActionsSettingsView.swift` -- Customizable actions settings

## Panel Layering

The launcher panel (`SessionLauncherPanel`) and overflow menu can never appear simultaneously -- the launcher is a modal-like floating panel that dismisses on outside click, and the overflow menu is anchored to a session row inside the notch. If the notch is visible and user clicks `...`, the overflow appears within the notch. If the launcher is open, the notch is behind it and not interactive.

## Modified Files

- `InstanceRow.swift` -- Add 4th `...` overflow button, add `onCopyAttach`, `onDelete`, `onPinProject`, `onAssignShortcut` callbacks, conditional rendering based on `AppSettings.sessionActionOrder` for which 3 are visible
- `ClaudeInstancesView.swift` -- Pass all action handlers to InstanceRow including new overflow actions
- `NotchMenuView.swift` -- Add Shortcuts and Session Actions settings sections (expandable rows)
- `NotchViewModel.swift` -- Add `focusSession(sessionID:)` method that sets `.opened` + `.chat(session)` + triggers input focus
- `AppDelegate.swift` -- Initialize `HotkeyManager`, wire to `NotchViewModel` and `SessionLauncherPanel`
- `AppSettings.swift` -- New keys following existing pattern (private `Keys` enum + computed properties): `globalShortcut` (Data?, encoded KeyCombo), `sessionShortcuts` (Data?, encoded [String: KeyCombo]), `sessionActionOrder` ([String], encoded [SessionActionType])

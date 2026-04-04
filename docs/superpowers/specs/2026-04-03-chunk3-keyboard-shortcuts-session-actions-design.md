# Chunk 3: Keyboard Shortcuts & Session Actions

Global hotkeys, per-session shortcuts, session row overflow menu, and customizable visible actions.

## Overview

Adds system-wide keyboard shortcut support for opening the launcher and jumping directly to specific sessions. Extends session rows with an overflow menu containing additional actions, with user-customizable visible button slots.

## Dependencies

- Chunk 1 (Tmux Session Launcher) -- the launcher panel must exist for the global shortcut to open it
- Chunk 2 (Project Manager) -- the "Pin Project" action in the overflow menu writes to ProjectStore

## Global Hotkey Infrastructure

### How It Works

Uses `CGEvent` tap (`CGEvent.tapCreate()`) for system-wide key interception. This lets us consume the event so it doesn't trigger anything else. Requires accessibility permissions (`AXIsProcessTrusted`), which the app already requests via `AccessibilityPermissionManager`.

Note: The existing codebase uses `CGEvent` for **posting** mouse events (in `NotchWindow.swift` and `NotchViewModel.swift`) but has never installed a `CGEvent` **tap** (listener). A keyboard-only tap filtered to `.keyDown`/`.keyUp` will not conflict with the existing mouse-event posting.

### HotkeyManager

`@Observable final class` with `static let shared` and `private init()`. Follows the same pattern as other observables in the codebase (no `@MainActor` annotation).

#### Internals

- Creates a `CGEvent` tap on init (mach port + `CFRunLoopSource` attached to **main run loop**)
- The hotkey dictionary must be protected with `Mutex<[KeyCombo: HotkeyAction]>` (from `Synchronization` framework, which the codebase already uses). Reason: the CGEvent tap callback is a C function pointer (`@convention(c)`) that receives `self` via `UnsafeMutableRawPointer` — it cannot participate in Swift observation or actor isolation. The Mutex ensures thread-safe reads from the callback.
- On each key event in the C callback: read the dictionary from the Mutex, check for match, consume and fire action if found, pass through if not
- Action dispatch: `DispatchQueue.main.async { ... }` from the C callback to ensure MainActor context for UI updates (CGEvent tap callbacks on main run loop are not guaranteed MainActor in Swift 6.2)

#### Deferred Start

Follow the `EventMonitors.shared.startMonitorsIfPermitted()` pattern (EventMonitors.swift line 62): only install the `CGEvent` tap when `AXIsProcessTrusted()` returns true. `AccessibilityPermissionManager` already calls `EventMonitors.shared.startMonitorsIfPermitted()` when permission is granted -- add a similar call to `HotkeyManager.shared.startIfPermitted()`.

#### Tap Health Check

`CGEvent.tapCreate()` can return `nil` even with accessibility granted, and taps can become disabled silently. Add a periodic check (similar to the accessibility polling in `AccessibilityPermissionManager`):
- On each shortcut settings view appear, verify `CGEvent.tapIsEnabled(tap:)` -- if disabled, re-enable with `CGEvent.tapEnable(tap:enable:)`
- If tap creation initially fails, retry on next accessibility permission grant

#### Lifecycle

- Created by `AppDelegate` on launch
- Loads saved shortcuts from `AppSettings`
- Installs `CGEvent` tap (deferred until accessibility granted)
- Tears down tap on app termination

#### Accessibility Check

- `AXIsProcessTrusted()` returns false if permission not granted
- `CGEvent` tap creation silently fails or returns nil
- Show warning in Shortcuts settings if accessibility isn't granted, using the existing `AccessibilityPermissionManager.isAccessibilityGranted` flag

### KeyCombo Model

```swift
struct KeyCombo: Hashable, Codable, Sendable {
    let keyCode: UInt16
    let modifiers: UInt            // NSEvent.ModifierFlags.rawValue (UInt, not ModifierFlags directly)
    var displayString: String      // "⌘⇧2" -- generated from keyCode + modifiers

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers)
    }
}
```

**Custom Codable conformance required**: `NSEvent.ModifierFlags` is NOT `Codable` out of the box (it's an `OptionSet` backed by `UInt`). Store `modifiers` as `UInt` (the raw value) which IS Codable. Provide a computed `modifierFlags` property for convenience.

**Display string generation**: `keyCode` is keyboard-layout-dependent. Use `Carbon.UCKeyTranslate` with `TISCopyCurrentKeyboardInputSource()` to convert keyCode to a layout-independent character. Modifier symbols use standard macOS glyphs: ⌘ (Command), ⌃ (Control), ⌥ (Option), ⇧ (Shift).

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
- Idle: shows current combo (e.g., "⌘⇧N") or "Record..." in gray placeholder
- Recording: pulsing blue border, text shows "Press keys..."
- Modifier symbols: standard macOS glyphs

### Interaction

- Click field to start recording
- Uses `NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged])` while recording (same pattern as `ChatView.swift` line ~556 for Cmd+V interception)
- Press any key combo (must include at least one modifier)
- Combo captured and displayed immediately
- Escape cancels recording (return event from monitor to not consume it)
- Small X button clears current shortcut
- Remove monitor when recording ends (on capture, cancel, or view disappear)

### Validation

- Must have at least one modifier (Command, Control, Option, Shift)
- Reserved system shortcut check -- the following are blocked with a "Reserved" shake animation:
  - macOS system: Cmd+Q, Cmd+H, Cmd+M, Cmd+Tab, Cmd+Space, Cmd+`, Cmd+W, Cmd+N, Cmd+Shift+Q
  - Clipboard: Cmd+C, Cmd+V, Cmd+X, Cmd+A, Cmd+Z, Cmd+Shift+Z
  - Mission Control: Ctrl+Up, Ctrl+Down, Ctrl+Left, Ctrl+Right
  - Principle: any combo that `CGEvent` tap cannot reliably intercept (system-level shortcuts consumed before our tap)
- Cannot conflict with another registered HotkeyAction -- shows "Already used for [action]" with reassign option
- On conflict reassign: clears old binding, assigns to new one

### Where It Appears

- Shortcuts settings: inline in each shortcut row
- Per-session overflow "Assign Shortcut": small popover with recorder + Save/Cancel

## Per-Session Shortcuts

### Binding Model & Ephemerality

Per-session shortcuts are **conversation-scoped**, not tmux-session-scoped. The `sessionID` comes from Claude Code and changes every time Claude restarts, even in the same tmux session. This is intentional for the initial implementation -- shortcuts are meant for active, long-running sessions.

Future enhancement: store a `tmuxSessionName` on `SessionState` (populated during `TmuxTargetFinder` lookup) to enable tmux-session-scoped shortcuts that survive Claude restarts. This is out of scope for Chunk 3.

- Stored in `AppSettings` as `[String: KeyCombo]` (sessionID to key combo)
- `HotkeyManager` registers as `.focusSession(sessionID:)` actions
- When session ends or is deleted, binding auto-removed

### What Happens When Fired

1. `HotkeyManager` dispatches `.focusSession(sessionID:)`
2. `HotkeyManager` looks up the session via `ClaudeSessionMonitor.shared.instances.first(where: { $0.sessionID == sessionID })` -- this is synchronous since `ClaudeSessionMonitor` is `@Observable` on MainActor and `instances` is a plain array property
3. If session found: call `NotchViewModel.showChat(for: session)` (existing method, line ~205) + set `NotchViewModel.status = .opened` via `notchOpen(reason:)` + set a `focusInputOnAppear` flag on `NotchViewModel` (see below)
4. If session not found: silently unregister the shortcut

**Input focus mechanism**: `@FocusState` is per-view and cannot be set from `NotchViewModel` directly. Instead:
- Add a `var focusInputOnAppear = false` property on `NotchViewModel`
- `ChatView` observes this property via `.onChange(of: viewModel.focusInputOnAppear)` and sets its local `@FocusState` binding when it becomes true
- `ChatView` resets the flag to false after applying focus
- This is the standard ViewModel-to-View focus coordination pattern

### Cleanup of Orphaned Bindings

**On app launch**: `HotkeyManager` loads saved shortcuts, cross-references with `ClaudeSessionMonitor.shared.instances`. Any binding whose `sessionID` has no matching session is removed.

**On session end**: Two code paths exist for session endings, and BOTH must trigger cleanup:

1. **Via `.sessionEnded` event** (from archive action, periodic PID check): `SessionStore.processSessionEnd()` fires. Add a cleanup side-effect here.
2. **Via hook `status == "ended"`** (from `SessionEnd` hook): `processHookEvent` directly removes the session at line ~323. **Currently does NOT emit `.sessionEnded`.** Must either: emit `.sessionEnded` from this path too, or add a separate notification.

**Recommended approach**: Unify all session removal paths through `processSessionEnd()` (currently, the `status == "ended"` hook path bypasses it and directly removes). Then add a `var onSessionRemoved: (@Sendable (String) -> Void)?` property on `SessionStore` (must be `@Sendable` since the closure crosses actor boundary) that `AppDelegate` wires to `HotkeyManager.shared.removeShortcut(forSession:)`. This is the simplest approach without introducing a full observer pattern. Alternatively, `ClaudeSessionMonitor`'s session stream subscription can diff the previous and current session lists to detect removals.

### Assignment Flow

1. Click `...` on session row -> "Assign Shortcut"
2. Popover appears anchored to row
3. Key recorder + "Save" + "Cancel"
4. Save: `HotkeyManager.shared.register(combo, action: .focusSession(session.sessionID))`
5. Popover dismisses

### Reassignment

- If session has existing shortcut, recorder shows current combo
- Recording new one replaces it
- X button clears entirely

## Session Row Overflow Menu

### The `...` Button

- 4th button in the InstanceRow action area (defined inside `ClaudeInstancesView.swift`, NOT a separate file)
- Renders as horizontal ellipsis icon (`IconButton` with `"ellipsis"`) matching existing button style (24x24px)
- Click opens dropdown within the notch panel

### Overflow Dropdown Implementation

No popovers or dropdowns exist anywhere in the current codebase. Two approaches:

1. **SwiftUI overlay within notch** (recommended): Use a `ZStack` overlay with absolute positioning. The dropdown renders above other session rows within the notch's `ScrollView`. If the row is near the bottom of the visible area, anchor the dropdown above the button instead of below.
2. **Separate NSPanel**: Like the launcher panel, but adds unnecessary complexity for a small menu.

The overlay approach uses a `@State var showOverflowFor: String?` (sessionID) on `ClaudeInstancesView`. When set, an overlay view renders the dropdown positioned relative to the triggering row. Tapping outside or selecting an action dismisses it.

### Interaction with Approval Buttons

InstanceRow currently has THREE rendering modes (lines 316-342 of `ClaudeInstancesView.swift`):

1. **Interactive tool approval**: Chat + Terminal (2 buttons)
2. **Non-interactive tool approval**: Chat + Deny + Allow (`InlineApprovalButtons`, 3 buttons with text labels)
3. **Normal state**: Chat + Terminal (conditional on PID) + Archive (conditional on idle/waitingForInput)

**Approval and launching states take absolute precedence.** When `session.phase.isWaitingForApproval`:
- The customizable action slots are NOT shown
- The `...` overflow button is NOT shown
- Approval-specific buttons render as they do today (no change)

When `session.phase` is `.launching` (from Chunk 1):
- The customizable action slots are NOT shown
- The `...` overflow button is NOT shown
- Cancel/Retry/Dismiss buttons render per Chunk 1's spec

When NOT in approval or launching state:
- The configurable visible buttons + `...` overflow render

This means the customizable system only applies to normal (non-approval) state.

### Conditional Action Visibility

Some actions have preconditions:
- **Focus**: requires `session.pid != nil` (no PID = can't find terminal)
- **Archive**: requires `.idle` or `.waitingForInput` phase
- **Copy Attach**: requires `session.isInTmux` (non-tmux sessions have nothing to attach to)
- **Delete**: requires `session.isInTmux`
- **Pin Project**: always available (cwd always exists)
- **Assign Shortcut**: always available

When a visible-slot action's condition is NOT met, the button is hidden and the remaining buttons shift left. The `...` button is always rightmost. This means the visible button count can vary from 1 to 3 plus `...`. This matches the current behavior where Terminal and Archive conditionally appear.

### Full Action Set

| Action | Icon | Description | Default Visible | Condition |
|---|---|---|---|---|
| Chat | bubble.left | Open chat view | Yes (slot 1) | Always |
| Focus | terminal | Switch to tmux pane | Yes (slot 2) | `pid != nil` |
| Archive | archivebox | End session in Claude Island | Yes (slot 3) | `.idle` or `.waitingForInput` |
| Copy Attach | doc.on.clipboard | Copy `tmux attach -t <name>` to clipboard | No (overflow) | `isInTmux` |
| Delete | trash | Kill tmux session + remove from list | No (overflow) | `isInTmux` |
| Pin Project | star | Add session cwd to pinned projects | No (overflow) | Always |
| Assign Shortcut | keyboard | Open key recorder | No (overflow) | Always |

### Copy Attach Behavior

- Uses `session.tmuxSessionName` (added to `SessionState` by Chunk 1) — no async lookup needed
- Copies: `tmux attach-session -t <session-name>`
- Brief "Copied!" toast on row (fades after 1.5s, using existing `.spring(response: 0.25, dampingFraction: 0.8)` animation pattern)
- Uses `NSPasteboard.general.clearContents()` + `.setString(_:forType: .string)` (existing `NSPasteboard` import in `ChatView.swift`)

### Delete Behavior

- Uses `session.tmuxSessionName` (added to `SessionState` by Chunk 1) — no async lookup needed
- Inline confirmation within dropdown: "Are you sure?" with "Delete" (red) + "Cancel" (swaps dropdown content via `@State`)
- On confirm: `TmuxController.shared.killSession(sessionName:)` (new method, uses `ProcessExecutor.run(tmuxPath, ["kill-session", "-t", name])`) then `SessionStore.shared.process(.sessionEnded(sessionID:))`
- If tmux target lookup fails (PID nil, session already dead): just fire `.sessionEnded` to clean up Claude Island state

### Delete vs Archive

- Archive: mark session as ended in Claude Island (existing behavior, doesn't touch tmux)
- Delete: kill tmux session AND remove from Claude Island. Confirmation required.

## Customizable Visible Actions

### Settings

- New row in `NotchMenuView`: "Session Actions" with chevron
- Expands to reorderable list of all 7 actions
- Top 3 are visible quick buttons, rest go to overflow
- Reorder using `.draggable` + `.dropDestination` pattern from `ModuleLayoutSettingsView` (lines 54-213) -- NOT `List` + `.onMove` (incompatible with notch's dark `ScrollView` + `VStack` styling)
- `...` overflow button always present, can't be removed/reordered
- Changes apply immediately
- Pass the action order as a parameter from `ClaudeInstancesView` to `InstanceRow` to avoid per-row `UserDefaults` reads in `LazyVStack`

### Storage

- Ordered action list in `AppSettings` as JSON-encoded `[SessionActionType]` via `JSONEncoder`/`JSONDecoder` (same pattern as `moduleLayoutConfig`)
- `SessionActionType` is a `String`-backed `RawRepresentable` enum for clean encoding
- Default: `[.chat, .focus, .archive, .copyAttach, .delete, .pinProject, .assignShortcut]`

## Shortcuts Settings Menu

### Location

New row in `NotchMenuView`: keyboard icon + "Shortcuts" label + chevron. Positioned after "Projects" row (Chunk 2) or after "Hooks" row if Chunk 2 is not yet implemented.

### Menu Height

Adding Shortcuts and Session Actions expandable sections to `NotchMenuView` increases content. The menu is inside a `ScrollView` (line 40) which handles overflow. However, the `openedSize` base height of 500px (NotchViewModel line ~125) may need increasing by ~80px (two new collapsed row headers at ~40px each). When expanded, content scrolls naturally within the ScrollView.

### Expanded View

#### Global Section

- Header: "Global" in small gray label
- Single row: "New Session" + key recorder
- Help text: "Opens the session launcher from anywhere"

#### Sessions Section

- Header: "Sessions" in small gray label
- One row per active binding: session display title + key recorder
- Only active bindings listed (sessions without shortcuts not shown)
- Re-record or clear with X
- Session ends -> row disappears (via `HotkeyManager` cleanup)
- Empty state: "No session shortcuts assigned" + help text about overflow menu

## Panel Layering

The launcher panel (`SessionLauncherPanel`) and overflow menu can never appear simultaneously -- the launcher is a modal-like floating panel that dismisses on outside click, and the overflow menu is an overlay within the notch. If the notch is visible and user clicks `...`, the overlay appears within the notch. If the launcher is open, the notch is behind it and not interactive.

## New Files

- `HotkeyManager.swift` -- `@Observable final class`, CGEvent tap + dispatch, deferred start, health check
- `KeyCombo.swift` -- Model with custom Codable (stores modifiers as UInt), keyCode-to-display via UCKeyTranslate
- `KeyRecorderView.swift` -- Reusable SwiftUI recorder with local event monitor
- `ShortcutsSettingsView.swift` -- Expandable settings section
- `SessionActionOverflowMenu.swift` -- Overlay dropdown view
- `SessionActionsSettingsView.swift` -- Reorderable action list (following ModuleLayoutSettingsView pattern)

## Modified Files

- `ClaudeInstancesView.swift` -- Add `@State showOverflowFor` for dropdown overlay, add `...` button to `InstanceRow`, add `onCopyAttach`/`onDelete`/`onPinProject`/`onAssignShortcut` callbacks, skip customizable buttons during approval states, pass action order as parameter from parent, handle conditional action visibility
- `NotchMenuView.swift` -- Add Shortcuts and Session Actions expandable settings sections
- `NotchViewModel.swift` -- Add `focusInputOnAppear` flag for per-session shortcut focus coordination. Note: `focusSession` logic lives in `HotkeyManager` which calls `viewModel.showChat(for:)` (existing method) + `viewModel.notchOpen(reason:)` directly. Increase `openedSize` base height for `.menu` by ~80px.
- `ChatView.swift` -- Observe `viewModel.focusInputOnAppear` via `.onChange`, set local `@FocusState` when true, reset flag after applying
- `SessionStore.swift` -- Unify all session removal through `processSessionEnd()` (route hook `status == "ended"` through it instead of direct removal). Add `var onSessionRemoved: (@Sendable (String) -> Void)?` callback, called from `processSessionEnd()`. Also clean up `pendingLaunches` (from Chunk 1) in the same method.
- `TmuxController.swift` -- Add `killSession(sessionName: String) async -> Bool` method using `ProcessExecutor`
- `AppDelegate.swift` -- Initialize `HotkeyManager`, wire `SessionStore.onSessionRemoved` to `HotkeyManager.removeShortcut(forSession:)`, add `HotkeyManager.startIfPermitted()` to accessibility grant callback
- `Settings.swift` -- New keys: `globalShortcut` (Data?, encoded KeyCombo via JSONEncoder), `sessionShortcuts` (Data?, encoded [String: KeyCombo]), `sessionActionOrder` (Data?, encoded [SessionActionType])

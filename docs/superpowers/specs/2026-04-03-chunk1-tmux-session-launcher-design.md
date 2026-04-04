# Chunk 1: Tmux Session Launcher

The core feature enabling session creation directly from Claude Island without touching a terminal.

## Overview

Users can create new Claude Code sessions from within Claude Island via a Raycast-style floating panel or (later, Chunk 3) a global keyboard shortcut. The launcher creates a tmux session, starts Claude, sends the user's prompt, and integrates seamlessly with the existing hook-driven session monitoring.

## Entry Point: New Session Row

### Placement

A dashed "New Session" row at the bottom of `ClaudeInstancesView`, always visible after all session rows.

### When List Is Empty

Replaces the current empty state ("No sessions / Run claude in terminal"). The dashed row becomes the only content, centered vertically.

### Appearance

- Same width and padding as `InstanceRow` (defined in `ClaudeInstancesView.swift`, not a separate file)
- 1px dashed border, rounded corners matching session rows (~8px)
- Border color: white at ~20% opacity
- Interior: `+` icon on left (matching status dot position), "New Session" text
- Text color: white at ~40% opacity
- On hover: border brightens to ~40% opacity, slight background fill

### Interaction

Click opens the launcher panel. No other buttons on this row.

### Implementation

- New `NewSessionRow` view added after the `ForEach` in `ClaudeInstancesView.instancesList` (inside the existing `LazyVStack`)
- Also replaces `emptyState` view (lines 54-65)
- Calls a callback that the parent wires to `SessionLauncherPanel.show()`
- `.launching` phase sessions sort at priority 0 in `phasePriority(_:)` (same as processing) so newly created sessions appear at the top

## Launcher Panel (NSPanel)

### Window Configuration

- Type: `NSPanel` subclass (following `NotchPanel` pattern in `NotchWindow.swift`)
- Style mask: `[.borderless, .nonactivatingPanel, .fullSizeContentView]`
- `isFloatingPanel = true`
- Window level: `.mainMenu + 4` (above the notch panel which is at `.mainMenu + 3`)
- Does not steal app activation (terminal stays active behind it)

### Dismiss Behavior

- **Escape key**: Override `cancelOperation(_:)` on the panel OR use `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` to catch Escape while panel is key window
- **Click outside**: `NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown)` + local monitor to detect clicks outside panel bounds, then dismiss
- Remove both monitors on dismiss to prevent leaks

### Appearance

- Centered on the screen containing the notch
- ~500px wide, height dynamic based on content
- Background: `NSVisualEffectView` with `.hudWindow` material as the panel's `contentView`, with the `NSHostingView` (SwiftUI) added as a subview of the visual effect view. This gives frosted glass look.
- Corner radius ~16px (set via `contentView.wantsLayer = true; contentView.layer?.cornerRadius = 16`)
- Subtle shadow for depth
- No title bar

### Animation

- Appears: scale from 0.95 to 1.0 with fade in (~150ms) via `NSAnimationContext` or SwiftUI animation
- Dismisses: fade out (~100ms)

### Key Window Behavior

- Becomes key window on appear (receives keyboard input)
- Resigns key window on dismiss
- `NotchPanel` is already `.nonactivatingPanel` so no interference
- If both panels are visible, only the launcher is key (notch is non-interactive behind it)

### SwiftUI Bridge

Following the existing pattern in `NotchViewController.swift`:
1. `NSVisualEffectView` (.hudWindow material) as panel's `contentView`
2. `NSHostingView(rootView: SessionLauncherView(...))` added as subview with autoresizing constraints
3. No need for `PassThroughHostingView` -- launcher is fully opaque, no click-through regions
4. Auto-focus: set `@FocusState` on prompt field, may need `DispatchQueue.main.async` delay after panel becomes key

## Launcher View (SwiftUI)

### Layout (vertical stack, top to bottom)

#### 1. Prompt Field

- `TextEditor` (multiline) with placeholder "What should Claude do?"
- Auto-focused on panel appear via `@FocusState`
- Min height ~40px, grows up to ~120px as text increases (then scrolls internally)
- Font: system 15pt, regular weight
- Subtle border, rounded corners
- Enter submits (Shift+Enter for newline)

#### 2. Session Name Field (hidden by default)

- Pressing Tab from prompt field reveals it with a slide-down animation
- Single-line `TextField`, placeholder: "Session name (optional)"
- Font: system 13pt
- Auto-generation if left empty:
  - First ~30 chars of prompt, lowercased, spaces to hyphens, special chars stripped, no dots or colons (tmux restrictions)
  - If prompt is also empty: `claude-YYYY-MM-DD-HHMM`
- Tab again moves to directory picker

#### 3. Directory Picker (Chunk 1 minimal version)

- Shows: last used directory (from `AppSettings.lastUsedDirectory`), home directory, "Browse..."
- Arrow keys move highlight, Enter selects
- "Browse..." opens `NSOpenPanel`, result fills selection
- Default selection: last used directory if set, otherwise home
- Chunk 2 replaces this with the full pinned/recent system

#### 4. Bottom Bar

- Shows resolved command preview in monospace (`Text` with `.font(.system(size: 11, design: .monospaced))`)
- Gray text
- Updates live as session name or directory changes

### Keyboard Flow

- Panel opens -> cursor in prompt
- Type prompt -> Tab -> name field appears -> type name (optional) -> Tab -> directory list focused
- Arrow keys to pick directory -> Enter -> submits everything
- Fast path: type prompt -> Enter -> submits with defaults (auto name, last used directory from `AppSettings.lastUsedDirectory`)

## TmuxSessionCreator Service

### Type

New actor: `TmuxSessionCreator`. Delegates tmux commands to existing infrastructure (`ProcessExecutor`, `TmuxPathFinder`) rather than reimplementing.

### Public API

```swift
func launch(prompt: String, sessionName: String, directory: String, commandTemplate: String) async throws(LaunchError)
```

### Execution Steps

**Step 1 -- Validate prerequisites**
- Find tmux binary: reuse `TmuxPathFinder.shared.getTmuxPath()` which already checks `/opt/homebrew/bin/tmux`, `/usr/local/bin/tmux`, `/usr/bin/tmux`, `/bin/tmux`
- Find claude binary: reuse `CLIVersionDetector.findClaudeBinary()` which checks `/usr/local/bin/claude`, `~/.claude/bin/claude`, and falls back to `which claude`
- Cache resolved paths for the session lifetime
- Verify directory exists
- If any fail, throw typed `LaunchError` with actionable message (e.g., "tmux not found. Install with: brew install tmux")

**Step 2 -- Resolve session name**
- Sanitize: lowercase, spaces to hyphens, strip non-alphanumeric (except hyphens), no dots or colons (tmux restrictions)
- Collision check: `ProcessExecutor.runWithResult(tmuxPath, arguments: ["has-session", "-t", name])` -- check `exitCode` (0 = exists, 1 = doesn't exist). Use `runWithResult` not `run` since non-zero exit is expected.
- If exists, append `-2`, `-3`, etc.
- Max length: 50 chars

**Step 3 -- Create tmux session**
- `ProcessExecutor.run(tmuxPath, arguments: ["new-session", "-d", "-s", name, "-c", directory])`
- `-d` creates it detached (no terminal window opens)
- Progress: "Creating tmux session..."

**Step 4 -- Resolve and run Claude command**
- Substitute variables in template: `{{name}}`, `{{date}}`, `{{time}}`, `{{dir}}`
- Send to pane using `-l` flag for literal text (prevents shell interpretation of special chars): `ProcessExecutor.run(tmuxPath, arguments: ["send-keys", "-t", name, "-l", resolvedCommand])` then `ProcessExecutor.run(tmuxPath, arguments: ["send-keys", "-t", name, "Enter"])`
- This matches the existing `ToolApprovalHandler.sendKeys(to:keys:pressEnter:)` pattern
- Progress: "Starting Claude..."

**Step 5 -- Wait for hook**
- Listen for `SessionStart` hook event matching this tmux session
- Timeout: 15 seconds -- if no hook fires, show error state
- Matching mechanism: see "Merging Provisional to Real Session" section below
- Progress: "Waiting for connection..."

**Step 6 -- Send prompt**
- Once `SessionStart` received and Claude is in `.waitingForInput` state (which `SessionStart` produces), send the prompt
- Small defensive delay (~200ms) before sending to ensure Claude's REPL is fully ready
- Use same `send-keys -l` pattern as step 4 for literal text
- Progress: "Sending prompt..."
- After this, normal hook flow takes over (`UserPromptSubmit` -> `.processing`)

### Error Types

```swift
enum LaunchError: Error, Sendable, Equatable {
    case tmuxNotInstalled
    case claudeNotInstalled
    case directoryNotFound(String)
    case tmuxSessionCreationFailed(String)
    case claudeStartTimeout
    case promptSendFailed(String)
}
```

Note: `LaunchError` must be `Equatable` because `LaunchProgress.failed(LaunchError)` requires it for `LaunchProgress: Equatable`.

### Relationship to SessionStore

- Creates a provisional `SessionState` with `.launching` phase immediately after step 3
- Sends events to `SessionStore` at each progress step
- Once hook fires (step 5), hook-driven flow takes over and provisional state merges with real session

## New SessionPhase: `.launching`

### State Machine Addition

```
.launching(LaunchProgress) -> .idle -> .processing -> ...
```

### LaunchProgress

```swift
enum LaunchProgress: Sendable, Equatable {
    case creatingTmuxSession
    case startingClaude
    case waitingForHook
    case sendingPrompt
    case failed(LaunchError)
}
```

### Transition Rules

- `.launching` can only transition to `.idle` (hook fires successfully) or stay in `.launching` with updated progress
- `.launching(.failed)` allows retry (resets to `.creatingTmuxSession`) or dismiss (removes session)
- No other phase can transition to `.launching` -- it is only set at session creation time
- `.launching` has `needsAttention = false`, `isActive = false` (no user action needed, no PID to check)

### Required Updates to SessionPhase.swift

The following exhaustive switches/properties must be updated with a `.launching` case:

1. **`PhaseKey` enum** (line ~160-183) -- Add `.launching` case and update `matches(_:)` to handle associated `LaunchProgress` value. **Critical**: without this, `canTransition(to:)` will never match `.launching` as a valid transition target.
2. **`allowedTransitions(from:)`** (line ~187-203) -- Add `.launching: [.idle, .launching]`
3. **`needsAttention`** (line ~100-108) -- Add `.launching: false` (currently falls through to `default: false` but an explicit case is better)
4. **`isActive`** (line ~111-118) -- Add `.launching: false`
5. **`Equatable` conformance** (line ~208-221) -- Add `case let (.launching(p1), .launching(p2)): p1 == p2`
6. **`CustomStringConvertible`** (line ~225-242) -- Add description for `.launching`

Also update exhaustive switches in other files:
7. **`ClaudeInstancesView.phasePriority(_:)`** (line ~88-98) -- Add `.launching: 0`
8. **`ClaudeInstancesView.InstanceRow.phaseStatusText`** (line ~195-204) -- Add `.launching` with progress-based text
9. **`ClaudeInstancesView.InstanceRow.stateIndicator`** (line ~355-381) -- Add `.launching` with pulsing ring rendering

### New SessionEvent Cases

```swift
case sessionLaunching(SessionLaunchPayload)
case launchProgressUpdated(sessionID: String, progress: LaunchProgress)
case launchCompleted(sessionID: String)
case launchFailed(sessionID: String, error: LaunchError)
```

Must also update:
- `SessionEvent.sessionID` computed property (line ~213-238) for all 4 new cases
- `SessionEvent.description` (line ~242-277) for all 4 new cases

### SessionLaunchPayload

```swift
struct SessionLaunchPayload: Sendable {
    let sessionID: String          // Generated UUID, provisional
    let sessionName: String        // The tmux session name
    let cwd: String               // Selected directory
    let prompt: String            // The user's prompt
    let commandTemplate: String   // The resolved claude command
}
```

### Merging Provisional to Real Session

When `SessionStart` hook fires, we need to match it to a pending launch. **The `HookEvent` does NOT contain a tmux session name** -- it only has `sessionID`, `cwd`, `pid`, and `tty`. Matching requires an async lookup.

**Merge mechanism:**
- `SessionStore` maintains a `pendingLaunches: [String: String]` dictionary mapping tmux session name to provisional session ID
- When a `SessionStart` hook arrives AND `pendingLaunches` is non-empty:
  1. Call `TmuxTargetFinder.shared.findTarget(forClaudePID: hookEvent.pid)` asynchronously to get the `TmuxTarget`
  2. Compare `TmuxTarget.session` (the tmux session name) against `pendingLaunches` keys
  3. Also verify `hookEvent.cwd` matches the pending launch's `cwd` as a corroborating signal
  4. If matched: remove the provisional session, create the real session (using the hook's `sessionID`) with the same display name and `cwd`, emit a `launchCompleted` event
- When `pendingLaunches` is empty, skip the `TmuxTargetFinder` lookup entirely (no performance impact on normal hook processing)
- The real session starts in `.idle` phase (from the hook), then immediately receives the prompt (step 6) transitioning to `.processing`
- If no match within 15 seconds: `launchFailed(.claudeStartTimeout)` is emitted and the provisional session transitions to `.launching(.failed)`

**SwiftUI identity during merge:**
- The provisional session has a UUID-based `stableID` and the real session will have a different `stableID` (based on the hook's session ID)
- To prevent a visible removal + insertion animation, use `.id(session.sessionID)` with an explicit `matchedGeometryEffect` on the row, keyed by the tmux session name (which is stable across the merge)
- Alternative simpler approach: keep the provisional `stableID` on the real session by copying it during merge. Since `stableID` is just for SwiftUI identity, this is safe.

## Progress Animation in Session Row

### Launching State

- Left indicator: pulsing animated ring (blue `#0a84ff`, opacity oscillates 40%-100%)
- Title: session name
- Subtitle: progress text with crossfade transitions between steps
- Action buttons: hidden, replaced with small "Cancel" text button
- Cancel: kills tmux session (`tmux kill-session -t <name>`) and removes provisional session
- The `.launching` check in `InstanceRow` (inside `ClaudeInstancesView.swift`) must intercept the normal button rendering. Current action buttons area (line ~316-342) would show chat/terminal/archive for an unknown phase -- add explicit `.launching` branch before the `else` block.

### Failed State (`.launching(.failed)`)

- Left indicator: solid red dot
- Title: session name
- Subtitle: error message
- Action buttons: "Retry" and "Dismiss"
- Retry: resets to `.launching(.creatingTmuxSession)`, re-runs TmuxSessionCreator
- Dismiss: removes provisional session
- `InstanceRow` needs `onCancel`, `onRetry`, `onDismiss` callbacks (optional, nil for non-launching sessions)

### Transition to Normal

- `.launching` -> `.idle`: pulsing ring becomes solid green dot, progress text replaced by normal subtitle
- If using the "copy stableID" merge approach, SwiftUI sees a property update on the same identity -- smooth transition

## Claude Command Configuration

### Settings Menu

- New row in `NotchMenuView`: command icon + "Claude Command" label + chevron
- Expands to show a text field with the command template (following `TokenTrackingRow` expansion pattern)
- Default: `claude`
- **Must update `openedSize` for `.menu` content type** (line ~125-128 in `NotchViewModel.swift`) to account for the expanded section height (~60px when expanded), or content will be clipped

### Supported Variables

| Variable | Value |
|---|---|
| `{{name}}` | Session name from launcher |
| `{{date}}` | Current date (YYYY-MM-DD) |
| `{{time}}` | Current time (HH-MM) |
| `{{dir}}` | Selected project directory path |

### Examples

- `claude` -- simplest
- `claude --worktree {{date}}-{{name}}` -- dated worktree
- `claude --resume` -- always resume last conversation
- `claude -p "You are a senior engineer"` -- custom system prompt

### Validation

- Command must start with `claude` (prevents arbitrary command execution)
- Invalid variables show inline warning

### Preview

- Resolved command shown in launcher bottom bar, updates live

## Post-Creation Flow

1. User submits from launcher
2. Launcher panel dismisses immediately (remove event monitors)
3. Notch auto-expands via `viewModel.notchOpen(reason: .sessionCreated)` -- always, regardless of the "Notch Auto-Expand" setting (this is an explicit user action, not a passive notification). Add `.sessionCreated` to `NotchOpenReason`.
4. `contentType` set to `.instances` so user sees the session list
5. New session row appears at top with `.launching` phase
6. Progress text animates through stages
7. Hook fires -> session merges -> transitions to normal `.idle` -> `.processing`
8. User monitors session like any other

## New Files

- `SessionLauncherPanel.swift` -- NSPanel subclass + NSVisualEffectView setup + dismiss monitors
- `SessionLauncherView.swift` -- SwiftUI launcher content (prompt, name, directory picker, bottom bar)
- `TmuxSessionCreator.swift` -- Actor, launch orchestration using existing ProcessExecutor/TmuxPathFinder/CLIVersionDetector
- `NewSessionRow.swift` -- Dashed row view

## Modified Files

- `SessionPhase.swift` -- Add `.launching(LaunchProgress)` case, update `PhaseKey` enum + `matches(_:)`, update `allowedTransitions(from:)`, add explicit cases in `needsAttention`/`isActive`/`Equatable`/`CustomStringConvertible`
- `SessionEvent.swift` -- Add 4 launch event cases + `SessionLaunchPayload`, update `sessionID` computed property and `description`
- `SessionStore.swift` -- Handle 4 new event cases in `process(_:)`, add `pendingLaunches` dictionary, add async `TmuxTargetFinder` lookup in `processHookEvent` when pending launches exist, merge provisional sessions
- `ClaudeInstancesView.swift` -- Add `NewSessionRow` after `ForEach`, replace `emptyState`, add `.launching` case to `phasePriority`, update `InstanceRow` with `.launching` rendering (pulsing ring, progress text, cancel/retry/dismiss), add optional `onCancel`/`onRetry`/`onDismiss` callbacks to `InstanceRow`
- `NotchMenuView.swift` -- Add Claude Command expandable settings section (following `TokenTrackingRow` pattern)
- `NotchViewModel.swift` -- Add `showLauncher()` method (calls `SessionLauncherPanel.shared.show()`), update `openedSize` for `.menu` to include Claude Command section height, add `.sessionCreated` to `NotchOpenReason`
- `WindowManager.swift` (or `AppDelegate.swift`) -- Create `SessionLauncherPanel` after `NotchWindowController` setup, pass `NotchViewModel` reference for post-creation auto-expand
- `Settings.swift` -- Add `claudeCommandTemplate` (String, default "claude") and `lastUsedDirectory` (String?, default nil) to private `Keys` enum + static computed properties with UserDefaults getter/setter

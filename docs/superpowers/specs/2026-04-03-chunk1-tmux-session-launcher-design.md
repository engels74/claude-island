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

- Same width and padding as `InstanceRow`
- 1px dashed border, rounded corners matching session rows (~8px)
- Border color: white at ~20% opacity
- Interior: `+` icon on left (matching status dot position), "New Session" text
- Text color: white at ~40% opacity
- On hover: border brightens to ~40% opacity, slight background fill

### Interaction

Click opens the launcher panel. No other buttons on this row.

### Implementation

- New `NewSessionRow` view added after the `ForEach` in `ClaudeInstancesView.instancesList`
- Also replaces `emptyState` view
- Calls a callback that the parent wires to `SessionLauncherPanel.show()`
- `.launching` phase sessions sort at priority 0 (same as processing) so newly created sessions appear at the top

## Launcher Panel (NSPanel)

### Window Configuration

- Type: `NSPanel` with `.nonactivatingPanel` + `.fullSizeContentView` style mask
- Does not steal app activation (terminal stays active behind it)
- Escape key dismisses
- Clicking outside dismisses

### Appearance

- Centered on the screen containing the notch
- ~500px wide, height dynamic based on content
- Dark translucent background using `NSVisualEffectView` with `.hudWindow` material (frosted glass)
- Corner radius ~16px
- Subtle shadow for depth
- No title bar

### Animation

- Appears: scale from 0.95 to 1.0 with fade in (~150ms)
- Dismisses: fade out (~100ms)

### Key Window Behavior

- Becomes key window on appear (receives keyboard input)
- Resigns key window on dismiss
- `NotchPanel` is already `.nonactivatingPanel` so no interference

## Launcher View (SwiftUI)

### Layout (vertical stack, top to bottom)

#### 1. Prompt Field

- `TextEditor` (multiline) with placeholder "What should Claude do?"
- Auto-focused on panel appear
- Min height ~40px, grows up to ~120px as text increases (then scrolls internally)
- Font: system 15pt, regular weight
- Subtle border, rounded corners
- Enter submits (Shift+Enter for newline)

#### 2. Session Name Field (hidden by default)

- Pressing Tab from prompt field reveals it with a slide-down animation
- Single-line `TextField`, placeholder: "Session name (optional)"
- Font: system 13pt
- Auto-generation if left empty:
  - First ~30 chars of prompt, lowercased, spaces to hyphens, special chars stripped
  - If prompt is also empty: `claude-YYYY-MM-DD-HHMM`
- Tab again moves to directory picker

#### 3. Directory Picker (Chunk 1 minimal version)

- Shows: last used directory (from `AppSettings`), home directory, "Browse..."
- Arrow keys move highlight, Enter selects
- "Browse..." opens `NSOpenPanel`, result fills selection
- Default selection: last used directory if set, otherwise home
- Chunk 2 replaces this with the full pinned/recent system

#### 4. Bottom Bar

- Shows resolved command preview in monospace, e.g., `claude --worktree 2026-04-03-session-name`
- Gray text, small font (11pt)
- Updates live as session name or directory changes

### Keyboard Flow

- Panel opens -> cursor in prompt
- Type prompt -> Tab -> name field appears -> type name (optional) -> Tab -> directory list focused
- Arrow keys to pick directory -> Enter -> submits everything
- Fast path: type prompt -> Enter -> submits with defaults (auto name, last directory)

## TmuxSessionCreator Service

### Type

New actor: `TmuxSessionCreator`

### Public API

```swift
func launch(prompt: String, sessionName: String, directory: String, commandTemplate: String) async throws(LaunchError)
```

### Execution Steps

**Step 1 -- Validate prerequisites**
- Check tmux is installed: try `/opt/homebrew/bin/tmux`, `/usr/local/bin/tmux`, then `which tmux` (handles PATH issues with Homebrew installs)
- Check claude is installed: same multi-path resolution
- Cache resolved paths for the session lifetime
- Verify directory exists
- If any fail, throw typed `LaunchError` with actionable message (e.g., "tmux not found. Install with: brew install tmux")

**Step 2 -- Resolve session name**
- Sanitize: lowercase, spaces to hyphens, strip non-alphanumeric (except hyphens)
- Collision check: `tmux has-session -t <name>` -- if exists, append `-2`, `-3`, etc.
- Max length: 50 chars

**Step 3 -- Create tmux session**
- `tmux new-session -d -s <name> -c <directory>`
- `-d` creates it detached (no terminal window opens)
- Progress: "Creating tmux session..."

**Step 4 -- Resolve and run Claude command**
- Substitute variables in template: `{{name}}`, `{{date}}`, `{{time}}`, `{{dir}}`
- Send to pane: `tmux send-keys -t <name> '<resolved command>' Enter`
- Progress: "Starting Claude..."

**Step 5 -- Wait for hook**
- Listen for `SessionStart` hook event matching this tmux session
- Timeout: 15 seconds -- if no hook fires, show error state
- Matching: hook reports PID/TTY, `TmuxTargetFinder` correlates pane PID with hook PID, tmux session name matches

**Step 6 -- Send prompt**
- Once `SessionStart` received and Claude is idle/waiting, send the prompt
- `tmux send-keys -t <name> -l '<prompt>' Enter` -- `-l` for literal text (handles special chars)
- Progress: "Sending prompt..."
- After this, normal hook flow takes over (`UserPromptSubmit` -> `.processing`)

### Error Types

```swift
enum LaunchError: Error, Sendable {
    case tmuxNotInstalled
    case claudeNotInstalled
    case directoryNotFound(String)
    case tmuxSessionCreationFailed(String)
    case claudeStartTimeout
    case promptSendFailed(String)
}
```

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
- `SessionPhase.canTransition(to:)` must be updated to include: `.launching -> .idle`, `.launching -> .launching` (progress updates)
- `.launching` has `needsAttention = false` (no user action needed during bootstrap)

### New SessionEvent Cases

```swift
case sessionLaunching(SessionLaunchPayload)
case launchProgressUpdated(sessionID: String, progress: LaunchProgress)
case launchCompleted(sessionID: String)
case launchFailed(sessionID: String, error: LaunchError)
```

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

When `SessionStart` hook fires:
- `TmuxTargetFinder` locates the pane by PID
- If pane's tmux session name matches created session name -> merge

**Merge mechanism:**
- `SessionStore` maintains a `pendingLaunches: [String: String]` dictionary mapping tmux session name to provisional session ID
- When a `SessionStart` hook arrives, `SessionStore` checks if the hook's tmux session name has a pending launch
- If matched: remove the provisional session, create the real session (using the hook's `sessionID`) with the same `sessionName` and `cwd`, emit a `launchCompleted` event
- The real session starts in `.idle` phase (from the hook), then immediately receives the prompt (step 6) transitioning to `.processing`
- Subscribers see the provisional session disappear and real session appear in the same position (same sort priority) in the same publish cycle -- no flash
- If no match within 15 seconds: `launchFailed(.claudeStartTimeout)` is emitted and the provisional session transitions to `.launching(.failed)`

## Progress Animation in Session Row

### Launching State

- Left indicator: pulsing animated ring (blue `#0a84ff`, opacity oscillates 40%-100%)
- Title: session name
- Subtitle: progress text with crossfade transitions between steps
- Action buttons: hidden, replaced with small "Cancel" text button
- Cancel: kills tmux session (`tmux kill-session -t <name>`) and removes provisional session

### Failed State (`.launching(.failed)`)

- Left indicator: solid red dot
- Title: session name
- Subtitle: error message
- Action buttons: "Retry" and "Dismiss"
- Retry: resets to `.launching(.creatingTmuxSession)`, re-runs TmuxSessionCreator
- Dismiss: removes provisional session

### Transition to Normal

- `.launching` -> `.idle`: pulsing ring becomes solid green dot, progress text replaced by normal subtitle
- Smooth, no flash or layout jump

## Claude Command Configuration

### Settings Menu

- New row in `NotchMenuView`: command icon + "Claude Command" label + chevron
- Expands to show a text field with the command template
- Default: `claude`

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
2. Launcher panel dismisses immediately
3. Notch auto-expands (`NotchViewModel.status = .opened`) -- always, regardless of the "Notch Auto-Expand" setting (this is an explicit user action, not a passive notification)
4. New session row appears at top with `.launching` phase
5. Progress text animates through stages
6. Hook fires -> session transitions to normal `.idle` -> `.processing`
7. User monitors session like any other

## New Files

- `SessionLauncherPanel.swift` -- NSPanel subclass
- `SessionLauncherView.swift` -- SwiftUI launcher content
- `TmuxSessionCreator.swift` -- Actor, launch orchestration
- `NewSessionRow.swift` -- Dashed row view

## Modified Files

- `SessionPhase.swift` -- Add `.launching(LaunchProgress)` case, update `canTransition(to:)`, add `needsAttention` return for new case
- `SessionEvent.swift` -- Add launch event cases and `SessionLaunchPayload`
- `SessionStore.swift` -- Handle launch events, add `pendingLaunches` dictionary, merge provisional sessions on `SessionStart` hook match
- `ClaudeInstancesView.swift` -- Add NewSessionRow after ForEach, replace empty state
- `InstanceRow.swift` -- Conditional rendering for `.launching` phase (pulsing ring, progress text, cancel button, failed state with retry/dismiss)
- `NotchMenuView.swift` -- Add Claude Command settings section
- `NotchViewModel.swift` -- Expose `showLauncher()` method, auto-expand on creation
- `AppDelegate.swift` -- Initialize `SessionLauncherPanel`
- `AppSettings.swift` -- Add `claudeCommandTemplate` (String, default "claude") and `lastUsedDirectory` (String?, default nil) following existing pattern: add to private `Keys` enum + static computed property with UserDefaults getter/setter
- `AppDelegate.swift` -- Initialize launcher panel
- `AppSettings.swift` -- New keys: `claudeCommandTemplate`, `lastUsedDirectory`

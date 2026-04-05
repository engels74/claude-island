# Session Launcher Redesign

Redesign the `SessionLauncherView` from a cluttered all-at-once layout to a clean Raycast-style interface with progressive disclosure. This replaces both the chunk 1 minimal picker and the chunk 2 inline list with a dropdown overlay.

## Overview

The launcher replaces its current layout (prompt + full directory picker with section headers + command preview + Launch button) with a minimal two-zone design: prompt field on top, single "in [project]" row below. The session name and directory picker are revealed only on demand. The Launch button is removed — Enter submits.

## Layout

### Default State (on open)

Top to bottom:
1. **Prompt field** — auto-focused `TextEditor`, placeholder "What should Claude do?", subtle blue focus border
2. **Divider** — `Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.horizontal, 16)` (not SwiftUI `Divider()` which has different default styling)
3. **Directory row** — "in" label (uppercase, 11px, 30% opacity) + star icon + project name (13px, medium weight) + chevron-down. Clickable — opens directory picker dropdown
4. **Hint bar** — centered text at ~18% opacity: `Tab: session name · ↵ launch · Esc cancel`

No Launch button. No session name field visible by default. No directory picker list visible by default.

### Prompt Field

- `TextEditor` (multiline) with placeholder "What should Claude do?"
- Auto-focused on panel appear (with 150ms async delay + `NSApp.activate` for `nonactivatingPanel`)
- Placeholder text has `.allowsHitTesting(false)` to prevent cursor offset
- Min height ~44px, grows to ~120px, then scrolls internally
- Font: system 15px
- Background: `Color.white.opacity(0.06)`, 10px corner radius
- Focus border: `.overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(red: 0.04, green: 0.52, blue: 1.0).opacity(focusedField == .prompt ? 0.4 : 0), lineWidth: 1.5))` — animates in/out with `.animation(.easeInOut(duration: 0.15))`
- Enter submits (Shift+Enter for newline)
- Tab reveals session name field

### Session Name Field (hidden by default)

- Appears between prompt and divider when Tab is pressed
- Slides in with `.spring(response: 0.25, dampingFraction: 0.8)` animation
- Layout: "as" label (uppercase, 11px, `.tracking(0.5)`, `Color.white.opacity(0.3)`) + `TextField` with auto-generated value as placeholder
- Auto-generated name used as `.prompt()` placeholder on the TextField — the `sessionName` binding stays empty. If empty at submit time, `resolvedSessionName` falls through to the auto-generated value (matching the current implementation pattern)
- If prompt is empty: `claude-YYYY-MM-DD-HHMM`
- Background: `Color.white.opacity(0.06)`, 10px corner radius (matching prompt field)
- Focus border: same overlay pattern as prompt field, conditional on `focusedField == .name`
- Enter from this field submits

### Directory Row

- Single row, not a list — shows the currently selected project
- "in" prefix label: uppercase, 11px, `Color.white.opacity(0.3)`, `.tracking(0.5)` (SwiftUI's letter-spacing equivalent)
- Star icon (yellow `#f5c542`, for pinned) or clock icon (for recent) + project display name (13px, medium weight)
- Chevron-down indicator on the right (rotates to chevron-up when dropdown is open)
- Click toggles the directory picker dropdown. Clicking again closes it.
- Default selection: `AppSettings.lastUsedDirectory` if set, otherwise first pinned, otherwise home directory as fallback

### Directory Picker Dropdown

- Controlled by `@State private var isDropdownOpen: Bool`
- **Panel height grows dynamically** when dropdown is open — the `NSHostingView` uses autoresizing constraints (already in place), so SwiftUI's intrinsic size change propagates to the panel. No manual frame updates needed.
- Renders inside the main VStack (not as a `.overlay`) so the panel resizes naturally. Appears below the directory row with slide animation.
- Background: `Color(red: 0.06, green: 0.06, blue: 0.12).opacity(0.98)` with 1px border at `Color.white.opacity(0.1)`, 8px radius, shadow `.shadow(color: .black.opacity(0.4), radius: 8, y: 4)`
- Sections with small uppercase headers (9px, `.tracking(0.5)`, 25% opacity): "Pinned", "Recent"
- Pinned rows: star icon + name + checkmark if selected
- Recent rows: clock icon + name + relative time (via `SessionPhaseHelpers.timeAgo`)
- Divider between sections
- "Browse..." row at bottom with folder icon
- **Arrow key navigation** — `.onKeyPress` handlers only active when `isDropdownOpen == true`. When dropdown is closed, arrow keys pass through to the TextEditor normally.
- Enter to select, Esc to close dropdown (not dismiss panel — see Esc Handling below)
- Selecting a project updates the directory row and closes the dropdown
- Browse opens NSOpenPanel (with z-order workaround: order out launcher panel first)
- **Empty state**: when both pinned and recent are empty, show Home directory as single entry + Browse

### Esc Key Handling

Esc is handled entirely in SwiftUI via `.onKeyPress(.escape)` on the view — the panel's local `NSEvent` monitor for keyCode 53 (Escape) is **removed** from `SessionLauncherPanel`. This prevents the panel from swallowing Esc before SwiftUI can process it.

Priority chain:
1. If `isDropdownOpen`: close dropdown, return `.handled`
2. If `showNameField` and name field is focused: hide name field, move focus back to prompt, return `.handled`
3. Otherwise: call `onDismiss()` to dismiss the panel

The `onDismiss` closure is still part of the view's interface — it's called from the Esc handler and potentially from any future "Cancel" interaction.

### Bottom Bar

**Conditional display based on whether command template has variables** — detected by checking `AppSettings.claudeCommandTemplate.contains("{{")`.

**When template is just "claude" (no `{{` present):**
- Single line: keyboard hints
- Centered, 10px font, `Color.white.opacity(0.18)`

**When template has variables (contains `{{`):**
- Two lines:
  - Line 1: resolved command in `.system(size: 10, design: .monospaced)`, `Color.white.opacity(0.22)`
  - Line 2: keyboard hints in 9px (slightly smaller to create visual hierarchy), `Color.white.opacity(0.13)`
- Updates live as prompt/name/directory change

### Hint Bar Content by State

| State | Hints shown |
|---|---|
| Prompt focused | `Tab: session name · ↵ launch · Esc cancel` |
| Name field focused | `↵ launch · Esc cancel` |
| Directory picker open | `↑↓ navigate · ↵ select · Esc close` |

### Dropdown State Transitions

| User action | Current state | Result |
|---|---|---|
| Click directory row | Dropdown closed | Dropdown opens |
| Click directory row | Dropdown open | Dropdown closes |
| Click elsewhere in panel | Dropdown open | Dropdown closes |
| Press Tab | Dropdown open | Dropdown closes, name field appears |
| Select a project | Dropdown open | Selection applied, dropdown closes |
| Press Esc | Dropdown open | Dropdown closes |

## Keyboard Flow

- Panel opens → cursor in prompt
- Type prompt → Enter → submits with defaults (auto name, last used directory)
- Type prompt → Tab → name field slides in → edit name → Enter → submits
- Click "in [project]" row → dropdown opens → arrow keys → Enter selects → dropdown closes
- Esc → closes dropdown first if open, then hides name field if visible, then dismisses panel

## Post-Submit Behavior

1. Panel dismisses immediately
2. Notch auto-expands with `.sessionCreated` reason
3. Content type set to `.instances` (session list)
4. Provisional session appears with launching progress
5. After hook merge, chat view opens automatically for the new session

## Modified Files

- `ClaudeIsland/UI/Views/SessionLauncherView.swift` — full rewrite of the view body
- `ClaudeIsland/UI/Views/DirectoryPickerView.swift` — refactor to render as inline expandable section (not overlay) with dropdown styling
- `ClaudeIsland/UI/Window/SessionLauncherPanel.swift` — remove local Escape key monitor (Esc now handled in SwiftUI)

## What Does NOT Change

- `SessionLauncherPanel.swift` — NSPanel setup, dismiss behavior, handleSubmit (only the Esc monitor is removed)
- `TmuxSessionCreator.swift` — launch orchestration (unchanged)
- `ProjectStore.swift` — data layer (unchanged)
- `NewSessionRow.swift` — entry point (unchanged)

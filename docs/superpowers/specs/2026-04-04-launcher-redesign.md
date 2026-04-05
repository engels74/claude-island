# Session Launcher Redesign

Redesign the `SessionLauncherView` from a cluttered all-at-once layout to a clean Raycast-style interface with progressive disclosure.

## Overview

The launcher replaces its current layout (prompt + full directory picker with section headers + command preview + Launch button) with a minimal two-zone design: prompt field on top, single "in [project]" row below. The session name and directory picker are revealed only on demand. The Launch button is removed — Enter submits.

## Layout

### Default State (on open)

Top to bottom:
1. **Prompt field** — auto-focused `TextEditor`, placeholder "What should Claude do?", subtle blue focus border
2. **Divider** — 1px at `Color.white.opacity(0.06)`, horizontal margins 16px
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
- Focus border: 1.5px `rgba(10,132,255,0.4)`
- Enter submits (Shift+Enter for newline)
- Tab reveals session name field

### Session Name Field (hidden by default)

- Appears between prompt and divider when Tab is pressed
- Slides in with `.spring(response: 0.25, dampingFraction: 0.8)` animation
- Layout: "as" label (same style as "in") + text field with auto-generated value
- Auto-generated from prompt: first 30 chars, lowercased, spaces to hyphens, non-alphanumeric stripped
- Shown as placeholder text (40% opacity) — editable, clears on first keystroke
- If prompt is empty: `claude-YYYY-MM-DD-HHMM`
- Background: `Color.white.opacity(0.06)`, 8px corner radius
- Focus border: 1.5px `rgba(10,132,255,0.4)`
- Enter from this field submits

### Directory Row

- Single row, not a list — shows the currently selected project
- "in" prefix label: uppercase, 11px, `Color.white.opacity(0.3)`, letter-spacing 0.5px
- Star icon (yellow, for pinned) or clock icon (for recent) + project display name
- Chevron-down indicator on the right
- Click opens the directory picker dropdown
- Default selection: `AppSettings.lastUsedDirectory` if set, otherwise first pinned, otherwise home

### Directory Picker Dropdown

- Opens as an overlay below the directory row when clicked
- Background: `rgba(15,15,30,0.98)` with 1px border at `Color.white.opacity(0.1)`, 8px radius, drop shadow
- Sections with small uppercase headers: "Pinned", "Recent"
- Pinned rows: star icon + name + checkmark if selected
- Recent rows: clock icon + name + relative time (via `SessionPhaseHelpers.timeAgo`)
- Divider between sections
- "Browse..." row at bottom with folder icon
- Arrow key navigation, Enter to select, Esc to close
- Selecting a project updates the directory row and dismisses the dropdown
- Browse opens NSOpenPanel (with z-order workaround)

### Bottom Bar

**When command template is just "claude" (default):**
- Single line: `Tab: session name · ↵ launch · Esc cancel`
- Centered, 10px font, `Color.white.opacity(0.18)`

**When command template has variables (e.g., `claude --worktree {{date}}-{{name}}`):**
- Two lines:
  - Line 1: resolved command in monospace, 10px, `Color.white.opacity(0.22)`
  - Line 2: keyboard hints in 9px, `Color.white.opacity(0.13)`
- Updates live as prompt/name/directory change

### Hint Bar Updates by State

| State | Hints shown |
|---|---|
| Prompt focused | `Tab: session name · ↵ launch · Esc cancel` |
| Name field focused | `↵ launch · Esc cancel` |
| Directory picker open | `↑↓ navigate · ↵ select · Esc close` |

## Keyboard Flow

- Panel opens → cursor in prompt
- Type prompt → Enter → submits with defaults (auto name, last used directory)
- Type prompt → Tab → name field slides in → edit name → Enter → submits
- Click "in [project]" row → dropdown opens → arrow keys → Enter selects → dropdown closes
- Esc at any point → dismisses panel (or closes dropdown first if open)

## Post-Submit Behavior

1. Panel dismisses immediately
2. Notch auto-expands with `.sessionCreated` reason
3. Content type set to `.instances` (session list)
4. Provisional session appears with launching progress
5. After hook merge, chat view opens automatically for the new session

## Modified Files

- `ClaudeIsland/UI/Views/SessionLauncherView.swift` — full rewrite of the view body
- `ClaudeIsland/UI/Views/DirectoryPickerView.swift` — refactor to render as dropdown overlay instead of inline list

## What Does NOT Change

- `SessionLauncherPanel.swift` — NSPanel setup, dismiss behavior, handleSubmit (unchanged)
- `TmuxSessionCreator.swift` — launch orchestration (unchanged)
- `ProjectStore.swift` — data layer (unchanged)
- `NewSessionRow.swift` — entry point (unchanged)

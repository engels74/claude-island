# Chat View Redesign

## Goal

Replace the current sparse chat view with a dual-mode interface: a dense **Terminal mode** that shows tool calls inline with full content visible by default (like Warp), and a clean **Chat mode** with iMessage-style bubbles where tool calls are compact one-line summaries. Users switch between modes via a segmented control in the header bar.

## Problems with Current Design

- Tool calls render as collapsed rows requiring manual expansion to see content
- Large empty space above content makes the view feel sparse
- No visual hierarchy distinguishes assistant text from tool activity
- Formatting is inconsistent across tool types
- Context is lost because you can't see what happened without clicking into each tool call
- No alternative for users who prefer a cleaner conversational view

## Architecture

The chat view gains a `ChatViewMode` enum (`.terminal`, `.chat`) stored per-session in `AppSettings`. The existing `ChatView` becomes a shell that routes to either `TerminalModeView` or `ChatModeView` based on the selected mode. Both modes consume the same `[ChatHistoryItem]` data from `ChatHistoryManager`.

The header bar adds a segmented control (`Terminal | Chat`) that toggles the mode. The input area at the bottom stays identical in both modes.

Existing components (`MarkdownRenderer`, `ToolResultViews`, autoscroll logic, message sending) are reused. The main change is how `MessageItemView` dispatches rendering per mode.

## Design Decisions

### Header

- Segmented control in the header bar: `Terminal | Chat`
- Positioned center-right, between the session title and action buttons
- Selected mode persists per-session via `AppSettings`
- Default mode: Terminal (the power-user view)

### Terminal Mode

Terminal mode is dense and information-rich. Everything flows top-to-bottom like scrolling through the actual CLI session.

**User messages:** Rendered with a blue "You" label above the message text. Monospaced font throughout.

**Assistant text:** Rendered with a purple "Claude" label. Markdown rendered inline (code blocks, links, emphasis all work). Monospaced font.

**Thinking blocks:** Collapsed inline as a single row with a dim "Thinking..." label, left-bordered with a subtle gray line. Click/tap to expand full thinking text. Always present (not hidden), but visually recessive.

**Tool calls:** Minimal inline rendering. Each tool gets:
- A status dot (6px): white pulsing = running, orange pulsing = approval needed, green = success, red = error
- Tool name in dim gray monospace
- A middle dot separator
- File path / command in blue
- Optional status text right-aligned (line count, exit code, "Running...", etc.)

**Tool content:** Shown by default directly below the status line, indented 12px left. No expanding needed for normal-length results.
- **Edit:** Unified diff with red (removed) / green (added) lines on dark background
- **Read:** File content with line numbers. Height-capped at ~6-8 visible lines with gradient fade and "Show all N lines" link
- **Bash:** Command output. Height-capped for long output. Exit code shown in status line
- **Grep/Glob:** File list or match count. Height-capped if many results
- **Write:** File path and creation confirmation
- **Bash with no output:** Status line only, no content block
- **Task (subagent):** Nested tool list (existing behavior)

**Long content handling:** Height cap with gradient fade. A "Show all N lines" / "Show full output" link at the bottom of the fade. Click to expand inline. The cap applies to Read results, Bash output, Grep results, and any other tool with more than ~8 lines of output.

**Approval requests:** Highlighted with an orange-tinted background, subtle orange border. The tool status line uses orange coloring. Allow/Deny buttons rendered inline below the tool info. Stands out from the flow without being jarring.

**Error results:** Red status dot, red tool name, error output in a red-tinted code block with subtle red border.

### Chat Mode

Chat mode is clean and conversational, like iMessage or ChatGPT.

**User messages:** Right-aligned blue bubbles with rounded corners (16px radius, 4px bottom-right). White text.

**Assistant messages:** Left-aligned with a purple "C" avatar circle (24px). Gray bubble background. Markdown rendered with system font (not monospace). Full inline code, links, emphasis support.

**Tool calls in Chat mode:** Collapsed into compact one-line summaries within the assistant bubble, separated by a thin divider above. Each tool shows:
- A small status dot (5px)
- One-line summary: "Edited ConversationParser.swift (3 locations)", "Build succeeded", "Committed: fix: filter..."
- No expand capability in Chat mode (switch to Terminal mode for details)

**Thinking blocks:** Same as Terminal mode - collapsed inline with expand.

### Input Area

Identical in both modes. No changes from current implementation. Text field with send button.

### Status Colors (Both Modes)

| Status | Color | Animation |
|--------|-------|-----------|
| Running | White | Pulsing glow |
| Waiting for approval | Orange (#d29922) | Pulsing glow |
| Success | Green (#3fb950) | Static |
| Error | Red (#f85149) | Static |
| Interrupted | Red (#f85149) | Static |

## File Structure

### New Files

- `ClaudeIsland/UI/Views/TerminalModeView.swift` - Terminal mode message rendering (user messages, assistant text, tool calls inline with content)
- `ClaudeIsland/UI/Views/ChatModeView.swift` - Chat mode message rendering (bubbles, compact tool summaries)
- `ClaudeIsland/UI/Components/ToolCallInlineView.swift` - Terminal mode tool call component (status dot + name + file + content block)
- `ClaudeIsland/UI/Components/ToolCallSummaryView.swift` - Chat mode compact tool summary (one-line with dot)
- `ClaudeIsland/UI/Components/CollapsibleContentView.swift` - Height-capped content with gradient fade and "Show all" link
- `ClaudeIsland/UI/Components/ThinkingBlockView.swift` - Collapsed thinking block with expand

### Modified Files

- `ClaudeIsland/UI/Views/ChatView.swift` - Refactor to shell that routes to Terminal/Chat mode views. Extract shared logic (autoscroll, input area, message loading). Add segmented control to header.
- `ClaudeIsland/Core/Settings.swift` - Add `chatViewMode` setting (default: `.terminal`)
- `ClaudeIsland/Models/ChatViewMode.swift` - New enum: `.terminal`, `.chat`

### Unchanged Files

- `ClaudeIsland/UI/Components/MarkdownRenderer.swift` - Reused as-is in both modes
- `ClaudeIsland/UI/Views/ToolResultViews.swift` - Reused for expanded tool content in Terminal mode
- `ClaudeIsland/Services/Chat/ChatHistoryManager.swift` - No changes, data layer stays the same
- `ClaudeIsland/Services/Session/ConversationParser.swift` - No changes

## Scope Boundaries

**In scope:**
- Dual-mode view with segmented toggle
- Terminal mode: inline tool rendering with content visible by default
- Chat mode: bubble UI with compact tool summaries
- Height-capped content with gradient fade
- Collapsed thinking blocks
- Status color system (already exists, just applied consistently)
- Per-session mode preference

**Out of scope:**
- Syntax highlighting in code blocks (existing MarkdownRenderer handles this)
- Changes to the JSONL format or ConversationParser
- Changes to the approval flow logic (just visual treatment)
- New tool result types
- Search within chat history
- Message timestamps (Chat mode only shows them conceptually, not adding timestamp parsing)

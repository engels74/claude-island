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

The chat view gains a `ChatViewMode` enum (`.terminal`, `.chat`) added to `Settings.swift` alongside other simple enums. The mode is stored globally in `AppSettings` (not per-session) since users tend to prefer one mode consistently. The existing `ChatView` becomes a shell that routes to either `TerminalModeView` or `ChatModeView` based on the selected mode. Both modes consume the same `[ChatHistoryItem]` data from `ChatHistoryManager`.

The header bar adds a segmented control (`Terminal | Chat`) that toggles the mode. The input area at the bottom stays identical in both modes.

**Shared logic extraction:** The current `ChatView` has ~300 lines of non-rendering logic (autoscroll via inverted `scaleEffect(y: -1)` scroll, pause/resume scroll tracking, keyboard monitoring for Cmd+V paste, session state observation, history loading/caching, focus management, tmux target resolution). All of this stays in the `ChatView` shell. The mode views (`TerminalModeView` / `ChatModeView`) receive `[ChatHistoryItem]` as input and only handle rendering. They do not manage scroll, loading, or input.

Existing components (`MarkdownRenderer`, `ToolResultViews`, autoscroll logic, message sending) are reused. `MarkdownRenderer` gains an optional `useSystemFont` parameter for Chat mode (defaults to false, preserving current monospace behavior).

## Design Decisions

### Header

- Segmented control in the header bar: `Terminal | Chat`
- Positioned center-right, after the session title
- Selected mode persists globally via `AppSettings.chatViewMode`
- Default mode: Terminal (the power-user view)

### Terminal Mode

Terminal mode is dense and information-rich. Everything flows top-to-bottom like scrolling through the actual CLI session. All text uses monospace font (SF Mono / Menlo), including markdown-rendered assistant text. Code blocks, links, and emphasis all render in monospace variants (bold monospace, italic monospace, etc.).

**User messages:** Rendered with a blue "You" label above the message text.

**Assistant text:** Rendered with a purple "Claude" label. Markdown rendered inline using `MarkdownText` with monospace font.

**Thinking blocks:** Collapsed inline as a single row with a dim "Thinking..." label, left-bordered with a subtle gray line (2px, `rgba(255,255,255,0.08)`). Click/tap to expand full thinking text. Always present (not hidden), but visually recessive.

**Processing indicator:** The existing `ProcessingIndicatorView` ("Working...") renders inline at the end of the message list, same position as current. Shown when the session is in `.processing` phase.

**Interrupted messages:** Rendered as a red "Interrupted" label inline, matching the existing `InterruptedMessageView` behavior.

**Tool calls:** Minimal inline rendering. Each tool gets:
- A status dot (6px): white pulsing = running, orange pulsing = approval needed, green = success, red = error
- Tool name in dim gray monospace
- A middle dot separator (U+00B7 `·`)
- File path / command in blue (`#58a6ff`)
- Optional status text right-aligned (line count, exit code, "Running...", etc.)

**Tool content:** Shown by default directly below the status line, indented 12px left. No click-to-expand needed for normal-length results. Content is always visible (unlike current collapsed behavior). For long content, a height cap with gradient fade is applied (see below).

Tool-specific rendering:
- **Edit:** Unified diff with red (removed) / green (added) lines on dark background (`#161b22`)
- **Read:** File content with line numbers. Height-capped.
- **Write:** File path and creation confirmation
- **Bash:** Command output. Exit code pulled from `tool.structuredResult` (`BashResult.returnCodeInterpretation` or `BashOutputResult.exitCode`). Height-capped for long output.
- **Grep/Glob:** File list or match count. Height-capped if many results.
- **Task (subagent):** Nested tool list (existing `SubagentToolsList` behavior)
- **WebFetch/WebSearch:** URL/query in status line, response content height-capped
- **MCP tools:** Formatted via `MCPToolFormatter.formatToolName()` for display name. Content rendered as generic text, height-capped.
- **AskUserQuestion, KillShell, ExitPlanMode, TodoWrite:** Status line only with tool name and result summary. No content block unless result has meaningful output.
- **Bash with no output:** Status line only, no content block
- **All other/Generic tools:** Status line with tool name + input preview. Result as plain text, height-capped.

**Long content handling:** Height cap at 120px (~8 lines at 10px monospace font size). Gradient fade from transparent to the code block background color. A "Show all N lines" / "Show full output" link centered at the bottom of the fade. Click to expand inline (removes cap, shows full content). The cap applies to Read results, Bash output, Grep results, WebFetch content, and any other tool result exceeding the cap.

**Approval requests:** Highlighted with an orange-tinted background (`rgba(210,153,34,0.06)`), subtle orange border (`rgba(210,153,34,0.15)`). The tool status line uses orange coloring. Allow/Deny buttons rendered inline below the tool info. Stands out from the flow without being jarring.

**Error results:** Red status dot, red tool name, error output in a red-tinted code block with subtle red border.

### Chat Mode

Chat mode is clean and conversational, like iMessage or ChatGPT.

**User messages:** Right-aligned blue bubbles (`#2563eb`) with rounded corners (16px radius, 4px bottom-right). White text.

**Assistant messages:** Left-aligned with a purple "C" avatar circle (24px, `#7c3aed`). Gray bubble background (`rgba(255,255,255,0.04)`). Markdown rendered with system font via `MarkdownText(useSystemFont: true)`. Full inline code, links, emphasis support.

**Tool calls in Chat mode:** Collapsed into compact one-line summaries within the assistant bubble, separated by a thin divider above. Each tool shows:
- A small status dot (5px)
- One-line summary using existing `ToolStatusDisplay.completed(for:result:)` text
- No expand capability for tool results in Chat mode (switch to Terminal mode for details)

**Approval requests in Chat mode:** The tool summary line shows the orange status dot and "Waiting for approval" text. The existing approval bar at the bottom of the chat view handles Allow/Deny interaction (no inline buttons in Chat mode).

**Thinking blocks:** Same as Terminal mode - collapsed inline with expand. This is the one exception to "no expand in Chat mode" because thinking text is conversational context, not tool output.

**Processing indicator:** Same as Terminal mode - shown inline at the end.

**Interrupted messages:** Red "Interrupted" text within the assistant bubble.

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

Note: Subagent tool rows within Task tools use the same color scheme (not orange for running, which was an inconsistency in the previous implementation).

## File Structure

### New Files

- `ClaudeIsland/UI/Views/TerminalModeView.swift` - Terminal mode message rendering (user messages, assistant text, tool calls inline with content)
- `ClaudeIsland/UI/Views/ChatModeView.swift` - Chat mode message rendering (bubbles, compact tool summaries)
- `ClaudeIsland/UI/Components/ToolCallInlineView.swift` - Terminal mode tool call component (status dot + name + file + content block)
- `ClaudeIsland/UI/Components/ToolCallSummaryView.swift` - Chat mode compact tool summary (one-line with dot)
- `ClaudeIsland/UI/Components/CollapsibleContentView.swift` - Height-capped content with gradient fade and "Show all" link. Must work correctly inside the inverted scroll context (`scaleEffect(y: -1)`).
- `ClaudeIsland/UI/Components/ThinkingBlockView.swift` - Collapsed thinking block with expand

### Modified Files

- `ClaudeIsland/UI/Views/ChatView.swift` - Refactor to shell that routes to Terminal/Chat mode views. Shared logic stays here: autoscroll (inverted scroll pattern), keyboard monitoring, history loading, focus management, session observation, input area. Mode views are called from within the existing scroll context.
- `ClaudeIsland/Core/Settings.swift` - Add `ChatViewMode` enum (`.terminal`, `.chat`) and `chatViewMode` key (default: `.terminal`)
- `ClaudeIsland/UI/Components/MarkdownRenderer.swift` - Add `useSystemFont: Bool = false` parameter to `MarkdownText`. When true, body text uses system font (SF Pro) instead of monospace. Code blocks remain monospace regardless.

### Unchanged Files

- `ClaudeIsland/UI/Views/ToolResultViews.swift` - Reused for expanded tool content in Terminal mode
- `ClaudeIsland/Services/Chat/ChatHistoryManager.swift` - No changes, data layer stays the same
- `ClaudeIsland/Services/Session/ConversationParser.swift` - No changes

## Scope Boundaries

**In scope:**
- Dual-mode view with segmented toggle
- Terminal mode: inline tool rendering with content visible by default
- Chat mode: bubble UI with compact tool summaries
- Height-capped content with gradient fade (120px cap)
- Collapsed thinking blocks
- Status color system (already exists, applied consistently across all tool types including subagent rows)
- Global mode preference in AppSettings
- `MarkdownRenderer` system font option for Chat mode
- All tool types rendered (explicit rules for common tools, generic fallback for others)

**Out of scope:**
- Syntax highlighting in code blocks (existing MarkdownRenderer handles this)
- Changes to the JSONL format or ConversationParser
- Changes to the approval flow logic (just visual treatment)
- New tool result types
- Search within chat history
- Message timestamps
- Image message rendering (paste-to-send works via existing input area, image display in history is a separate feature)

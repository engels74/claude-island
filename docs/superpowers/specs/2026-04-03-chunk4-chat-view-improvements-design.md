# Chunk 4: Chat View Improvements

Configurable notch panel width and richer markdown rendering in the chat view.

## Overview

Improves the chat experience by allowing users to widen the expanded notch panel and enhancing markdown rendering with task lists, improved code blocks, and table support.

## Dependencies

None. Can be built in parallel with any other chunk.

## Configurable Panel Width

### Setting

- New row in `NotchMenuView`: resize icon + "Panel Width" label
- Positioned after "Notch Layout" row (line ~72) and before the first Divider (line ~75) in the display settings section
- Expands to show a slider (no existing slider precedent in NotchMenuView -- first one in the codebase, may need custom styling to match dark aesthetic, use `.buttonStyle(.plain)` equivalent)
- Range: 50% to 80% of screen width (see "Width Value" section below)
- Continuous slider (not stepped)
- Stored as a `Double` in `UserDefaults` (no native `CGFloat` getter in UserDefaults)

### Width Value Semantics

The current chat panel width is hardcoded as `min(screenRect.width * 0.5, 600)` in `NotchViewModel.openedSize` (line ~119). The new setting replaces the `0.5` multiplier:

- **Setting name**: `chatPanelWidthFraction` (fraction of screen width, NOT a percentage or multiplier on current)
- **Default**: `0.5` (matches current behavior)
- **Range**: `0.5` (current) to `0.8` (80% of screen width)
- **Max cap**: remove the `600` cap when fraction > 0.5, or increase it proportionally. At 0.8 on a 1440px screen, the width would be 1152px.
- **Formula**: `width = min(screenRect.width * chatPanelWidthFraction, screenRect.width * 0.8)`

### Implementation -- Where Width Changes

**NOT in `NotchGeometry`**. `NotchGeometry` is a pure `Sendable` struct with `let` properties -- it cannot read mutable settings. Its `openedScreenRect(for:)` method takes a `CGSize` parameter and positions it on screen. It should remain a pure geometry calculator.

**The change goes in `NotchViewModel.openedSize`** (line ~111-135). The `.chat` case currently returns:
```swift
case .chat:
    return CGSize(width: min(self.screenRect.width * 0.5, 600), height: 580)
```

Replace `0.5` with the stored fraction. Since `openedSize` is a computed property on an `@Observable` class, views that read it will re-render automatically.

**Reactivity bridge**: `AppSettings` uses raw `UserDefaults`, which is NOT `@Observable`. `NotchViewModel` won't know the setting changed. Solution:
- Add a stored `var chatPanelWidthFraction: Double = 0.5` property on `NotchViewModel` (an `@Observable` class, so changes trigger re-renders)
- The slider in `NotchMenuView` writes to BOTH `NotchViewModel.chatPanelWidthFraction` AND `AppSettings.chatPanelWidthFraction` (for persistence)
- On app launch, `NotchViewModel` loads the initial value from `AppSettings`
- This follows the same approach used for `selectorUpdateToken` -- a stored `@Observable` property drives `openedSize` recomputation

**Hit testing**: `NotchViewController` (line ~61) adds 52px to `openedSize.width` for hit-test area. This reads `openedSize` via a closure, so it automatically picks up width changes. No manual update needed.

### Live Preview Limitation

The slider lives in `NotchMenuView`, shown when `contentType == .menu`. The width setting only affects `.chat` content type. **Live preview of the chat panel while adjusting the slider is not possible** in the current architecture (the user is looking at the menu, not the chat).

Options:
- **A.** Drop the live preview claim. The user adjusts the slider, goes back to a chat, sees the result. Simple and honest.
- **B.** Show a preview indicator (a horizontal line or ghost outline at the slider's current width) overlaid on the menu to hint at the resulting width.
- **C.** Apply the width to ALL content types (menu, instances, chat) so the entire notch panel gets wider. This is simpler but changes the instances view too.

Recommend **A** for the initial implementation -- keep it simple. The user adjusts and sees the change next time they open a chat.

### Message Readability at Wide Widths

At very wide widths (1000px+), text lines become long and hard to read. Add a `maxWidth` constraint on message text content:
- `AssistantMessageView` and `UserMessageView` text blocks capped at ~700px
- Code blocks and tables are NOT capped (they benefit from full width)
- This preserves readability while still giving code/tables more room

### Edge Cases

- Screen changes (external monitor, resolution): fraction-based scales automatically
- Minimum: 0.5 (current default, can't go narrower)
- Maximum: 0.8 of screen width
- Collapsed notch pill stays the same size regardless
- The window (`NotchPanel`) is already full-screen width; only content width changes

## Markdown Renderer Enhancements

`MarkdownRenderer.swift` (282 lines) wraps Apple's `swift-markdown` (version 0.5.0+). Current parsing options (line 25): `[.parseBlockDirectives, .parseSymbolLinks]`.

**Confirmed by codebase audit**: `ToolResultViews.swift` does NOT use `MarkdownRenderer` -- it has its own rendering. Changes to `MarkdownRenderer` spacing/styling have zero cross-contamination risk.

### Task Lists

swift-markdown already parses task lists -- `ListItem` has a `.checkbox` property (type `Checkbox?`: `.checked` or `.unchecked`). No parsing option change needed. The current `unorderedListView` (lines 148-169) iterates `list.listItems` but never inspects `item.checkbox`.

**Implementation**:
- In `unorderedListView`, check `item.checkbox` before rendering the bullet
- If `.unchecked`: render an empty square icon (SF Symbol `square`) instead of `circle.fill` bullet
- If `.checked`: render a checked square icon (SF Symbol `checkmark.square.fill`) with green tint
- If `nil`: render normal bullet (current behavior)
- Checkbox aligned with existing bullet indentation
- Read-only (no tap handler)

Note: The spec previously said "Add `ListItemCheckbox` handling in `BlockRenderer`" -- there is no `ListItemCheckbox` type in swift-markdown. The correct API is the `ListItem.checkbox` property, checked inside the existing `unorderedListView` method.

### Code Blocks

Current `CodeBlockView` (lines 267-281): monospace text, horizontal scroll (already exists!), `Color.white.opacity(0.08)` background, 6pt corner radius, no language label, no copy button.

The `BlockRenderer` at line 103 passes `codeBlock.code` but discards `codeBlock.language` (which swift-markdown provides as `String?`).

**Implementation**:
- Change `CodeBlockView` signature to accept `language: String?` parameter
- Pass `codeBlock.language` from `BlockRenderer` line 103
- Add a `VStack(spacing: 0)` wrapper:
  - **Header bar** (only when language is non-nil): `HStack` with language label (left, gray small text) + copy button (right, SF Symbol `doc.on.doc`)
  - Header background: `Color.white.opacity(0.12)` (slightly lighter than code area)
  - **Code area**: existing `ScrollView(.horizontal)` with monospaced text (already has horizontal scroll)
- Copy button: `NSPasteboard.general.clearContents()` + `.setString(code, forType: .string)`, with 1.5s visual feedback (icon changes to `checkmark`, reverts via `@State` + timer)
- Consider extracting a reusable `CopyButton` component since Chunk 3 also needs clipboard functionality

### Tables

**Requires adding `.parseTable` to parsing options** at line 25. Without this, swift-markdown will NOT produce `Table` nodes. Current options: `[.parseBlockDirectives, .parseSymbolLinks]`. Change to: `[.parseBlockDirectives, .parseSymbolLinks, .parseTable]`.

swift-markdown table types: `Table`, `Table.Head`, `Table.Body`, `Table.Row`, `Table.Cell`. No existing grid/table rendering in the codebase.

**Implementation**:
- Add `Table` case to `BlockRenderer` (line ~114, currently falls through to `EmptyView()`)
- Use SwiftUI `Grid` (macOS 13+, which is satisfied since the app targets macOS 15.6+)
- Wrap `Grid` in `ScrollView(.horizontal)` for wide tables
- Use `.fixedSize()` on the `Grid` inside the horizontal scroll to prevent column collapse
- Walk the tree: `Table.Head` -> rows -> cells, `Table.Body` -> rows -> cells
- Each cell's content is inline markup -- render with `InlineRenderer`
- Header row: `.bold()` + slightly darker background (`Color.white.opacity(0.12)`)
- Alternating body rows: `Color.white.opacity(0.04)` on even rows
- Cell padding: ~6px vertical, ~10px horizontal
- Subtle borders: `Color.white.opacity(0.15)` between cells

### Text Density

Current spacing values (from codebase audit):
- Paragraph line spacing: `.lineSpacing(4)` (line 98)
- Top-level block spacing: `VStack(spacing: 12)` (line 67)
- List item spacing: `spacing: 4` (lines 149, 157, 172, 180)
- Message list spacing: `LazyVStack(spacing: 16)` (ChatView.swift line 337)

**Recommended reductions**:
- Block spacing: `12` -> `8` (biggest visual win)
- Line spacing: `4` -> `2` (still readable at font size 13)
- Message list spacing: `16` -> `12` (tighter but still clear turn separation)
- List item spacing: keep at `4` (already compact)

These are safe reductions. Avoid going tighter without user testing.

### What NOT to Change

- Overall chat message bubble structure
- Input bar at bottom
- Header/back navigation
- Tool result rendering (`ToolResultViews.swift` -- completely separate rendering path, does not use `MarkdownRenderer`)

## New Files

None. All changes are modifications to existing files.

## Modified Files

- `NotchMenuView.swift` -- Add Panel Width expandable row with slider (after "Notch Layout", before divider). First slider control in the codebase -- may need custom styling for dark theme.
- `NotchViewModel.swift` -- Add stored `chatPanelWidthFraction: Double` property (loaded from `AppSettings` on init), update `.chat` case in `openedSize` to use it instead of hardcoded `0.5`. Also applies to `.instances` content type if option C is chosen.
- `MarkdownRenderer.swift` -- Check `ListItem.checkbox` in `unorderedListView` for task list rendering; pass `codeBlock.language` to `CodeBlockView`; add language label header + copy button to `CodeBlockView`; add `Table` case to `BlockRenderer` using SwiftUI `Grid`; add `.parseTable` to document parsing options (line 25); reduce `VStack` spacing from `12` to `8`, `lineSpacing` from `4` to `2`
- `ChatView.swift` -- Reduce `LazyVStack(spacing:)` from `16` to `12`; add `maxWidth(700)` on message text content (not code blocks/tables) for readability at wide widths
- `Settings.swift` -- Add `chatPanelWidthFraction` key (Double, default 0.5) to private `Keys` enum + static computed property. **Important**: `UserDefaults.double(forKey:)` returns `0.0` for unset keys. The getter must guard: `let v = defaults.double(forKey: key); return v > 0 ? v : 0.5`. Without this, a fresh install gets a zero-width panel.

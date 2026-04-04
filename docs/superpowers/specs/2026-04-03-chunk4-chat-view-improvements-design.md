# Chunk 4: Chat View Improvements

Configurable notch panel width and richer markdown rendering in the chat view.

## Overview

Improves the chat experience by allowing users to widen the expanded notch panel and enhancing markdown rendering with task lists, improved code blocks, and table support.

## Dependencies

None. Can be built in parallel with any other chunk.

## Configurable Panel Width

### Setting

- New row in `NotchMenuView`: resize icon + "Panel Width" label
- Expands to show a slider
- Range: current default width (100%) up to 80% of screen width
- Continuous slider (not stepped)
- Live preview: panel resizes in real-time as slider is dragged
- Stored in `AppSettings` as percentage of screen width

### Implementation in NotchWindowController

- `NotchGeometry.openedScreenRect(for:)` is the key method -- currently calculates the expanded panel frame. Update it to read `AppSettings.panelWidthPercentage` and apply as multiplier to screen width
- `NotchViewModel.openedSize` derives from geometry -- will automatically reflect the new width
- Collapsed notch pill stays the same size regardless of setting
- Only the expanded content area width changes
- Animation: notch animates to configured width on expand (existing expand animation handles this)

### Edge Cases

- Screen changes (external monitor, resolution): percentage-based scales automatically
- Minimum width: the current hardcoded expanded width (baseline 100%) -- can't go narrower than today
- Maximum: 80% of screen width (prevents full-screen appearance)
- The window itself (`NotchPanel`) is already full-screen width -- the expanded content is centered within it. This architecture doesn't change; only the content width calculation changes.

## Markdown Renderer Enhancements

Current `MarkdownRenderer` wraps Apple's `swift-markdown` parser. Handles paragraphs, bold, italic, lists, links, headings, code spans. The following are missing and need to be added.

### Task Lists

- `- [ ]` renders as unchecked checkbox icon + text
- `- [x]` renders as checked checkbox icon (green checkmark or filled box) + text
- Read-only (clicking does nothing -- reflecting Claude's output)
- Checkbox aligned with bullet points in regular lists
- Nested task lists supported (indentation follows existing nested list behavior)

### Code Blocks

Current: monospace text on dark background. Enhanced:

- Language label in top-right corner (gray, small text) when language specified
- Copy button in top-right corner (copies code to clipboard)
- Slightly different background shade to distinguish from surrounding text
- Horizontal scroll for long lines (no wrapping)
- No syntax highlighting -- adds significant complexity (third-party dependency or custom tokenizer) for marginal value at these widths. Can revisit later.

### Tables

- Render as grid with subtle borders
- Header row: bold text, slightly darker background
- Alternating row shading (very subtle, ~5% opacity difference)
- Horizontal scroll if table wider than panel
- Cell padding: ~6px vertical, ~10px horizontal

### Text Density

- Reduce line spacing slightly (current rendering feels loose)
- Tighter paragraph margins
- Benefits from wider panel setting -- more horizontal space means less vertical scrolling

### What NOT to Change

- Overall chat message bubble structure
- Input bar at bottom
- Header/back navigation
- Tool result rendering (separate views, out of scope)

## New Files

None anticipated. All changes are modifications to existing files.

## Modified Files

- `NotchMenuView.swift` -- Add Panel Width settings section (slider row, after existing display settings)
- `NotchGeometry.swift` -- Update `openedScreenRect(for:)` to apply width percentage from settings
- `NotchViewModel.swift` -- `openedSize` will reflect new geometry automatically; may need to trigger re-render on setting change
- `MarkdownRenderer.swift` -- Add `ListItemCheckbox` handling in `BlockRenderer` for task lists; enhance `CodeBlockView` with language label + copy button + horizontal scroll; add `Table`/`TableHead`/`TableBody`/`TableRow`/`TableCell` rendering; adjust spacing constants
- `AppSettings.swift` -- Add `panelWidthPercentage` (CGFloat, default 1.0, range 1.0-0.8 of screen) following existing pattern: private `Keys` enum + computed property

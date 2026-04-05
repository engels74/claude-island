# Chat View Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the monolithic ChatView with a dual-mode interface (Terminal/Chat) using a segmented toggle, where Terminal mode shows tool calls inline with content visible by default and Chat mode uses iMessage-style bubbles with compact tool summaries.

**Architecture:** ChatView.swift (1467 lines) is refactored into a shell that manages autoscroll, input, history loading, and keyboard monitoring, routing rendering to either TerminalModeView or ChatModeView. New reusable components (CollapsibleContentView, ThinkingBlockView, ToolCallInlineView, ToolCallSummaryView) are created. MarkdownRenderer gains a `useSystemFont` parameter for Chat mode.

**Tech Stack:** Swift 6.2, SwiftUI, AppKit (NSEvent monitors), swift-markdown

---

### Task 1: Add ChatViewMode enum and AppSettings key

**Goal:** Add the `ChatViewMode` enum and settings key so both modes can be persisted.

**Files:**
- Modify: `ClaudeIsland/Core/Settings.swift`

**Acceptance Criteria:**
- [ ] `ChatViewMode` enum with `.terminal` and `.chat` cases exists in Settings.swift
- [ ] `AppSettings.chatViewMode` reads/writes the mode to UserDefaults
- [ ] Default value is `.terminal`

**Verify:** `xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -5` → BUILD SUCCEEDED

**Steps:**

- [ ] **Step 1: Add ChatViewMode enum to Settings.swift**

Add this after the `SessionActionType` enum (around line 119):

```swift
// MARK: - ChatViewMode

enum ChatViewMode: String, CaseIterable {
    case terminal = "Terminal"
    case chat = "Chat"
}
```

- [ ] **Step 2: Add chatViewMode property to AppSettings**

Add this after the `sessionActionOrder` property (before the Keys enum):

```swift
// MARK: - Chat View Mode

static var chatViewMode: ChatViewMode {
    get {
        guard let rawValue = defaults.string(forKey: Keys.chatViewMode),
              let mode = ChatViewMode(rawValue: rawValue)
        else {
            return .terminal
        }
        return mode
    }
    set {
        defaults.set(newValue.rawValue, forKey: Keys.chatViewMode)
    }
}
```

- [ ] **Step 3: Add the key to the Keys enum**

Add inside `private enum Keys`:

```swift
static let chatViewMode = "chatViewMode"
```

- [ ] **Step 4: Build and verify**

```bash
xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -5
```

- [ ] **Step 5: Commit**

```bash
git add ClaudeIsland/Core/Settings.swift
git commit -m "feat: add ChatViewMode enum and AppSettings key"
```

---

### Task 2: Add useSystemFont parameter to MarkdownRenderer

**Goal:** Allow MarkdownText to render with system font (SF Pro) instead of monospace for Chat mode.

**Files:**
- Modify: `ClaudeIsland/UI/Components/MarkdownRenderer.swift`

**Acceptance Criteria:**
- [ ] `MarkdownText` accepts a `useSystemFont: Bool = false` parameter
- [ ] When `useSystemFont` is true, body text uses `.system(size:)` instead of `.system(size:design:.monospaced)`
- [ ] Code blocks always remain monospace regardless of `useSystemFont`
- [ ] Existing call sites are unaffected (parameter defaults to false)

**Verify:** `xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -5` → BUILD SUCCEEDED

**Steps:**

- [ ] **Step 1: Add useSystemFont parameter to MarkdownText init**

In `MarkdownRenderer.swift`, modify the `MarkdownText` struct. Change the init from:

```swift
init(_ text: String, color: Color = .white.opacity(0.9), fontSize: CGFloat = 13) {
    self.text = text
    self.baseColor = color
    self.fontSize = fontSize
    self.document = DocumentCache.shared.document(for: text)
}
```

To:

```swift
init(_ text: String, color: Color = .white.opacity(0.9), fontSize: CGFloat = 13, useSystemFont: Bool = false) {
    self.text = text
    self.baseColor = color
    self.fontSize = fontSize
    self.useSystemFont = useSystemFont
    self.document = DocumentCache.shared.document(for: text)
}
```

Add the property:

```swift
let useSystemFont: Bool
```

- [ ] **Step 2: Pass useSystemFont through to BlockRenderer and InlineRenderer**

Add `useSystemFont: Bool` parameter to `BlockRenderer` init and pass it through wherever `InlineRenderer` or `BlockRenderer` is constructed recursively.

In `BlockRenderer`, add `let useSystemFont: Bool` property and pass it through to every `InlineRenderer(...)` and recursive `BlockRenderer(...)` call.

In `InlineRenderer`, add `let useSystemFont: Bool` property. When `useSystemFont` is true, use `.system(size: fontSize)` for text instead of the default. The `InlineCode` case should always use `.system(size:design:.monospaced)` regardless.

In `MarkdownText.body`, pass `useSystemFont` when creating `BlockRenderer`:

```swift
BlockRenderer(markup: child, baseColor: self.baseColor, fontSize: self.fontSize, useSystemFont: self.useSystemFont)
```

Note: `CodeBlockView` already uses monospace explicitly, so no changes needed there.

- [ ] **Step 3: Build and verify**

```bash
xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -5
```

- [ ] **Step 4: Commit**

```bash
git add ClaudeIsland/UI/Components/MarkdownRenderer.swift
git commit -m "feat: add useSystemFont parameter to MarkdownText"
```

---

### Task 3: Create CollapsibleContentView component

**Goal:** Build a reusable height-capped content view with gradient fade and "Show all" expand link.

**Files:**
- Create: `ClaudeIsland/UI/Components/CollapsibleContentView.swift`

**Acceptance Criteria:**
- [ ] `CollapsibleContentView` caps content at 120px with a gradient fade
- [ ] Shows "Show all N lines" / "Show full output" link at bottom of fade
- [ ] Click expands inline to show full content
- [ ] Works correctly inside inverted scroll context (`scaleEffect(y: -1)`)
- [ ] Gradient fades to a configurable background color (default `#161b22`)

**Verify:** `xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -5` → BUILD SUCCEEDED

**Steps:**

- [ ] **Step 1: Create CollapsibleContentView.swift**

Create `ClaudeIsland/UI/Components/CollapsibleContentView.swift`:

```swift
//
//  CollapsibleContentView.swift
//  ClaudeIsland
//
//  Height-capped content with gradient fade and expand link
//

import SwiftUI

struct CollapsibleContentView<Content: View>: View {
    // MARK: Lifecycle

    init(
        lineCount: Int? = nil,
        expandLabel: String? = nil,
        backgroundColor: Color = Color(red: 0.086, green: 0.106, blue: 0.133),
        maxHeight: CGFloat = 120,
        @ViewBuilder content: () -> Content,
    ) {
        self.lineCount = lineCount
        self.expandLabel = expandLabel
        self.backgroundColor = backgroundColor
        self.maxHeight = maxHeight
        self.content = content()
    }

    // MARK: Internal

    var body: some View {
        if self.isExpanded {
            self.content
        } else {
            ZStack(alignment: .bottom) {
                self.content
                    .frame(maxHeight: self.maxHeight, alignment: .top)
                    .clipped()

                // Gradient fade
                LinearGradient(
                    colors: [self.backgroundColor.opacity(0), self.backgroundColor],
                    startPoint: .top,
                    endPoint: .bottom,
                )
                .frame(height: 40)

                // Expand link
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        self.isExpanded = true
                    }
                } label: {
                    Text(self.resolvedLabel)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Color(red: 0.345, green: 0.651, blue: 1.0))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(self.backgroundColor)
                        .cornerRadius(3)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(Color(red: 0.345, green: 0.651, blue: 1.0).opacity(0.2), lineWidth: 1),
                        )
                }
                .buttonStyle(.plain)
                .padding(.bottom, 4)
            }
        }
    }

    // MARK: Private

    @State private var isExpanded = false

    private let lineCount: Int?
    private let expandLabel: String?
    private let backgroundColor: Color
    private let maxHeight: CGFloat
    private let content: Content

    private var resolvedLabel: String {
        if let expandLabel {
            return expandLabel
        }
        if let lineCount {
            return "Show all \(lineCount) lines"
        }
        return "Show full output"
    }
}
```

- [ ] **Step 2: Build and verify**

```bash
xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -5
```

- [ ] **Step 3: Commit**

```bash
git add ClaudeIsland/UI/Components/CollapsibleContentView.swift
git commit -m "feat: add CollapsibleContentView with height cap and gradient fade"
```

---

### Task 4: Create ThinkingBlockView component

**Goal:** Build a collapsed thinking block with expand toggle, reusable in both modes.

**Files:**
- Create: `ClaudeIsland/UI/Components/ThinkingBlockView.swift`

**Acceptance Criteria:**
- [ ] Shows collapsed "Thinking..." label with left border (2px, `rgba(255,255,255,0.08)`)
- [ ] Chevron rotates on expand
- [ ] Full thinking text shown on expand
- [ ] Visually recessive (dim colors, italic)

**Verify:** `xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -5` → BUILD SUCCEEDED

**Steps:**

- [ ] **Step 1: Create ThinkingBlockView.swift**

Create `ClaudeIsland/UI/Components/ThinkingBlockView.swift`:

```swift
//
//  ThinkingBlockView.swift
//  ClaudeIsland
//
//  Collapsed thinking block with expand toggle
//

import SwiftUI

struct ThinkingBlockView: View {
    // MARK: Internal

    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    self.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(.white.opacity(0.2))
                        .rotationEffect(.degrees(self.isExpanded ? 90 : 0))

                    Text("Thinking...")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.25))
                        .italic()

                    Spacer()
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if self.isExpanded {
                Text(self.text)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.3))
                    .italic()
                    .lineSpacing(2)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                    .padding(.leading, 15)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color.white.opacity(0.03))
        .cornerRadius(4)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Private

    @State private var isExpanded = false
}
```

- [ ] **Step 2: Build and verify**

```bash
xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -5
```

- [ ] **Step 3: Commit**

```bash
git add ClaudeIsland/UI/Components/ThinkingBlockView.swift
git commit -m "feat: add ThinkingBlockView with collapsed inline expand"
```

---

### Task 5: Create ToolCallInlineView for Terminal mode

**Goal:** Build the minimal inline tool call component for Terminal mode with status dot, tool name, file path, and content block.

**Files:**
- Create: `ClaudeIsland/UI/Components/ToolCallInlineView.swift`

**Acceptance Criteria:**
- [ ] Shows status dot (6px) with correct color and pulsing animation for running/approval
- [ ] Tool name in dim gray monospace with middle dot separator
- [ ] File path / command in blue (`#58a6ff`)
- [ ] Right-aligned status text (line count, exit code, "Running...")
- [ ] Content shown below status line, indented 12px, using existing `ToolResultContent`
- [ ] Edit tools always show diff (even while running via `EditInputDiffView`)
- [ ] Bash with no output shows status line only
- [ ] Long content wrapped in `CollapsibleContentView`
- [ ] Approval requests highlighted with orange background and inline Allow/Deny buttons
- [ ] Error results use red tinting

**Verify:** `xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -5` → BUILD SUCCEEDED

**Steps:**

- [ ] **Step 1: Create ToolCallInlineView.swift**

Create `ClaudeIsland/UI/Components/ToolCallInlineView.swift`:

```swift
//
//  ToolCallInlineView.swift
//  ClaudeIsland
//
//  Terminal mode inline tool call with status dot, name, content
//

import SwiftUI

// MARK: - ToolCallInlineView

struct ToolCallInlineView: View {
    // MARK: Internal

    let tool: ToolCallItem
    let sessionID: String
    let onApprove: (() -> Void)?
    let onDeny: (() -> Void)?

    var body: some View {
        let isApproval = self.tool.status == .waitingForApproval

        VStack(alignment: .leading, spacing: 4) {
            // Status line
            self.statusLine

            // Approval buttons
            if isApproval, let onApprove, let onDeny {
                HStack(spacing: 8) {
                    Button {
                        onApprove()
                    } label: {
                        Text("Allow")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Color(red: 0.051, green: 0.067, blue: 0.09))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(0.9))
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)

                    Button {
                        onDeny()
                    } label: {
                        Text("Deny")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white.opacity(0.5))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, 12)
            }

            // Content block
            if self.shouldShowContent {
                self.contentBlock
                    .padding(.leading, 12)
            }
        }
        .padding(isApproval ? 8 : 0)
        .padding(.leading, isApproval ? 2 : 0)
        .background(
            isApproval
                ? RoundedRectangle(cornerRadius: 6)
                    .fill(Color(red: 0.824, green: 0.6, blue: 0.133).opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(red: 0.824, green: 0.6, blue: 0.133).opacity(0.15), lineWidth: 1),
                    )
                : nil,
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Private

    @State private var pulseOpacity: Double = 0.6

    private var statusColor: Color {
        switch self.tool.status {
        case .running: .white
        case .waitingForApproval: Color(red: 0.824, green: 0.6, blue: 0.133)
        case .success: Color(red: 0.247, green: 0.725, blue: 0.314)
        case .error, .interrupted: Color(red: 0.973, green: 0.318, blue: 0.286)
        }
    }

    private var isAnimating: Bool {
        self.tool.status == .running || self.tool.status == .waitingForApproval
    }

    private var toolDisplayName: String {
        MCPToolFormatter.formatToolName(self.tool.name)
    }

    private var inputPreview: String {
        self.tool.inputPreview
    }

    private var rightStatusText: String? {
        switch self.tool.status {
        case .running:
            return "Running..."
        case .waitingForApproval:
            return "Waiting for approval"
        default:
            let display = self.tool.statusDisplay
            return display.text.isEmpty ? nil : display.text
        }
    }

    private var shouldShowContent: Bool {
        // Edit always shows diff
        if self.tool.name == "Edit" {
            return true
        }
        // Task shows subagent tools list
        if self.tool.name == "Task" && !self.tool.subagentTools.isEmpty {
            return true
        }
        // Running tools don't show content yet (except Edit)
        if self.tool.status == .running || self.tool.status == .waitingForApproval {
            return false
        }
        // Tools with no result
        let hasResult = self.tool.result != nil || self.tool.structuredResult != nil
        if !hasResult {
            return false
        }
        // Bash with empty output
        if self.tool.name == "Bash" || self.tool.name == "bash" {
            if let result = self.tool.result, result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return false
            }
        }
        return true
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(self.statusColor.opacity(self.isAnimating ? self.pulseOpacity : 0.6))
                .frame(width: 6, height: 6)
                .shadow(color: self.isAnimating ? self.statusColor.opacity(0.5) : .clear, radius: 3)
                .id(self.tool.status)
                .onAppear {
                    if self.isAnimating {
                        withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                            self.pulseOpacity = 0.15
                        }
                    }
                }

            Text(self.toolDisplayName)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(self.tool.status == .error ? Color(red: 0.973, green: 0.318, blue: 0.286) : .white.opacity(0.45))

            Text("\u{00B7}")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.25))

            Text(self.inputPreview)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Color(red: 0.345, green: 0.651, blue: 1.0))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            if let statusText = self.rightStatusText {
                Text(statusText)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(self.tool.status == .error ? Color(red: 0.973, green: 0.318, blue: 0.286).opacity(0.8) : .white.opacity(0.3))
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var contentBlock: some View {
        let isError = self.tool.status == .error

        if self.tool.name == "Task" && !self.tool.subagentTools.isEmpty {
            SubagentToolsList(tools: self.tool.subagentTools)
                .padding(.top, 2)
        } else if self.tool.name == "Edit" && self.tool.status == .running {
            EditInputDiffView(input: self.tool.input)
                .padding(.top, 4)
        } else {
            let lineCount = self.estimateLineCount()
            let needsCap = lineCount > 8

            Group {
                if needsCap {
                    CollapsibleContentView(lineCount: lineCount) {
                        self.resultContent
                    }
                } else {
                    self.resultContent
                }
            }
            .padding(.top, 4)
            .padding(isError ? 4 : 0)
            .background(
                isError
                    ? RoundedRectangle(cornerRadius: 4)
                        .fill(Color(red: 0.973, green: 0.318, blue: 0.286).opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color(red: 0.973, green: 0.318, blue: 0.286).opacity(0.1), lineWidth: 1),
                        )
                    : nil,
            )
        }
    }

    @ViewBuilder
    private var resultContent: some View {
        ToolResultContent(tool: self.tool)
    }

    private func estimateLineCount() -> Int {
        if let result = self.tool.result {
            return result.components(separatedBy: "\n").count
        }
        return 0
    }
}
```

- [ ] **Step 2: Build and verify**

```bash
xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -5
```

- [ ] **Step 3: Commit**

```bash
git add ClaudeIsland/UI/Components/ToolCallInlineView.swift
git commit -m "feat: add ToolCallInlineView for Terminal mode inline rendering"
```

---

### Task 6: Create ToolCallSummaryView for Chat mode

**Goal:** Build the compact one-line tool summary for Chat mode.

**Files:**
- Create: `ClaudeIsland/UI/Components/ToolCallSummaryView.swift`

**Acceptance Criteria:**
- [ ] Shows small status dot (5px) with correct color
- [ ] One-line summary text from `ToolStatusDisplay`
- [ ] No expand capability
- [ ] Orange dot for approval state

**Verify:** `xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -5` → BUILD SUCCEEDED

**Steps:**

- [ ] **Step 1: Create ToolCallSummaryView.swift**

Create `ClaudeIsland/UI/Components/ToolCallSummaryView.swift`:

```swift
//
//  ToolCallSummaryView.swift
//  ClaudeIsland
//
//  Chat mode compact one-line tool summary
//

import SwiftUI

struct ToolCallSummaryView: View {
    // MARK: Internal

    let tool: ToolCallItem

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(self.statusColor.opacity(0.6))
                .frame(width: 5, height: 5)

            Text(self.summaryText)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.35))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    // MARK: Private

    private var statusColor: Color {
        switch self.tool.status {
        case .running: .white
        case .waitingForApproval: Color(red: 0.824, green: 0.6, blue: 0.133)
        case .success: Color(red: 0.247, green: 0.725, blue: 0.314)
        case .error, .interrupted: Color(red: 0.973, green: 0.318, blue: 0.286)
        }
    }

    private var summaryText: String {
        if self.tool.status == .running {
            return ToolStatusDisplay.running(for: self.tool.name, input: self.tool.input).text
        }
        if self.tool.status == .waitingForApproval {
            return "Waiting for approval"
        }
        return ToolStatusDisplay.completed(for: self.tool.name, result: self.tool.structuredResult).text
    }
}
```

- [ ] **Step 2: Build and verify**

```bash
xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -5
```

- [ ] **Step 3: Commit**

```bash
git add ClaudeIsland/UI/Components/ToolCallSummaryView.swift
git commit -m "feat: add ToolCallSummaryView for Chat mode compact summaries"
```

---

### Task 7: Create TerminalModeView

**Goal:** Build the Terminal mode message renderer with dense inline tool calls.

**Files:**
- Create: `ClaudeIsland/UI/Views/TerminalModeView.swift`

**Acceptance Criteria:**
- [ ] User messages render with blue "You" label, monospace font
- [ ] Assistant text renders with purple "Claude" label, monospace markdown
- [ ] Tool calls render via `ToolCallInlineView` (inline with content visible)
- [ ] Thinking blocks render via `ThinkingBlockView` (collapsed)
- [ ] Interrupted messages render as red "Interrupted" text
- [ ] Each item has `scaleEffect(x: 1, y: -1)` for inverted scroll compatibility

**Verify:** `xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -5` → BUILD SUCCEEDED

**Steps:**

- [ ] **Step 1: Create TerminalModeView.swift**

Create `ClaudeIsland/UI/Views/TerminalModeView.swift`:

```swift
//
//  TerminalModeView.swift
//  ClaudeIsland
//
//  Terminal mode: dense inline tool rendering with full content visible
//

import SwiftUI

struct TerminalModeView: View {
    // MARK: Internal

    let item: ChatHistoryItem
    let sessionID: String
    let onApprove: (() -> Void)?
    let onDeny: (() -> Void)?

    var body: some View {
        switch self.item.type {
        case let .user(text):
            self.userMessage(text)
        case let .assistant(text):
            self.assistantMessage(text)
        case let .toolCall(tool):
            ToolCallInlineView(
                tool: tool,
                sessionID: self.sessionID,
                onApprove: self.onApprove,
                onDeny: self.onDeny,
            )
        case let .thinking(text):
            ThinkingBlockView(text: text)
        case .interrupted:
            self.interruptedMessage
        }
    }

    // MARK: Private

    private let labelBlue = Color(red: 0.345, green: 0.651, blue: 1.0)
    private let labelPurple = Color(red: 0.702, green: 0.557, blue: 0.941)

    private func userMessage(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("You")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(self.labelBlue)

            MarkdownText(text, color: .white.opacity(0.9), fontSize: 11)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func assistantMessage(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Claude")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(self.labelPurple)

            MarkdownText(text, color: .white.opacity(0.9), fontSize: 11)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var interruptedMessage: some View {
        Text("Interrupted")
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(Color(red: 0.973, green: 0.318, blue: 0.286))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
```

- [ ] **Step 2: Build and verify**

```bash
xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -5
```

- [ ] **Step 3: Commit**

```bash
git add ClaudeIsland/UI/Views/TerminalModeView.swift
git commit -m "feat: add TerminalModeView with dense inline rendering"
```

---

### Task 8: Create ChatModeView

**Goal:** Build the Chat mode message renderer with iMessage-style bubbles.

**Files:**
- Create: `ClaudeIsland/UI/Views/ChatModeView.swift`

**Acceptance Criteria:**
- [ ] User messages render as right-aligned blue bubbles (16px radius, 4px bottom-right)
- [ ] Assistant messages render left-aligned with purple "C" avatar (24px)
- [ ] Assistant bubble uses system font via `MarkdownText(useSystemFont: true)`
- [ ] Tool calls render as compact summaries via `ToolCallSummaryView` within assistant bubble
- [ ] Consecutive assistant items (text, tools, thinking) group into one visual bubble
- [ ] Thinking blocks use `ThinkingBlockView` inside the bubble
- [ ] Interrupted messages show red text inside assistant bubble

**Verify:** `xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -5` → BUILD SUCCEEDED

**Steps:**

- [ ] **Step 1: Create ChatModeView.swift**

Create `ClaudeIsland/UI/Views/ChatModeView.swift`:

```swift
//
//  ChatModeView.swift
//  ClaudeIsland
//
//  Chat mode: iMessage-style bubbles with compact tool summaries
//

import SwiftUI

struct ChatModeView: View {
    // MARK: Internal

    let item: ChatHistoryItem
    let sessionID: String

    var body: some View {
        switch self.item.type {
        case let .user(text):
            self.userBubble(text)
        case let .assistant(text):
            self.assistantBubble {
                MarkdownText(text, color: .white.opacity(0.9), fontSize: 13, useSystemFont: true)
            }
        case let .toolCall(tool):
            self.assistantBubble {
                VStack(alignment: .leading, spacing: 0) {
                    Rectangle()
                        .fill(Color.white.opacity(0.06))
                        .frame(height: 1)
                        .padding(.bottom, 6)

                    ToolCallSummaryView(tool: tool)
                }
            }
        case let .thinking(text):
            self.assistantBubble {
                ThinkingBlockView(text: text)
            }
        case .interrupted:
            self.assistantBubble {
                Text("Interrupted")
                    .font(.system(size: 13))
                    .foregroundColor(Color(red: 0.973, green: 0.318, blue: 0.286))
            }
        }
    }

    // MARK: Private

    private let bubbleBlue = Color(red: 0.145, green: 0.388, blue: 0.918)
    private let avatarPurple = Color(red: 0.486, green: 0.227, blue: 0.929)

    private func userBubble(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 60)

            MarkdownText(text, color: .white, fontSize: 13, useSystemFont: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    BubbleShape(isUser: true)
                        .fill(self.bubbleBlue),
                )
        }
    }

    private func assistantBubble<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 10) {
            // Avatar
            Text("C")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(self.avatarPurple))

            // Bubble
            content()
                .frame(maxWidth: 600, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    BubbleShape(isUser: false)
                        .fill(Color.white.opacity(0.04)),
                )

            Spacer(minLength: 40)
        }
    }
}

// MARK: - BubbleShape

private struct BubbleShape: Shape {
    let isUser: Bool

    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 16
        let smallRadius: CGFloat = 4

        if self.isUser {
            // User: small radius on bottom-right
            return Path(
                roundedRect: rect,
                cornerRadii: RectangleCornerRadii(
                    topLeading: radius,
                    bottomLeading: radius,
                    bottomTrailing: smallRadius,
                    topTrailing: radius,
                ),
            )
        } else {
            // Assistant: small radius on top-left
            return Path(
                roundedRect: rect,
                cornerRadii: RectangleCornerRadii(
                    topLeading: smallRadius,
                    bottomLeading: radius,
                    bottomTrailing: radius,
                    topTrailing: radius,
                ),
            )
        }
    }
}
```

- [ ] **Step 2: Build and verify**

```bash
xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -5
```

- [ ] **Step 3: Commit**

```bash
git add ClaudeIsland/UI/Views/ChatModeView.swift
git commit -m "feat: add ChatModeView with iMessage-style bubbles"
```

---

### Task 9: Refactor ChatView into shell with mode routing

**Goal:** Refactor ChatView to route rendering to TerminalModeView or ChatModeView based on selected mode, add segmented control to header.

**Files:**
- Modify: `ClaudeIsland/UI/Views/ChatView.swift`

**Acceptance Criteria:**
- [ ] Header has segmented control (`Terminal | Chat`) after the session title
- [ ] `messageList` routes each item to `TerminalModeView` or `ChatModeView` based on `AppSettings.chatViewMode`
- [ ] All shared logic (autoscroll, input bar, keyboard monitoring, history loading, approval bar) remains in ChatView
- [ ] Existing `MessageItemView`, `UserMessageView`, `AssistantMessageView`, `ToolCallView`, `ThinkingView`, `InterruptedMessageView` are removed (replaced by mode views)
- [ ] `ProcessingIndicatorView`, `SubagentToolsList`, `SubagentToolRow`, `SubagentToolsSummary`, `ChatApprovalBar`, `ChatInteractivePromptBar`, `NewMessagesIndicator`, `ProcessingSpinner` remain in ChatView (shared infrastructure)
- [ ] Terminal mode passes `onApprove`/`onDeny` closures for inline approval in `ToolCallInlineView`
- [ ] Chat mode relies on existing `approvalBar` at bottom (no inline approval)
- [ ] Build succeeds with 0 lint violations

**Verify:** `xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -5` → BUILD SUCCEEDED, then `swiftlint lint --strict ClaudeIsland/ 2>&1 | tail -3` → 0 violations

**Steps:**

- [ ] **Step 1: Add @AppStorage for chatViewMode to ChatView**

In ChatView's private properties section (around line 198), add:

```swift
@AppStorage("chatViewMode") private var chatViewMode: String = ChatViewMode.terminal.rawValue
```

Add a computed property:

```swift
private var currentMode: ChatViewMode {
    ChatViewMode(rawValue: self.chatViewMode) ?? .terminal
}
```

- [ ] **Step 2: Modify chatHeader to include segmented control**

Replace the `chatHeader` computed property. Add a `Picker` with segmented style after the session title text:

```swift
private var chatHeader: some View {
    HStack(spacing: 8) {
        Button {
            self.viewModel.exitChat()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white.opacity(self.isHeaderHovered ? 1.0 : 0.6))
                    .frame(width: 24, height: 24)

                Text(self.session.displayTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white.opacity(self.isHeaderHovered ? 1.0 : 0.85))
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .onHover { self.isHeaderHovered = $0 }

        Spacer()

        // View mode toggle
        Picker("", selection: self.$chatViewMode) {
            Text("Terminal").tag(ChatViewMode.terminal.rawValue)
            Text("Chat").tag(ChatViewMode.chat.rawValue)
        }
        .pickerStyle(.segmented)
        .frame(width: 140)
        .labelsHidden()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(Color.black.opacity(0.2))
    .overlay(alignment: .bottom) {
        LinearGradient(
            colors: [self.fadeColor.opacity(0.7), self.fadeColor.opacity(0)],
            startPoint: .top,
            endPoint: .bottom,
        )
        .frame(height: 24)
        .offset(y: 24)
        .allowsHitTesting(false)
    }
    .zIndex(1)
}
```

- [ ] **Step 3: Replace MessageItemView dispatch in messageList**

In the `messageList` computed property, replace the `ForEach` block. Instead of:

```swift
ForEach(self.history.reversed()) { item in
    MessageItemView(item: item, sessionID: self.sessionID)
        .padding(.horizontal, 16)
        .scaleEffect(x: 1, y: -1)
        ...
}
```

Use:

```swift
ForEach(self.history.reversed()) { item in
    Group {
        switch self.currentMode {
        case .terminal:
            TerminalModeView(
                item: item,
                sessionID: self.sessionID,
                onApprove: { self.approvePermission() },
                onDeny: { self.denyPermission() },
            )
        case .chat:
            ChatModeView(item: item, sessionID: self.sessionID)
        }
    }
    .padding(.horizontal, 16)
    .scaleEffect(x: 1, y: -1)
    .transition(.asymmetric(
        insertion: .opacity.combined(with: .scale(scale: 0.98)),
        removal: .opacity,
    ))
}
```

- [ ] **Step 4: Remove old message view types**

Delete `MessageItemView`, `UserMessageView`, `AssistantMessageView`, `ToolCallView` (the large struct from ~line 851-1057), `ThinkingView`, and `InterruptedMessageView` from ChatView.swift. These are replaced by the mode views and new components.

Keep: `ProcessingIndicatorView`, `SubagentToolsList`, `SubagentToolRow`, `SubagentToolsSummary`, `ChatApprovalBar`, `ChatInteractivePromptBar`, `NewMessagesIndicator`, `ProcessingSpinner` (if present).

- [ ] **Step 5: Update the LazyVStack spacing for Terminal mode**

In the `messageList`, make the spacing conditional:

```swift
LazyVStack(spacing: self.currentMode == .terminal ? 8 : 12) {
```

Terminal mode uses tighter 8px spacing for density.

- [ ] **Step 6: Build and lint**

```bash
xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -5
swiftlint lint --strict ClaudeIsland/ 2>&1 | tail -10
```

Fix any file_length or other lint violations by extracting remaining helper views to separate files if needed.

- [ ] **Step 7: Commit**

```bash
git add ClaudeIsland/UI/Views/ChatView.swift
git commit -m "feat: refactor ChatView with Terminal/Chat mode toggle"
```

---

### Task 10: Lint pass and final cleanup

**Goal:** Fix any remaining lint violations, verify the build, and clean up unused code.

**Files:**
- Modify: Any files with lint violations (likely ChatView.swift if still over 600 lines)

**Acceptance Criteria:**
- [ ] `swiftlint lint --strict ClaudeIsland/` returns 0 violations
- [ ] `swiftformat ClaudeIsland/` makes no changes
- [ ] `xcodebuild -scheme ClaudeIsland -configuration Debug build` succeeds
- [ ] No unused imports or dead code

**Verify:** `swiftlint lint --strict ClaudeIsland/ 2>&1 | tail -3` → 0 violations, `xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -5` → BUILD SUCCEEDED

**Steps:**

- [ ] **Step 1: Run swiftformat**

```bash
swiftformat ClaudeIsland/
```

- [ ] **Step 2: Run swiftlint and fix violations**

```bash
swiftlint lint --strict ClaudeIsland/ 2>&1 | grep -E "warning:|error:"
```

If ChatView.swift exceeds 600 lines, extract `ProcessingIndicatorView`, `SubagentToolsList`, `SubagentToolRow`, `SubagentToolsSummary` into `ClaudeIsland/UI/Components/ProcessingViews.swift` and `ChatApprovalBar`, `ChatInteractivePromptBar` into `ClaudeIsland/UI/Components/ChatBarViews.swift`.

- [ ] **Step 3: Build and verify**

```bash
xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -5
```

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "chore: lint pass and cleanup for chat view redesign"
```

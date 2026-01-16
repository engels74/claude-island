# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Claude Island is a macOS menu bar app that provides Dynamic Island-style notifications for Claude Code CLI sessions. It displays an animated overlay that expands from the MacBook notch, showing live session status, permission approval buttons, and chat history.

**Requirements:** macOS 15.6+, Claude Code CLI

## Build Commands

```bash
# Build release archive (Developer ID signed)
./scripts/build.sh

# Quick development build
xcodebuild -scheme ClaudeIsland -configuration Release build

# Full release with notarization and DMG
./scripts/create-release.sh
```

## Architecture

### Communication Flow

1. **Hook Installation** (`HookInstaller.swift`) - On launch, installs `claude-island-state.py` into `~/.claude/hooks/` and updates `~/.claude/settings.json` to register hooks for all Claude Code events
2. **Unix Socket Server** (`HookSocketServer.swift`) - Listens on `/tmp/claude-island.sock` for real-time events from the Python hook script. Uses GCD DispatchSource for non-blocking I/O
3. **Session State** (`SessionStore.swift`) - Swift actor that serves as single source of truth. All state mutations flow through `process(_ event: SessionEvent)`
4. **JSONL Parsing** (`ConversationParser.swift`) - Parses `~/.claude/projects/<project>/<session>.jsonl` files for chat history and tool results

### Event Pipeline

```
Python Hook → Unix Socket → HookEvent → SessionStore.process() → SessionState → UI via Combine
```

### Key Types

- `SessionPhase` - idle, processing, waitingForApproval, waitingForInput, compacting
- `SessionState` - Full state for one Claude session including chatItems, toolTracker, subagentState
- `HookEvent` - Decoded events from the Python hook (PreToolUse, PostToolUse, PermissionRequest, etc.)
- `ToolResultData` - Structured tool results (bash output, file content, task results, etc.)

### UI Layer

- **NotchViewModel** - State machine for notch open/close/pop animations
- **NotchView** - SwiftUI root view with animated transitions
- **ChatView** - Markdown-rendered conversation with tool result displays
- **NotchWindow** - NSPanel configured as overlay above all windows

### Permission Handling

When Claude needs tool approval:

1. `PermissionRequest` hook fires, socket stays open awaiting response
2. `SessionStore` transitions to `.waitingForApproval` phase
3. Notch expands showing approve/deny buttons
4. `ToolApprovalHandler` sends response via socket or tmux sendkeys fallback

## Code Patterns

- **Actor isolation**: `SessionStore` is an actor; use `await` for all method calls
- **Combine publishers**: UI subscribes to `sessionsPublisher` for reactive updates
- **Event-driven state**: Never mutate `SessionState` directly; always dispatch through `SessionEvent`

## Dependencies

- **Sparkle** - Auto-update framework
- **Mixpanel** - Anonymous analytics (app launch, session start events only)

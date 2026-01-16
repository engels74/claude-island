# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Claude Island is a macOS menu bar app (macOS 15.6+) that provides Dynamic Island-style notifications for Claude Code CLI sessions. It displays a notch overlay that expands from the MacBook notch, showing live session status and allowing permission approvals directly from the UI.

## Build Commands

```bash
# Build for development
xcodebuild -scheme ClaudeIsland -configuration Debug build

# Build release with ad-hoc signing
./scripts/build.sh

# Build release (no scripts)
xcodebuild -scheme ClaudeIsland -configuration Release build
```

## Linting and Formatting

```bash
# Run all pre-commit checks
prek run --all-files

# Format Swift files
swiftformat ClaudeIsland

# Lint Swift files
swiftlint lint --strict ClaudeIsland

# Lint shell scripts
shellcheck scripts/*.sh
```

## Architecture

### Core Components

- **SessionStore** (`Services/State/SessionStore.swift`) - Actor-based central state manager for all Claude sessions. All state mutations flow through `process(_ event:)`. Uses event-driven architecture with `SessionEvent` enum.

- **HookSocketServer** (`Services/Hooks/HookSocketServer.swift`) - Unix socket server that receives events from Claude Code CLI hooks. Hooks are installed in `~/.claude/hooks/` and communicate session state via socket.

- **NotchViewModel** (`Core/NotchViewModel.swift`) - `@Observable` view model managing notch UI state (opened/closed/popping), content type switching, and geometry calculations.

- **ClaudeSessionMonitor** (`Services/Session/ClaudeSessionMonitor.swift`) - Coordinates between HookSocketServer and SessionStore, handles interrupt detection and permission callbacks.

### Data Flow

1. Claude Code CLI triggers hooks that send JSON events to HookSocketServer
2. HookSocketServer parses events and forwards to SessionStore via `process(.hookReceived(event))`
3. SessionStore updates session state and publishes changes via Combine
4. NotchViewModel and views react to state changes

### UI Layer

- **NotchWindow/NotchWindowController** - Custom NSPanel-based floating window positioned at screen notch
- **NotchView** - Main SwiftUI view composing the notch UI
- **ChatView/ClaudeInstancesView** - Content views for chat history and session list

### Key Patterns

- Uses `@Observable` macro (macOS 14+) for view models instead of `ObservableObject`
- Actor isolation for thread-safe state management
- Combine publishers for cross-component communication
- GCD DispatchSource for non-blocking socket I/O

## Code Style

- Use `os.Logger` for logging, not `print()` (enforced by SwiftLint custom rule)
- Line length: 150 warning, 200 error
- SwiftFormat handles organization with `organizeDeclarations` and `sortDeclarations` enabled
- `HookSocketServer.swift` is excluded from SwiftFormat's `organizeDeclarations` due to complexity

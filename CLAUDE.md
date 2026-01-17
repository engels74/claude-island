# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Coding Guidelines

See `.augment/rules/` for detailed best practices:

- `swift-dev-pro.md` - Modern Swift 5.9–6.x patterns (actors, @Observable, structured concurrency)
- `python-314-pro.md` - Python 3.14+ patterns (for the hook script in `ClaudeIsland/Resources/`)

## Project Overview

Claude Island is a macOS menu bar application (Swift/SwiftUI) that displays Dynamic Island-style notifications for Claude Code CLI sessions. It monitors Claude Code activities via Unix socket IPC and displays status updates, permission requests, and chat history in an animated notch overlay.

**Requirements:** macOS 15.6+, Xcode 16.x, Swift 5.9+

## Build Commands

```bash
# Build release
./scripts/build.sh
# Output: build/export/Claude Island.app

# Build with xcodebuild directly
xcodebuild -scheme ClaudeIsland -configuration Release build

# Create release DMG (requires Sparkle keys)
./scripts/create-release.sh --skip-notarization

# Run pre-commit hooks (linting/formatting)
prek run --all-files

# Install pre-commit hooks
prek install --hook-type pre-commit --hook-type pre-push
```

## Code Quality

The project uses strict linting enforced by pre-commit hooks:

- **SwiftFormat** (v0.55.3): Auto-formats Swift code
- **SwiftLint** (v0.57.1): Lints with `--strict` mode, 70+ opt-in rules enabled
- **Ruff** (v0.14.11+): Python linting/formatting for hook script
- **ShellCheck**: Shell script validation

Key linting rules:

- Line length: warning 150, error 200
- Use `os.Logger` instead of `print()` for logging
- Function body: warning 60, error 100 lines
- Force unwrapping/cast/try are warnings, not errors

## Architecture

### Core Pattern: MVVM + Actors + Event-Driven

The app uses Swift actors for thread-safe state management and `@Observable` for SwiftUI reactivity.

**Key Components:**

- **`SessionStore`** (actor): Thread-safe container for all session state, emits changes via `AsyncStream`
- **`NotchViewModel`** (`@Observable`): Aggregates state for UI, handles user interactions
- **`HookSocketServer`**: Listens on `/tmp/claude-island.sock` for JSON messages from Python hook
- **`ClaudeSessionMonitor`**: Watches Claude JSONL history files, parses conversations incrementally
- **`ConversationParser`**: Streams JSONL files line-by-line into `SessionEvent` objects

### Directory Structure

```
ClaudeIsland/
├── App/           # App entry point, AppDelegate, WindowManager
├── Core/          # ViewModels, Settings, geometry calculations
├── Models/        # Data models (ChatMessage, SessionEvent, SessionState)
├── Services/      # Business logic split by domain:
│   ├── Hooks/     # Socket server, hook installer
│   ├── Session/   # Session monitoring, JSONL parsing
│   ├── State/     # SessionStore actor, event processing
│   ├── Tmux/      # Tmux integration
│   └── Window/    # Window focusing, Yabai integration
├── UI/            # SwiftUI views and components
│   ├── Views/     # Main views (NotchView, ChatView, etc.)
│   ├── Window/    # NSPanel/NSHostingView wrappers
│   └── Components/# Reusable UI components
└── Resources/     # Python hook script (claude-island-state.py)
```

### IPC Flow

1. Claude Code runs with hooks installed at `~/.claude/hooks/`
2. Python hook (`claude-island-state.py`) sends JSON events to Unix socket
3. `HookSocketServer` receives events and updates `SessionStore`
4. `NotchViewModel` observes `SessionStore` changes via `AsyncStream`
5. SwiftUI views reactively update based on `NotchViewModel` state

## Python Hook

The hook script at `ClaudeIsland/Resources/claude-island-state.py` uses **Python 3.14+** with modern syntax:

- PEP 758 bracketless `except` clauses
- PEP 649 deferred annotations (no forward reference quotes needed)
- TypedDicts for basedpyright compliance
- Pattern matching (`match`/`case`)

## CI/CD

GitHub Actions workflows:

- **`code-quality.yml`**: Runs on push to main and PRs, executes `prek run --all-files`
- **`release.yml`**: Manual trigger or tag push (`v*`), builds DMG with Sparkle signing

## Signing

The app uses ad-hoc signing (`CODE_SIGN_IDENTITY=-`) for development. Users must bypass Gatekeeper on first launch:

```bash
xattr -d com.apple.quarantine "/Applications/Claude Island.app"
```

Auto-updates via Sparkle work normally after first launch.

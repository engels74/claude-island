# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Claude Atoll is a macOS menu bar app (Swift 6.2, macOS 15.6+) that brings Dynamic Island-style notifications to Claude Code CLI sessions. It installs hooks into `~/.claude/hooks/` that communicate session state via a Unix socket. The app listens for events and displays them in a notch overlay with approve/deny buttons for tool permission requests.

## Build & Development Commands

```bash
# Build (release, ad-hoc signed)
./scripts/build.sh

# Build via Xcode directly
xcodebuild -scheme ClaudeAtoll -configuration Release build

# Lint (strict mode — warnings are errors)
swiftlint lint --strict ClaudeAtoll/

# Auto-format
swiftformat ClaudeAtoll/

# Run all pre-commit checks
prek run --all-files

# Install pre-commit hooks (one-time setup)
prek install --hook-type pre-commit --hook-type pre-push

# Create DMG (local testing, no notarization/GitHub/website)
./scripts/create-release.sh --skip-notarization --skip-github --skip-website --skip-sparkle
```

Dependencies: `brew install swiftformat swiftlint shellcheck create-dmg`

## Architecture

### Event-Driven State Machine

All state flows through a single actor: `SessionStore.shared`. Every mutation enters via `SessionStore.process(_ event: SessionEvent)`. Views subscribe via `sessionsStream() -> AsyncStream<[SessionState]>`.

```
HookSocketServer (Unix socket, receives JSON from Python hook)
  → SessionStore.process(.hookReceived(event))
    → updates SessionState (immutable struct, replaced in dict)
    → publishState() yields via AsyncStream
      → ChatHistoryManager (@Observable, subscribes to stream)
      → ClaudeSessionMonitor (@Observable, subscribes to stream)
        → SwiftUI views re-render
```

### Key Layers

- **App/** — Entry point (`ClaudeAtollApp` @main), `AppDelegate` (lifecycle, hook install, window setup), `WindowManager`
- **Core/** — `NotchViewModel` (@Observable UI state), `ModuleRegistry`/`ModuleLayoutEngine` (plugin-based notch modules), `AppSettings` (UserDefaults wrapper)
- **Services/** — The business logic layer:
  - `State/SessionStore` (actor) — central state, all mutations here
  - `Hooks/HookSocketServer` (actor) — Unix domain socket server for hook events
  - `Hooks/HookInstaller` — auto-installs Python hook script into `~/.claude/hooks/`
  - `Session/ConversationParser` (actor) — incremental JSONL parsing for chat history
  - `Chat/ChatHistoryManager` (@Observable) — UI-facing chat data
  - `TokenTracking/ClaudeAPIService` (actor) — fetches usage from Anthropic API via OAuth
  - `Tmux/ToolApprovalHandler` — sends approve/deny to Claude via tmux
- **Models/** — `SessionEvent` (all event types), `SessionState` (immutable), `SessionPhase` (state machine), `ChatMessage`
- **UI/** — SwiftUI views + AppKit bridge (`NotchWindow`/`NotchPanel` NSPanel subclass for borderless overlay)
  - `Modules/` — `NotchModule` protocol implementations (dots, spinner, token rings, Clawd mascot, etc.)

### IPC & Data Flow

- **Hook → App**: Python script (`claude-atoll-state.py` bundled in Resources) sends JSON over Unix socket to `HookSocketServer`
- **Chat History**: Parsed from JSONL files at `~/.claude/cwd/.claude-atoll/conversation-{sessionID}.jsonl` by `ConversationParser` (incremental tail-based parsing for large files)
- **Permission Approval**: `ToolApprovalHandler` sends keystrokes to the correct tmux pane via `TmuxController`
- **Token Tracking**: `ClaudeAPIService` reads OAuth token from Keychain (`CLIOAuthKeychainGate`) and calls `api.anthropic.com`

### Module System

The notch UI uses a plugin architecture via the `NotchModule` protocol. Each module declares its side, order, visibility conditions, and renders its own view. `ModuleLayoutEngine` computes positions. Modules: `SessionDotsModule`, `ActivitySpinnerModule`, `PermissionIndicatorModule`, `TokenRingsModule`, `ClawdModule`, `TimerModule`, `ReadyCheckmarkModule`, `AccessibilityWarningModule`.

## Conventions

### Concurrency

- **Actors** for mutable shared state (`SessionStore`, `HookSocketServer`, `ConversationParser`, `ClaudeAPIService`)
- **`@Observable`** (not `@StateObject`/`@Published`) for all UI-facing state
- **`@MainActor`** on UI protocols and view-related code
- **`@concurrent`** on CPU-intensive nonisolated async functions (e.g., `ProcessExecutor.run`)
- **Typed throws** (SE-0413): `throws(ProcessExecutorError)`, `throws(APIServiceError)`, etc.
- **Named tasks** for debugging: `Task(name: "session-stream-register") { ... }`
- **`Sendable`** on all value types, error enums, and cross-actor data
- **`Mutex`** from `Synchronization` for thread-safe collections (not locks)

### Logging

Use `os.Logger` exclusively — never `print()`. SwiftLint enforces this via `no_print_statements` custom rule. Each component has a static nonisolated logger:

```swift
nonisolated static let logger = Logger(subsystem: "com.engels74.ClaudeAtoll", category: "ComponentName")
```

### Code Organization

- Large types split into extensions in separate files: `SessionStore+Subagents.swift`, `SessionStore+PeriodicCheck.swift`
- `// MARK: - Section Name` for organizing code within files
- File names match type names exactly

### Style (enforced by SwiftFormat + SwiftLint)

- 4-space indentation, 150-char line width (200 error)
- Alphabetical imports
- `self.` inserted explicitly (`--self insert`)
- Type/func attributes on previous line, var attributes on same line
- Modifier order: `nonisolated, override, acl, setterACL, dynamic, mutating, nonmutating, lazy, final, required, convenience, typeMethods, owned`
- Acronyms preserved: `ID, URL, UUID, HTTP, JSON, API, UI, MCP, PID, JSONL, CLI, SDK`

### SwiftLint Thresholds

- File length: 600 warning / 1000 error
- Function body: 60 warning / 100 error
- Cyclomatic complexity: 15 warning / 25 error
- Line length: 150 warning / 200 error

### Excluded from Formatting

`HookSocketServer.swift` is excluded from SwiftFormat's `organizeDeclarations` due to file complexity causing timeouts.

## CI/CD

Three GitHub Actions workflows:

- **code-quality.yml** — Runs `prek` checks (SwiftFormat, SwiftLint, shellcheck, markdownlint, ruff) on push/PR to main
- **ci.yml** — Builds app via `build.sh`, creates DMG, optional VirusTotal scan
- **release.yml** — Triggered by semver tag push (e.g., `1.0.0`); builds, creates DMG, creates GitHub release, updates website appcast via repository dispatch to `engels74/claude-atoll-web`

Pre-commit hooks skip SwiftFormat/SwiftLint in CI (handled separately by the code-quality workflow). The `no-commit-to-branch` hook prevents direct commits to main.

## Swift Development Reference

See `.augment/rules/swift-dev-pro.md` for the comprehensive Swift 6.2+ coding reference covering concurrency, typed throws, `@Observable`, ownership, macros, and Swift Testing framework conventions.

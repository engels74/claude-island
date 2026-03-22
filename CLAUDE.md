# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Is

Claude Island is a macOS menu bar app (Swift 6 / SwiftUI) that provides Dynamic Island-style notifications for Claude Code CLI sessions. It renders an animated overlay from the MacBook notch, showing session status, permission approval buttons, chat history, and token usage. Fork of [farouqaldori/claude-island](https://github.com/farouqaldori/claude-island).

**Requirements:** macOS 15.6+, Xcode 26+ (Swift 6.2), Claude Code CLI.

## Build & Development

```bash
# Build (ad-hoc signed)
./scripts/build.sh
# or directly:
xcodebuild -scheme ClaudeIsland -configuration Release build

# Create DMG release (run after build)
./scripts/create-release.sh --skip-notarization --skip-github --skip-website
```

There is no test target in this project. The Xcode scheme has a test action configured but there are currently no test files.

## Linting & Formatting

Pre-commit hooks enforce all quality checks. Install with:

```bash
prek install --hook-type pre-commit --hook-type pre-push
```

Run all checks manually:

```bash
prek run --all-files
```

Individual tools:

```bash
swiftformat .                    # Auto-format Swift (config: .swiftformat)
swiftlint lint --strict          # Lint Swift (config: .swiftlint.yml)
shellcheck scripts/*.sh          # Lint shell scripts
ruff check --fix ClaudeIsland/Resources/  # Lint Python hook script
ruff format ClaudeIsland/Resources/       # Format Python hook script
```

**SwiftFormat** targets Swift 6.2, enforces `--self insert`, `--redundanttype inferred`, 150 char max width, `before-first` wrapping for arguments/parameters/collections, and `organizeDeclarations` (MARK-based section ordering). HookSocketServer.swift is excluded from `organizeDeclarations` due to file complexity.

**SwiftLint** key limits: line length 150/200, function body 60/100, file length 600/1000, type body 300/500, cyclomatic complexity 15/25.

## Architecture

### Communication Flow

```
Claude Code CLI
  → hooks (configured in ~/.claude/settings.json)
  → claude-island-state.py (Python 3.14+ script, bundled in Resources/)
  → Unix socket (/tmp/claude-island.sock)
  → HookSocketServer (GCD DispatchSource, non-blocking I/O)
  → SessionStore.process(event) (Swift actor, single entry point for all state mutations)
  → NotchViewModel → SwiftUI views
```

### Hook System

On first launch, `HookInstaller` copies `claude-island-state.py` to `~/.claude/hooks/` and registers hook entries in `~/.claude/settings.json` for these events: `UserPromptSubmit`, `PostToolUse`, `PermissionRequest`, `Notification`, `Stop`, `SubagentStop`, `SessionStart`, `SessionEnd`, `PreCompact`. The Python script sends JSON over the Unix socket; for `PermissionRequest` events, it blocks waiting for the app's approve/deny response.

**Note:** `PreToolUse` is intentionally not registered due to upstream Claude Code bug (#15897) with parallel hook `updatedInput` aggregation.

### Session State Machine

`SessionPhase` is an explicit state machine (`SessionPhase.swift`). Phases: `idle`, `processing`, `waitingForInput`, `waitingForApproval(PermissionContext)`, `compacting`, `ended`. All transitions are validated via `canTransition(to:)`.

`SessionEvent` (`SessionEvent.swift`) is the single event type for all state mutations — hook events, permission decisions, file updates, tool completions, subagent lifecycle, interrupts. Everything flows through `SessionStore.process(_ event:)`.

### Module System

The notch UI uses a pluggable module system. `NotchModule` protocol defines visibility, layout, and rendering. `ModuleRegistry` holds all modules (Clawd, PermissionIndicator, AccessibilityWarning, ActivitySpinner, ReadyCheckmark, TokenRings, SessionDots, Timer). `ModuleLayoutEngine` computes left/right placement based on user-configurable `ModuleLayoutConfig` stored in UserDefaults.

### Key Source Layout

- `ClaudeIsland/App/` — App entry point (`@main`), `AppDelegate`, `WindowManager`, `ScreenObserver`
- `ClaudeIsland/Core/` — `NotchViewModel`, `NotchGeometry`, module system, `Settings`, selectors, `AccessibilityPermissionManager`
- `ClaudeIsland/Models/` — `SessionState`, `SessionPhase`, `SessionEvent`, `ChatMessage`, `JSONValue`
- `ClaudeIsland/Services/Hooks/` — `HookInstaller`, `HookSocketServer`, Python runtime detection
- `ClaudeIsland/Services/State/` — `SessionStore` (actor), subagent tracking, periodic checks
- `ClaudeIsland/Services/Session/` — `ConversationParser` (JSONL parsing), `ClaudeSessionMonitor`
- `ClaudeIsland/Services/Window/` — `TerminalFocuser`, `YabaiController`, `WindowFinder`
- `ClaudeIsland/Services/Tmux/` — tmux integration (session matching, path finding, tool approval)
- `ClaudeIsland/UI/Views/` — `NotchView`, `ChatView`, `ClaudeInstancesView`, tool result views
- `ClaudeIsland/UI/Modules/` — Individual module implementations (conform to `NotchModule`)
- `ClaudeIsland/UI/Components/` — Reusable UI components (`NotchShape`, `MarkdownRenderer`, `TokenRingView`)
- `ClaudeIsland/Resources/` — `claude-island-state.py` (hook script), entitlements

### SPM Dependencies

- **Sparkle** — Auto-updates
- **swift-markdown** — Markdown rendering in chat view
- **OcclusionKit** — Window occlusion detection
- **swift-subprocess** — Process execution

## Conventions

- **Swift concurrency:** Uses `@Observable` (not `ObservableObject`), Swift actors for thread safety, `Sendable` conformance throughout. `HookSocketServer` uses `@unchecked Sendable` with GCD serial queue + `Mutex` for lock-protected state.
- **Singletons:** Major services use `static let shared` pattern (`SessionStore.shared`, `HookSocketServer.shared`, `ModuleRegistry.shared`).
- **Logging:** `os.Logger` with subsystem `"com.engels74.ClaudeIsland"` and per-type categories.
- **Settings:** `AppSettings` enum with static computed properties backed by `UserDefaults`.
- **File naming:** Extensions use `TypeName+Feature.swift` pattern (e.g., `SessionStore+Subagents.swift`, `ConversationParser+Subagents.swift`).
- **Python hook script:** Requires Python 3.14+, uses `TypedDict`, `TypeIs`, `dataclass`, `match` statements. Linted with ruff.
- **SwiftFormat `organizeDeclarations`:** Code sections are ordered by MARK comments (`Lifecycle`, `Internal`, `Private`). SwiftFormat enforces this automatically.
- **`nonisolated` usage:** Extensively used for `Sendable` structs/enums and static properties to opt out of actor isolation where thread safety is guaranteed by design.

## CI/CD

- **Code Quality** (`code-quality.yml`): Runs `prek` (pre-commit) checks on push/PR to main.
- **CI** (`ci.yml`): Builds DMG after Code Quality passes, runs VirusTotal scan.
- **Release** (`release.yml`): Triggered by version tags (`X.Y.Z`), builds, signs with Sparkle, creates GitHub release, updates website appcast.
- Version is managed via `MARKETING_VERSION` in `project.pbxproj`, updated by CI on tag push.

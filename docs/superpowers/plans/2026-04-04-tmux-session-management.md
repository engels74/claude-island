# Tmux Session Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add tmux session creation, project management, keyboard shortcuts, session actions, and chat view improvements to Claude Island.

**Architecture:** Four chunks with a clear dependency chain. Chunk 1 (session launcher) and Chunk 4 (chat improvements) have zero dependencies and run in parallel. Chunk 2 (project manager) depends on Chunk 1. Chunk 3 (keyboard shortcuts & session actions) depends on Chunks 1 and 2. Each chunk modifies the central event-driven state machine (SessionStore/SessionPhase/SessionEvent) and extends the SwiftUI view layer.

**Tech Stack:** Swift 6.2, macOS 15.6+, SwiftUI, AppKit (NSPanel, NSVisualEffectView, CGEvent), async/await actors, `@Observable`, UserDefaults persistence.

**Specs:** `docs/superpowers/specs/2026-04-03-chunk{1,2,3,4}-*-design.md`

---

## File Map

### Chunk 1: Tmux Session Launcher (new files)
- `ClaudeIsland/UI/Windows/SessionLauncherPanel.swift` — NSPanel subclass + NSVisualEffectView, dismiss monitors
- `ClaudeIsland/UI/Views/SessionLauncherView.swift` — SwiftUI launcher content (prompt, name, directory, bottom bar)
- `ClaudeIsland/Services/Tmux/TmuxSessionCreator.swift` — Actor, orchestrates tmux session + Claude launch
- `ClaudeIsland/UI/Views/NewSessionRow.swift` — Dashed "New Session" row + header `+` button

### Chunk 1: Tmux Session Launcher (modified files)
- `ClaudeIsland/Models/SessionPhase.swift` — Add `.launching(LaunchProgress)` case
- `ClaudeIsland/Models/SessionEvent.swift` — Add 4 launch event cases + `SessionLaunchPayload`
- `ClaudeIsland/Models/SessionState.swift` — Add `tmuxSessionName: String?`
- `ClaudeIsland/Services/State/SessionStore.swift` — Handle launch events, `pendingLaunches` dict, merge logic
- `ClaudeIsland/UI/Views/ClaudeInstancesView.swift` — NewSessionRow, `.launching` in phasePriority/InstanceRow
- `ClaudeIsland/UI/Views/NotchMenuView.swift` — Claude Command expandable setting
- `ClaudeIsland/Core/NotchViewModel.swift` — `showLauncher()`, `.sessionCreated` reason, openedSize adjustments
- `ClaudeIsland/Core/Settings.swift` — `claudeCommandTemplate`, `lastUsedDirectory` keys
- `ClaudeIsland/App/AppDelegate.swift` — SessionLauncherPanel creation

### Chunk 2: Project Manager (new files)
- `ClaudeIsland/Models/ProjectEntry.swift` — Codable model
- `ClaudeIsland/Services/ProjectStore.swift` — `@Observable final class`, manages pinned/recent
- `ClaudeIsland/UI/Views/ProjectsSettingsView.swift` — Expandable settings section
- `ClaudeIsland/UI/Views/DirectoryPickerView.swift` — Reusable picker for launcher

### Chunk 2: Project Manager (modified files)
- `ClaudeIsland/UI/Views/SessionLauncherView.swift` — Replace minimal picker with DirectoryPickerView
- `ClaudeIsland/Services/Session/ClaudeSessionMonitor.swift` — Call `ProjectStore.recordUsage` on SessionStart
- `ClaudeIsland/UI/Views/NotchMenuView.swift` — Add Projects expandable section
- `ClaudeIsland/Core/Settings.swift` — Add `projects` key

### Chunk 3: Keyboard Shortcuts & Session Actions (new files)
- `ClaudeIsland/Services/HotkeyManager.swift` — CGEvent tap + dispatch
- `ClaudeIsland/Models/KeyCombo.swift` — Model with custom Codable
- `ClaudeIsland/UI/Views/KeyRecorderView.swift` — Reusable SwiftUI recorder
- `ClaudeIsland/UI/Views/ShortcutsSettingsView.swift` — Expandable settings section
- `ClaudeIsland/UI/Views/SessionActionOverflowMenu.swift` — Overlay dropdown
- `ClaudeIsland/UI/Views/SessionActionsSettingsView.swift` — Reorderable action list

### Chunk 3: Keyboard Shortcuts & Session Actions (modified files)
- `ClaudeIsland/UI/Views/ClaudeInstancesView.swift` — Overflow `...` button, action callbacks, customizable slots
- `ClaudeIsland/UI/Views/NotchMenuView.swift` — Shortcuts + Session Actions sections
- `ClaudeIsland/Core/NotchViewModel.swift` — `focusInputOnAppear` flag, openedSize increase
- `ClaudeIsland/UI/Views/ChatView.swift` — Observe `focusInputOnAppear`
- `ClaudeIsland/Services/State/SessionStore.swift` — Unify session removal, `onSessionRemoved` callback
- `ClaudeIsland/Services/Tmux/TmuxController.swift` — `killSession(sessionName:)`
- `ClaudeIsland/App/AppDelegate.swift` — Init HotkeyManager, wire callbacks
- `ClaudeIsland/Core/Settings.swift` — `globalShortcut`, `sessionShortcuts`, `sessionActionOrder` keys

### Chunk 4: Chat View Improvements (modified files only)
- `ClaudeIsland/UI/Views/NotchMenuView.swift` — Panel Width slider
- `ClaudeIsland/Core/NotchViewModel.swift` — `chatPanelWidthFraction` property
- `ClaudeIsland/UI/Components/MarkdownRenderer.swift` — Task lists, code block header+copy, tables, spacing
- `ClaudeIsland/UI/Views/ChatView.swift` — Spacing reduction, maxWidth on text
- `ClaudeIsland/Core/Settings.swift` — `chatPanelWidthFraction` key

---

## Task 1: SessionPhase `.launching` + SessionEvent Launch Cases

**Goal:** Extend the state machine with the `.launching` phase and 4 launch event types so downstream tasks can use them.

**Files:**
- Modify: `ClaudeIsland/Models/SessionPhase.swift`
- Modify: `ClaudeIsland/Models/SessionEvent.swift`
- Modify: `ClaudeIsland/Models/SessionState.swift`

**Acceptance Criteria:**
- [ ] `SessionPhase.launching(LaunchProgress)` case exists with all 5 progress states
- [ ] `LaunchError` enum exists with 6 error cases, conforming to `Error, Sendable, Equatable`
- [ ] `PhaseKey.launching` exists and `matches(_:)` handles it
- [ ] `allowedTransitions(from: .launching)` returns `[.idle, .launching]`
- [ ] `needsAttention`, `isActive`, `Equatable`, `CustomStringConvertible` all handle `.launching`
- [ ] 4 new `SessionEvent` cases exist with `sessionID` and `description` computed properties updated
- [ ] `SessionLaunchPayload` struct exists
- [ ] `SessionState.tmuxSessionName: String?` field added
- [ ] Project builds with `xcodebuild -scheme ClaudeIsland build`

**Verify:** `xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -5` -> Build Succeeded

**Steps:**

- [ ] **Step 1: Add LaunchProgress and LaunchError enums to SessionPhase.swift**

Add before the `SessionPhase` enum:

```swift
// MARK: - LaunchProgress

nonisolated enum LaunchProgress: Sendable, Equatable {
    case creatingTmuxSession
    case startingClaude
    case waitingForHook
    case sendingPrompt
    case failed(LaunchError)
}

// MARK: - LaunchError

nonisolated enum LaunchError: Error, Sendable, Equatable {
    case tmuxNotInstalled
    case claudeNotInstalled
    case directoryNotFound(String)
    case tmuxSessionCreationFailed(String)
    case claudeStartTimeout
    case promptSendFailed(String)
}
```

- [ ] **Step 2: Add `.launching` case to SessionPhase enum**

Add after `.compacting`:

```swift
    /// Session is being launched via TmuxSessionCreator
    case launching(LaunchProgress)
```

- [ ] **Step 3: Update `needsAttention` computed property**

Add explicit case before `default`:

```swift
        case .launching:
            false
```

- [ ] **Step 4: Update `isActive` computed property**

Add explicit case before `default`:

```swift
        case .launching:
            false
```

- [ ] **Step 5: Update `PhaseKey` enum and `matches(_:)`**

Add `.launching` case to `PhaseKey`:

```swift
        case launching
```

Add to `matches(_:)` switch:

```swift
            case (.launching, .launching):
                true
```

- [ ] **Step 6: Update `allowedTransitions(from:)`**

Add case:

```swift
        case .launching:
            [.idle, .launching]
```

- [ ] **Step 7: Update Equatable conformance**

Add case in the `==` switch:

```swift
        case let (.launching(p1), .launching(p2)):
            p1 == p2
```

- [ ] **Step 8: Update CustomStringConvertible**

Add case:

```swift
        case let .launching(progress):
            "launching(\(progress))"
```

- [ ] **Step 9: Add SessionLaunchPayload and 4 event cases to SessionEvent.swift**

Add `SessionLaunchPayload` after `FileUpdatePayload`:

```swift
// MARK: - SessionLaunchPayload

nonisolated struct SessionLaunchPayload: Sendable {
    let sessionID: String
    let sessionName: String
    let cwd: String
    let prompt: String
    let commandTemplate: String
}
```

Add 4 new cases to `SessionEvent` enum after `.historyLoaded`:

```swift
    // MARK: - Launch Events (from TmuxSessionCreator)

    /// A new session is being launched
    case sessionLaunching(SessionLaunchPayload)

    /// Launch progress updated
    case launchProgressUpdated(sessionID: String, progress: LaunchProgress)

    /// Launch completed successfully (hook merged)
    case launchCompleted(sessionID: String)

    /// Launch failed
    case launchFailed(sessionID: String, error: LaunchError)
```

- [ ] **Step 10: Update `SessionEvent.sessionID` computed property**

Add to the binding pattern:

```swift
        case let .sessionLaunching(payload):
            payload.sessionID
        case let .launchProgressUpdated(sessionID, _),
             let .launchCompleted(sessionID),
             let .launchFailed(sessionID, _):
            sessionID
```

- [ ] **Step 11: Update `SessionEvent.description`**

Add cases:

```swift
        case let .sessionLaunching(payload):
            "sessionLaunching(session: \(payload.sessionID.prefix(8)), name: \(payload.sessionName))"
        case let .launchProgressUpdated(sessionID, progress):
            "launchProgressUpdated(session: \(sessionID.prefix(8)), progress: \(progress))"
        case let .launchCompleted(sessionID):
            "launchCompleted(session: \(sessionID.prefix(8)))"
        case let .launchFailed(sessionID, error):
            "launchFailed(session: \(sessionID.prefix(8)), error: \(error))"
```

- [ ] **Step 12: Add `tmuxSessionName` to SessionState**

Add after `var isInTmux: Bool`:

```swift
    var tmuxSessionName: String?
```

Also add it to the `init` with default `nil`:

```swift
    tmuxSessionName: String? = nil,
```

And in the init body:

```swift
    self.tmuxSessionName = tmuxSessionName
```

- [ ] **Step 13: Build and verify**

Run: `xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -5`
Expected: Build Succeeded (all exhaustive switches now have `.launching` cases)

- [ ] **Step 14: Commit**

```bash
git add ClaudeIsland/Models/SessionPhase.swift ClaudeIsland/Models/SessionEvent.swift ClaudeIsland/Models/SessionState.swift
git commit -m "feat: add .launching phase, launch events, and tmuxSessionName to state machine"
```

---

## Task 2: Settings Keys for Chunks 1 & 4

**Goal:** Add all new UserDefaults keys needed by Chunks 1 and 4 to `Settings.swift`.

**Files:**
- Modify: `ClaudeIsland/Core/Settings.swift`

**Acceptance Criteria:**
- [ ] `claudeCommandTemplate` key with String default `"claude"`
- [ ] `lastUsedDirectory` key with optional String
- [ ] `chatPanelWidthFraction` key with Double default `0.5` (guarded for zero)
- [ ] All follow existing patterns in Settings.swift

**Verify:** `xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -5` -> Build Succeeded

**Steps:**

- [ ] **Step 1: Add keys to private Keys enum**

Add after `static let verboseMode`:

```swift
        static let claudeCommandTemplate = "claudeCommandTemplate"
        static let lastUsedDirectory = "lastUsedDirectory"
        static let chatPanelWidthFraction = "chatPanelWidthFraction"
```

- [ ] **Step 2: Add computed properties**

Add after `verboseMode` property, before the `private` section:

```swift
    // MARK: - Claude Command Template

    static var claudeCommandTemplate: String {
        get { defaults.string(forKey: Keys.claudeCommandTemplate) ?? "claude" }
        set { defaults.set(newValue, forKey: Keys.claudeCommandTemplate) }
    }

    // MARK: - Last Used Directory

    static var lastUsedDirectory: String? {
        get { defaults.string(forKey: Keys.lastUsedDirectory) }
        set { defaults.set(newValue, forKey: Keys.lastUsedDirectory) }
    }

    // MARK: - Chat Panel Width

    static var chatPanelWidthFraction: Double {
        get {
            let value = defaults.double(forKey: Keys.chatPanelWidthFraction)
            return value > 0 ? value : 0.5
        }
        set { defaults.set(newValue, forKey: Keys.chatPanelWidthFraction) }
    }
```

- [ ] **Step 3: Build and commit**

```bash
xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -5
git add ClaudeIsland/Core/Settings.swift
git commit -m "feat: add settings keys for launcher, directory, and panel width"
```

---

## Task 3: SessionStore Launch Event Handling + Pending Launch Merge

**Goal:** Wire the 4 launch events into `SessionStore.process()`, manage `pendingLaunches` dictionary, and implement the async TmuxTargetFinder merge when hooks arrive.

**Files:**
- Modify: `ClaudeIsland/Services/State/SessionStore.swift`

**Acceptance Criteria:**
- [ ] `pendingLaunches: [String: String]` dictionary (tmux session name -> provisional sessionID)
- [ ] `process()` handles all 4 launch event cases
- [ ] `processHookEvent` performs async `TmuxTargetFinder` lookup when `pendingLaunches` is non-empty
- [ ] Actor reentrancy guard: verifies provisional session still exists after `await`
- [ ] `processSessionEnd` also cleans up `pendingLaunches`
- [ ] Provisional session uses `stableID` copy during merge for SwiftUI identity

**Verify:** `xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -5` -> Build Succeeded

**Steps:**

- [ ] **Step 1: Add `pendingLaunches` dictionary**

Add after `var sessions: [String: SessionState] = [:]` (line 41):

```swift
    /// Maps tmux session name to provisional session ID for launch merge
    var pendingLaunches: [String: String] = [:]
```

- [ ] **Step 2: Add launch event cases to `process()`**

Add after the `.subagentStopped` case (around line 129), before the closing `}` of the switch:

```swift
        // MARK: - Launch Events

        case let .sessionLaunching(payload):
            self.processSessionLaunching(payload)

        case let .launchProgressUpdated(sessionID, progress):
            self.processLaunchProgressUpdated(sessionID: sessionID, progress: progress)

        case let .launchCompleted(sessionID):
            self.processLaunchCompleted(sessionID: sessionID)

        case let .launchFailed(sessionID, error):
            self.processLaunchFailed(sessionID: sessionID, error: error)
```

- [ ] **Step 3: Implement the 4 launch event handlers**

Add a new MARK section after `processSessionEnd`:

```swift
    // MARK: - Launch Event Processing

    private func processSessionLaunching(_ payload: SessionLaunchPayload) {
        let session = SessionState(
            sessionID: payload.sessionID,
            cwd: payload.cwd,
            projectName: URL(fileURLWithPath: payload.cwd).lastPathComponent,
            tmuxSessionName: payload.sessionName,
            phase: .launching(.creatingTmuxSession),
        )
        self.sessions[payload.sessionID] = session
        self.pendingLaunches[payload.sessionName] = payload.sessionID
    }

    private func processLaunchProgressUpdated(sessionID: String, progress: LaunchProgress) {
        guard var session = sessions[sessionID] else { return }
        session.phase = .launching(progress)
        session.lastActivity = Date()
        self.sessions[sessionID] = session
    }

    private func processLaunchCompleted(sessionID: String) {
        guard var session = sessions[sessionID] else { return }
        if case .launching = session.phase {
            session.phase = .idle
            session.lastActivity = Date()
            self.sessions[sessionID] = session
        }
    }

    private func processLaunchFailed(sessionID: String, error: LaunchError) {
        guard var session = sessions[sessionID] else { return }
        session.phase = .launching(.failed(error))
        session.lastActivity = Date()
        self.sessions[sessionID] = session
        // Clean up pending launch
        if let tmuxName = session.tmuxSessionName {
            self.pendingLaunches.removeValue(forKey: tmuxName)
        }
    }
```

- [ ] **Step 4: Add merge logic to `processHookEvent`**

After the line `if event.status == "ended"` block (around line 322-326), add pending launch merge logic. Replace the existing `if event.status == "ended"` block and the code that follows up to `self.sessions[sessionID] = session` with logic that checks for pending launches.

Before the line `let newPhase = event.determinePhase()` (line 328), insert:

```swift
        // Merge pending launch if this is a new session matching a pending launch
        if !self.pendingLaunches.isEmpty, self.sessions[sessionID] == nil {
            await self.attemptLaunchMerge(hookEvent: event)
        }
```

Add the merge method:

```swift
    private func attemptLaunchMerge(hookEvent: HookEvent) async {
        guard let pid = hookEvent.pid else { return }

        let target = await TmuxTargetFinder.shared.findTarget(forClaudePID: pid)
        guard let tmuxSessionName = target?.session else { return }

        // Actor reentrancy guard: verify pending launch still exists after await
        guard let provisionalID = pendingLaunches[tmuxSessionName] else { return }
        guard let provisionalSession = sessions[provisionalID] else {
            self.pendingLaunches.removeValue(forKey: tmuxSessionName)
            return
        }

        // Verify cwd matches as corroborating signal
        guard hookEvent.cwd == provisionalSession.cwd else { return }

        // Remove provisional session
        self.sessions.removeValue(forKey: provisionalID)
        self.pendingLaunches.removeValue(forKey: tmuxSessionName)

        // Create real session using hook's sessionID but keeping display context
        var realSession = SessionState(
            sessionID: hookEvent.sessionID,
            cwd: hookEvent.cwd,
            projectName: provisionalSession.projectName,
            pid: hookEvent.pid,
            tty: hookEvent.tty?.replacingOccurrences(of: "/dev/", with: ""),
            tmuxSessionName: tmuxSessionName,
            phase: .idle,
        )
        realSession.isInTmux = true
        self.sessions[hookEvent.sessionID] = realSession
    }
```

- [ ] **Step 5: Clean up pendingLaunches in processSessionEnd**

Update `processSessionEnd` (line 909-912):

```swift
    private func processSessionEnd(sessionID: String) async {
        if let session = sessions[sessionID], let tmuxName = session.tmuxSessionName {
            self.pendingLaunches.removeValue(forKey: tmuxName)
        }
        self.sessions.removeValue(forKey: sessionID)
        self.cancelPendingSync(sessionID: sessionID)
    }
```

- [ ] **Step 6: Build and commit**

```bash
xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -5
git add ClaudeIsland/Services/State/SessionStore.swift
git commit -m "feat: handle launch events and pending launch merge in SessionStore"
```

---

## Task 4: TmuxSessionCreator Service

**Goal:** Create the actor that orchestrates tmux session creation + Claude launch + hook waiting.

**Files:**
- Create: `ClaudeIsland/Services/Tmux/TmuxSessionCreator.swift`

**Acceptance Criteria:**
- [ ] Actor with `launch(prompt:sessionName:directory:commandTemplate:)` method
- [ ] Validates tmux and claude binaries via existing `TmuxPathFinder` and `CLIVersionDetector.findClaudeBinary` pattern
- [ ] Sanitizes session name (lowercase, hyphens, no dots/colons, collision check, 50-char max)
- [ ] Creates detached tmux session, sends claude command, waits for hook with 15s timeout
- [ ] Sends progress events to SessionStore at each step
- [ ] Sends prompt after hook fires and Claude is ready

**Verify:** `xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -5` -> Build Succeeded

**Steps:**

- [ ] **Step 1: Create TmuxSessionCreator.swift**

```swift
//
//  TmuxSessionCreator.swift
//  ClaudeIsland
//
//  Orchestrates tmux session creation and Claude Code launch
//

import Foundation
import os

actor TmuxSessionCreator {
    // MARK: Lifecycle

    private init() {}

    // MARK: Internal

    static let shared = TmuxSessionCreator()

    func launch(
        prompt: String,
        sessionName: String,
        directory: String,
        commandTemplate: String,
    ) async throws(LaunchError) {
        // Step 1: Validate prerequisites
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else {
            throw .tmuxNotInstalled
        }

        let claudePath = await self.findClaudeBinary()
        guard claudePath != nil else {
            throw .claudeNotInstalled
        }

        guard FileManager.default.fileExists(atPath: directory) else {
            throw .directoryNotFound(directory)
        }

        // Step 2: Resolve session name
        let resolvedName = await self.resolveSessionName(sessionName, tmuxPath: tmuxPath)

        // Create provisional session
        let provisionalID = UUID().uuidString
        let payload = SessionLaunchPayload(
            sessionID: provisionalID,
            sessionName: resolvedName,
            cwd: directory,
            prompt: prompt,
            commandTemplate: commandTemplate,
        )
        await SessionStore.shared.process(.sessionLaunching(payload))

        // Step 3: Create tmux session
        await SessionStore.shared.process(.launchProgressUpdated(
            sessionID: provisionalID,
            progress: .creatingTmuxSession,
        ))

        do {
            _ = try await ProcessExecutor.shared.run(tmuxPath, arguments: [
                "new-session", "-d", "-s", resolvedName, "-c", directory,
            ])
        } catch {
            await SessionStore.shared.process(.launchFailed(
                sessionID: provisionalID,
                error: .tmuxSessionCreationFailed(error.localizedDescription),
            ))
            throw .tmuxSessionCreationFailed(error.localizedDescription)
        }

        // Step 4: Send claude command
        await SessionStore.shared.process(.launchProgressUpdated(
            sessionID: provisionalID,
            progress: .startingClaude,
        ))

        let resolvedCommand = self.resolveTemplate(
            commandTemplate,
            name: resolvedName,
            directory: directory,
        )

        do {
            _ = try await ProcessExecutor.shared.run(tmuxPath, arguments: [
                "send-keys", "-t", resolvedName, "-l", resolvedCommand,
            ])
            _ = try await ProcessExecutor.shared.run(tmuxPath, arguments: [
                "send-keys", "-t", resolvedName, "Enter",
            ])
        } catch {
            await SessionStore.shared.process(.launchFailed(
                sessionID: provisionalID,
                error: .promptSendFailed(error.localizedDescription),
            ))
            throw .promptSendFailed(error.localizedDescription)
        }

        // Step 5: Wait for hook
        await SessionStore.shared.process(.launchProgressUpdated(
            sessionID: provisionalID,
            progress: .waitingForHook,
        ))

        let hookReceived = await self.waitForHookMerge(provisionalID: provisionalID, timeout: 15.0)

        guard hookReceived else {
            await SessionStore.shared.process(.launchFailed(
                sessionID: provisionalID,
                error: .claudeStartTimeout,
            ))
            throw .claudeStartTimeout
        }

        // Step 6: Send prompt
        await SessionStore.shared.process(.launchProgressUpdated(
            sessionID: provisionalID,
            progress: .sendingPrompt,
        ))

        try? await Task.sleep(for: .milliseconds(200))

        if !prompt.isEmpty {
            do {
                _ = try await ProcessExecutor.shared.run(tmuxPath, arguments: [
                    "send-keys", "-t", resolvedName, "-l", prompt,
                ])
                _ = try await ProcessExecutor.shared.run(tmuxPath, arguments: [
                    "send-keys", "-t", resolvedName, "Enter",
                ])
            } catch {
                Self.logger.warning("Failed to send prompt: \(error.localizedDescription, privacy: .public)")
            }
        }

        AppSettings.lastUsedDirectory = directory
    }

    func cancelLaunch(sessionName: String) async {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else { return }
        _ = try? await ProcessExecutor.shared.run(tmuxPath, arguments: [
            "kill-session", "-t", sessionName,
        ])
    }

    // MARK: Private

    nonisolated private static let logger = Logger(
        subsystem: "com.engels74.ClaudeIsland",
        category: "TmuxSessionCreator",
    )

    private func findClaudeBinary() async -> String? {
        let claudeBinPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/bin/claude").path

        let knownPaths = [
            "/usr/local/bin/claude",
            claudeBinPath,
        ]

        for path in knownPaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        let result = await ProcessExecutor.shared.runWithResult("/usr/bin/which", arguments: ["claude"])
        if case let .success(processResult) = result, processResult.isSuccess {
            let path = processResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        return nil
    }

    private func resolveSessionName(_ name: String, tmuxPath: String) async -> String {
        var sanitized = name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }

        if sanitized.isEmpty {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd-HHmm"
            sanitized = "claude-\(formatter.string(from: Date()))"
        }

        sanitized = String(sanitized.prefix(50))

        var candidate = sanitized
        var counter = 2
        while await self.tmuxSessionExists(candidate, tmuxPath: tmuxPath) {
            candidate = "\(String(sanitized.prefix(46)))-\(counter)"
            counter += 1
        }

        return candidate
    }

    private func tmuxSessionExists(_ name: String, tmuxPath: String) async -> Bool {
        let result = await ProcessExecutor.shared.runWithResult(tmuxPath, arguments: [
            "has-session", "-t", name,
        ])
        if case let .success(processResult) = result {
            return processResult.exitCode == 0
        }
        return false
    }

    private func resolveTemplate(_ template: String, name: String, directory: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dateStr = formatter.string(from: Date())

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH-mm"
        let timeStr = timeFormatter.string(from: Date())

        return template
            .replacingOccurrences(of: "{{name}}", with: name)
            .replacingOccurrences(of: "{{date}}", with: dateStr)
            .replacingOccurrences(of: "{{time}}", with: timeStr)
            .replacingOccurrences(of: "{{dir}}", with: directory)
    }

    private func waitForHookMerge(provisionalID: String, timeout: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let session = await SessionStore.shared.session(for: provisionalID)
            if session == nil {
                return true
            }
            if let session, case let .launching(progress) = session.phase {
                if case .failed = progress { return false }
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }
}
```

- [ ] **Step 2: Build and commit**

```bash
xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -5
git add ClaudeIsland/Services/Tmux/TmuxSessionCreator.swift
git commit -m "feat: add TmuxSessionCreator actor for session launch orchestration"
```

---

## Task 5: SessionLauncherPanel (NSPanel)

**Goal:** Create the floating NSPanel that hosts the launcher SwiftUI view, with frosted glass appearance and dismiss behavior.

**Files:**
- Create: `ClaudeIsland/UI/Windows/SessionLauncherPanel.swift`

**Acceptance Criteria:**
- [ ] NSPanel subclass with borderless, non-activating, floating behavior
- [ ] Window level `.mainMenu + 4` (above notch at `.mainMenu + 3`)
- [ ] NSVisualEffectView with `.hudWindow` material as contentView
- [ ] 16px corner radius, centered on notch screen
- [ ] Escape key and click-outside dismiss
- [ ] Event monitors removed on dismiss
- [ ] Scale + fade animation on show/dismiss

**Verify:** `xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -5` -> Build Succeeded

**Steps:**

- [ ] **Step 1: Create SessionLauncherPanel.swift**

```swift
//
//  SessionLauncherPanel.swift
//  ClaudeIsland
//
//  Floating panel for the session launcher
//

import AppKit
import SwiftUI

final class SessionLauncherPanel: NSPanel {
    // MARK: Lifecycle

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true,
        )

        self.isFloatingPanel = true
        self.level = .mainMenu + 4
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.hidesOnDeactivate = false
        self.isMovableByWindowBackground = false

        let visualEffect = NSVisualEffectView()
        visualEffect.material = .hudWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 16
        visualEffect.layer?.masksToBounds = true

        self.contentView = visualEffect
        self.visualEffectView = visualEffect
    }

    // MARK: Internal

    static let shared = SessionLauncherPanel()

    weak var viewModel: NotchViewModel?

    func show() {
        guard !self.isVisible else { return }

        self.updateHostingView()
        self.centerOnNotchScreen()
        self.alphaValue = 0

        self.makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1
        }

        self.installMonitors()
    }

    func dismiss() {
        self.removeMonitors()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        }, completionHandler: {
            self.orderOut(nil)
        })
    }

    override func cancelOperation(_: Any?) {
        self.dismiss()
    }

    // MARK: Private

    private var visualEffectView: NSVisualEffectView?
    private var localMonitor: Any?
    private var globalMonitor: Any?

    private func updateHostingView() {
        guard let visualEffectView else { return }

        visualEffectView.subviews.forEach { $0.removeFromSuperview() }

        let launcherView = SessionLauncherView(
            onSubmit: { [weak self] prompt, name, directory in
                self?.handleSubmit(prompt: prompt, sessionName: name, directory: directory)
            },
            onDismiss: { [weak self] in
                self?.dismiss()
            },
        )

        let hostingView = NSHostingView(rootView: launcherView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor),
        ])
    }

    private func centerOnNotchScreen() {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let panelSize = self.frame.size
        let x = screenFrame.midX - panelSize.width / 2
        let y = screenFrame.midY - panelSize.height / 2 + 50
        self.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func installMonitors() {
        self.localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.dismiss()
                return nil
            }
            return event
        }

        self.globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, self.isVisible else { return }
            let location = event.locationInWindow
            if !self.frame.contains(NSEvent.mouseLocation) {
                self.dismiss()
            }
        }
    }

    private func removeMonitors() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
    }

    private func handleSubmit(prompt: String, sessionName: String, directory: String) {
        self.dismiss()

        self.viewModel?.notchOpen(reason: .notification)
        self.viewModel?.contentType = .instances

        Task(name: "launch-session") {
            do {
                try await TmuxSessionCreator.shared.launch(
                    prompt: prompt,
                    sessionName: sessionName,
                    directory: directory,
                    commandTemplate: AppSettings.claudeCommandTemplate,
                )
            } catch {
                SessionLauncherPanel.logger.error("Launch failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    nonisolated private static let logger = Logger(
        subsystem: "com.engels74.ClaudeIsland",
        category: "SessionLauncherPanel",
    )
}

import os
```

- [ ] **Step 2: Build and commit**

```bash
xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -5
git add ClaudeIsland/UI/Windows/SessionLauncherPanel.swift
git commit -m "feat: add SessionLauncherPanel floating NSPanel with dismiss behavior"
```

---

## Task 6: SessionLauncherView (SwiftUI)

**Goal:** Create the SwiftUI launcher content with prompt field, session name field, minimal directory picker, and command preview.

**Files:**
- Create: `ClaudeIsland/UI/Views/SessionLauncherView.swift`

**Acceptance Criteria:**
- [ ] Auto-focused multiline prompt field (Enter submits, Shift+Enter newline)
- [ ] Tab reveals session name field with slide animation
- [ ] Minimal directory picker (last used, home, Browse...)
- [ ] Live command preview in bottom bar
- [ ] Auto-generates session name from prompt if empty
- [ ] Calls `onSubmit` with prompt, name, and directory

**Verify:** `xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -5` -> Build Succeeded

**Steps:**

- [ ] **Step 1: Create SessionLauncherView.swift**

Write the full SwiftUI view with prompt field, name field (hidden by default, revealed on Tab), directory picker with last-used/home/Browse options, and bottom bar showing the resolved command. Follow the spec's keyboard flow: prompt -> Tab -> name -> Tab -> directory -> Enter submits. The `onSubmit` closure receives `(prompt: String, sessionName: String, directory: String)`. Auto-generate session name from first 30 chars of prompt if left empty. Use `@FocusState` for auto-focus on appear.

The view needs these properties:
```swift
let onSubmit: (String, String, String) -> Void
let onDismiss: () -> Void
@State private var prompt = ""
@State private var sessionName = ""
@State private var selectedDirectory: String = AppSettings.lastUsedDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path
@State private var showNameField = false
@FocusState private var focusedField: Field?

private enum Field { case prompt, name, directory }
```

Use `TextEditor` for multiline prompt with min height ~40px growing to ~120px. The name field is a single-line `TextField`. Directory picker shows a `VStack` of selectable rows. Bottom bar shows resolved command in monospace.

- [ ] **Step 2: Build and commit**

```bash
xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -5
git add ClaudeIsland/UI/Views/SessionLauncherView.swift
git commit -m "feat: add SessionLauncherView with prompt, name, and directory picker"
```

---

## Task 7: NewSessionRow + ClaudeInstancesView Updates

**Goal:** Add the dashed "New Session" row to the instances list and handle `.launching` phase rendering in InstanceRow.

**Files:**
- Create: `ClaudeIsland/UI/Views/NewSessionRow.swift`
- Modify: `ClaudeIsland/UI/Views/ClaudeInstancesView.swift`

**Acceptance Criteria:**
- [ ] Dashed row at bottom of instances list with `+` icon and "New Session" text
- [ ] Replaces `emptyState` when list is empty
- [ ] Header `+` button near top of `ClaudeInstancesView`
- [ ] `.launching` case in `phasePriority` (priority 0)
- [ ] `.launching` case in `InstanceRow.phaseStatusText`
- [ ] `.launching` case in `InstanceRow.stateIndicator` (pulsing ring)
- [ ] Cancel button for launching state, Retry/Dismiss for failed state

**Verify:** `xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -5` -> Build Succeeded

**Steps:**

- [ ] **Step 1: Create NewSessionRow.swift**

```swift
//
//  NewSessionRow.swift
//  ClaudeIsland
//
//  Dashed "New Session" row for the instances list
//

import SwiftUI

struct NewSessionRow: View {
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: self.onTap) {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
                    .frame(width: 14)

                Text("New Session")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        Color.white.opacity(self.isHovered ? 0.4 : 0.2),
                        style: StrokeStyle(lineWidth: 1, dash: [6, 4]),
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(self.isHovered ? Color.white.opacity(0.04) : Color.clear),
                    ),
            )
        }
        .buttonStyle(.plain)
        .onHover { self.isHovered = $0 }
    }
}
```

- [ ] **Step 2: Update ClaudeInstancesView**

Replace `emptyState` (lines 54-65) to show `NewSessionRow` instead:

```swift
    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            NewSessionRow { self.showLauncher() }
                .padding(.horizontal, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
```

Add `NewSessionRow` after the `ForEach` in `instancesList` (after line 81):

```swift
                NewSessionRow { self.showLauncher() }
```

Add header `+` button — modify `instancesList` to wrap in a `VStack`:

Add `+` button as an `HStack` above the `ScrollView`.

Add `showLauncher()` method:

```swift
    private func showLauncher() {
        SessionLauncherPanel.shared.show()
    }
```

- [ ] **Step 3: Add `.launching` to phasePriority**

```swift
        case .launching: 0
```

- [ ] **Step 4: Add `.launching` to phaseStatusText in InstanceRow**

```swift
        case let .launching(progress):
            switch progress {
            case .creatingTmuxSession: "Creating session..."
            case .startingClaude: "Starting Claude..."
            case .waitingForHook: "Waiting for connection..."
            case .sendingPrompt: "Sending prompt..."
            case let .failed(error): "Failed: \(error.localizedDescription)"
            }
```

- [ ] **Step 5: Add `.launching` to stateIndicator in InstanceRow**

Add a pulsing blue ring:

```swift
        case .launching:
            Circle()
                .stroke(Color(red: 0.04, green: 0.52, blue: 1.0), lineWidth: 2)
                .frame(width: 8, height: 8)
                .opacity(self.launchPulseOpacity)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: self.launchPulseOpacity)
                .onAppear { self.launchPulseOpacity = 0.4 }
```

Add `@State private var launchPulseOpacity: Double = 1.0` to InstanceRow.

- [ ] **Step 6: Add launching-state action buttons in InstanceRow**

In the `mainRow` action buttons area (around lines 316-342), add a `.launching` check before the existing `else` block:

```swift
                } else if case let .launching(progress) = self.session.phase {
                    if case .failed = progress {
                        HStack(spacing: 8) {
                            Button {
                                self.onRetry?()
                            } label: {
                                Text("Retry")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.white.opacity(0.8))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.white.opacity(0.1))
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)

                            Button {
                                self.onDismiss?()
                            } label: {
                                Text("Dismiss")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.white.opacity(0.5))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        Button {
                            self.onCancel?()
                        } label: {
                            Text("Cancel")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                    }
```

Add optional callbacks to InstanceRow:

```swift
    var onCancel: (() -> Void)?
    var onRetry: (() -> Void)?
    var onDismiss: (() -> Void)?
```

- [ ] **Step 7: Build and commit**

```bash
xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -5
git add ClaudeIsland/UI/Views/NewSessionRow.swift ClaudeIsland/UI/Views/ClaudeInstancesView.swift
git commit -m "feat: add NewSessionRow, launching phase rendering, and cancel/retry actions"
```

---

## Task 8: NotchMenuView Claude Command + NotchViewModel Updates

**Goal:** Add the Claude Command expandable setting to the menu and update NotchViewModel for launcher integration.

**Files:**
- Modify: `ClaudeIsland/UI/Views/NotchMenuView.swift`
- Modify: `ClaudeIsland/Core/NotchViewModel.swift`
- Modify: `ClaudeIsland/App/AppDelegate.swift`

**Acceptance Criteria:**
- [ ] "Claude Command" expandable row in NotchMenuView after Hooks toggle
- [ ] Text field with command template, following TokenTrackingRow expansion pattern
- [ ] `.sessionCreated` added to `NotchOpenReason`
- [ ] `openedSize` for `.menu` accounts for command section height
- [ ] AppDelegate creates `SessionLauncherPanel` and wires viewModel reference

**Verify:** `xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -5` -> Build Succeeded

**Steps:**

- [ ] **Step 1: Add `.sessionCreated` to NotchOpenReason**

In `NotchViewModel.swift`, add to enum:

```swift
    case sessionCreated
```

- [ ] **Step 2: Add Claude Command expandable row to NotchMenuView**

Add after the Hooks toggle row (around line 133), before `AccessibilityRow`:

```swift
                        ClaudeCommandRow()
```

Create the `ClaudeCommandRow` struct following `TokenTrackingRow` pattern (expand/collapse with chevron, text field inside):

```swift
struct ClaudeCommandRow: View {
    @State private var isExpanded = false
    @State private var isHovered = false
    @State private var commandTemplate: String = AppSettings.claudeCommandTemplate

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    self.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "terminal")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(self.isHovered || self.isExpanded ? 1.0 : 0.7))
                        .frame(width: 16)

                    Text("Claude Command")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(self.isHovered || self.isExpanded ? 1.0 : 0.7))

                    Spacer()

                    Image(systemName: self.isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.4))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(self.isHovered || self.isExpanded ? Color.white.opacity(0.08) : Color.clear),
                )
            }
            .buttonStyle(.plain)
            .onHover { self.isHovered = $0 }

            if self.isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("claude", text: self.$commandTemplate)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .onSubmit {
                            AppSettings.claudeCommandTemplate = self.commandTemplate
                        }
                        .onChange(of: self.commandTemplate) { _, newValue in
                            if !newValue.hasPrefix("claude") {
                                self.commandTemplate = "claude"
                            }
                            AppSettings.claudeCommandTemplate = self.commandTemplate
                        }

                    Text("Variables: {{name}}, {{date}}, {{time}}, {{dir}}")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                }
                .padding(.leading, 28)
                .padding(.trailing, 28)
                .padding(.vertical, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}
```

- [ ] **Step 3: Wire SessionLauncherPanel in AppDelegate**

In `AppDelegate.swift`, after the NotchWindowController setup, add:

```swift
SessionLauncherPanel.shared.viewModel = self.viewModel
```

- [ ] **Step 4: Build and commit**

```bash
xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -5
git add ClaudeIsland/UI/Views/NotchMenuView.swift ClaudeIsland/Core/NotchViewModel.swift ClaudeIsland/App/AppDelegate.swift
git commit -m "feat: add Claude Command settings, sessionCreated reason, launcher panel wiring"
```

---

## REVIEW CHECKPOINT: Chunk 1 Complete

**At this point, pause and review.** All Chunk 1 tasks (Tasks 1-8) should be complete. Verify:
1. The app builds cleanly
2. The launcher panel opens when clicking "New Session"
3. A tmux session is created and Claude starts
4. The session appears in the list with launching progress
5. After hook fires, the session transitions to normal state

---

## Task 9: Chat View Improvements — Configurable Panel Width

**Goal:** Add a panel width slider to settings and wire it to NotchViewModel's `openedSize`.

**Files:**
- Modify: `ClaudeIsland/Core/NotchViewModel.swift`
- Modify: `ClaudeIsland/UI/Views/NotchMenuView.swift`

**Acceptance Criteria:**
- [ ] `chatPanelWidthFraction` stored property on NotchViewModel (loaded from AppSettings on init)
- [ ] `.chat` case in `openedSize` uses the fraction instead of hardcoded `0.5`
- [ ] Slider in NotchMenuView (0.5 to 0.8 range) after "Notch Layout" row
- [ ] Slider writes to both NotchViewModel and AppSettings

**Verify:** `xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -5` -> Build Succeeded

**Steps:**

- [ ] **Step 1: Add `chatPanelWidthFraction` to NotchViewModel**

Add stored property:

```swift
    var chatPanelWidthFraction: Double = AppSettings.chatPanelWidthFraction
```

Update the `.chat` case in `openedSize`:

```swift
        case .chat:
            return CGSize(
                width: min(self.screenRect.width * self.chatPanelWidthFraction, self.screenRect.width * 0.8),
                height: 580,
            )
```

- [ ] **Step 2: Add Panel Width slider to NotchMenuView**

Add after "Notch Layout" row (line ~72), before the Divider:

```swift
                        PanelWidthRow(viewModel: self.viewModel)
```

Create the row:

```swift
struct PanelWidthRow: View {
    var viewModel: NotchViewModel

    @State private var isExpanded = false
    @State private var isHovered = false
    @State private var widthFraction: Double = AppSettings.chatPanelWidthFraction

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    self.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.left.and.right")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(self.isHovered || self.isExpanded ? 1.0 : 0.7))
                        .frame(width: 16)

                    Text("Panel Width")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(self.isHovered || self.isExpanded ? 1.0 : 0.7))

                    Spacer()

                    Text("\(Int(self.widthFraction * 100))%")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))

                    Image(systemName: self.isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.4))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(self.isHovered || self.isExpanded ? Color.white.opacity(0.08) : Color.clear),
                )
            }
            .buttonStyle(.plain)
            .onHover { self.isHovered = $0 }

            if self.isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    Slider(value: self.$widthFraction, in: 0.5 ... 0.8, step: 0.05)
                        .tint(.white.opacity(0.5))
                        .onChange(of: self.widthFraction) { _, newValue in
                            self.viewModel.chatPanelWidthFraction = newValue
                            AppSettings.chatPanelWidthFraction = newValue
                        }

                    HStack {
                        Text("50%")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.3))
                        Spacer()
                        Text("80%")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.3))
                    }
                }
                .padding(.leading, 28)
                .padding(.trailing, 28)
                .padding(.vertical, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}
```

- [ ] **Step 3: Build and commit**

```bash
xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -5
git add ClaudeIsland/Core/NotchViewModel.swift ClaudeIsland/UI/Views/NotchMenuView.swift
git commit -m "feat: add configurable chat panel width with slider (50-80%)"
```

---

## Task 10: Markdown Renderer Enhancements

**Goal:** Add task list checkboxes, code block language labels with copy buttons, table rendering, and tighter spacing.

**Files:**
- Modify: `ClaudeIsland/UI/Components/MarkdownRenderer.swift`
- Modify: `ClaudeIsland/UI/Views/ChatView.swift`

**Acceptance Criteria:**
- [ ] Task list items render with checkbox icons (square/checkmark.square.fill)
- [ ] Code blocks show language label header + copy button when language is present
- [ ] `.parseTable` added to parsing options
- [ ] Tables render using SwiftUI Grid with horizontal scroll
- [ ] Block spacing reduced from 12 to 8, line spacing from 4 to 2
- [ ] ChatView LazyVStack spacing reduced from 16 to 12
- [ ] Message text capped at 700px maxWidth (code/tables exempt)

**Verify:** `xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -5` -> Build Succeeded

**Steps:**

- [ ] **Step 1: Add `.parseTable` to parsing options**

In `DocumentCache.document(for:)` (line 25), change:

```swift
let doc = Document(parsing: text, options: [.parseBlockDirectives, .parseSymbolLinks, .parseTable])
```

- [ ] **Step 2: Reduce spacing in MarkdownText**

Change `VStack(alignment: .leading, spacing: 12)` (line 67) to:

```swift
VStack(alignment: .leading, spacing: 8)
```

Change `.lineSpacing(4)` (line 98) to:

```swift
.lineSpacing(2)
```

- [ ] **Step 3: Add task list checkbox handling to unorderedListView**

Replace the bullet rendering in `unorderedListView` (lines 148-169). For each `item`, check `item.checkbox`:

```swift
    private func unorderedListView(_ list: UnorderedList) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(list.listItems.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 6) {
                    if let checkbox = item.checkbox {
                        Image(systemName: checkbox == .checked ? "checkmark.square.fill" : "square")
                            .font(.system(size: self.fontSize - 1))
                            .foregroundColor(checkbox == .checked ? Color.green.opacity(0.8) : self.baseColor.opacity(0.5))
                            .frame(width: 12, alignment: .center)
                    } else {
                        SwiftUI.Text("\u{2022}")
                            .font(.system(size: self.fontSize))
                            .foregroundColor(self.baseColor.opacity(0.6))
                            .frame(width: 12, alignment: .center)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(item.children.enumerated()), id: \.offset) { _, child in
                            if let para = child as? Paragraph {
                                InlineRenderer(children: Array(para.inlineChildren), baseColor: self.baseColor, fontSize: self.fontSize)
                            } else {
                                Self(markup: child, baseColor: self.baseColor, fontSize: self.fontSize)
                            }
                        }
                    }
                }
            }
        }
    }
```

- [ ] **Step 4: Update CodeBlockView with language header + copy button**

Replace the existing `CodeBlockView` (lines 267-281):

```swift
private struct CodeBlockView: View {
    let code: String
    let language: String?

    @State private var showCopied = false

    var body: some View {
        VStack(spacing: 0) {
            if let language, !language.isEmpty {
                HStack {
                    SwiftUI.Text(language)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))

                    Spacer()

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(self.code, forType: .string)
                        self.showCopied = true
                        Task(name: "copy-feedback") {
                            try? await Task.sleep(for: .seconds(1.5))
                            self.showCopied = false
                        }
                    } label: {
                        Image(systemName: self.showCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.12))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                SwiftUI.Text(self.code)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
                    .padding(10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.white.opacity(0.08))
        .cornerRadius(6)
    }
}
```

Update the `BlockRenderer` call site (line 103) to pass language:

```swift
        } else if let codeBlock = markup as? CodeBlock {
            CodeBlockView(code: codeBlock.code, language: codeBlock.language)
```

- [ ] **Step 5: Add Table rendering to BlockRenderer**

Add after the `OrderedList` check (line 109), before `ThematicBreak`:

```swift
        } else if let table = markup as? Table {
            self.tableView(table)
```

Add the table rendering method:

```swift
    private func tableView(_ table: Table) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                if let head = table.head {
                    GridRow {
                        ForEach(Array(head.cells.enumerated()), id: \.offset) { _, cell in
                            InlineRenderer(
                                children: Array(cell.inlineChildren),
                                baseColor: self.baseColor,
                                fontSize: self.fontSize,
                            )
                            .asText()
                            .bold()
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white.opacity(0.12))
                        }
                    }
                }

                if let body = table.body {
                    ForEach(Array(body.rows.enumerated()), id: \.offset) { rowIndex, row in
                        GridRow {
                            ForEach(Array(row.cells.enumerated()), id: \.offset) { _, cell in
                                InlineRenderer(
                                    children: Array(cell.inlineChildren),
                                    baseColor: self.baseColor,
                                    fontSize: self.fontSize,
                                )
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(rowIndex % 2 == 0 ? Color.white.opacity(0.04) : Color.clear)
                            }
                        }
                    }
                }
            }
            .fixedSize()
        }
        .background(Color.white.opacity(0.04))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white.opacity(0.15), lineWidth: 0.5),
        )
    }
```

- [ ] **Step 6: Update ChatView spacing and maxWidth**

In `ChatView.swift`, change `LazyVStack(spacing: 16)` (line 337) to:

```swift
LazyVStack(spacing: 12)
```

Add `.frame(maxWidth: 700, alignment: .leading)` to `AssistantMessageView` and `UserMessageView` text blocks (NOT code blocks or tables). This is applied at the message text level, not the entire message bubble.

- [ ] **Step 7: Build and commit**

```bash
xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -5
git add ClaudeIsland/UI/Components/MarkdownRenderer.swift ClaudeIsland/UI/Views/ChatView.swift
git commit -m "feat: add task lists, code block headers, table rendering, tighter spacing"
```

---

## REVIEW CHECKPOINT: Chunk 4 Complete

**Pause and review.** Tasks 9-10 complete Chunk 4. Verify:
1. Panel width slider works (50-80% range)
2. Task lists render with checkboxes
3. Code blocks show language labels and copy buttons
4. Tables render in a grid with horizontal scroll
5. Spacing is tighter but readable

---

## Task 11: ProjectEntry Model + ProjectStore + Settings Key

**Goal:** Create the project directory management system.

**Files:**
- Create: `ClaudeIsland/Models/ProjectEntry.swift`
- Create: `ClaudeIsland/Services/ProjectStore.swift`
- Modify: `ClaudeIsland/Core/Settings.swift`
- Modify: `ClaudeIsland/Services/Session/ClaudeSessionMonitor.swift`

**Acceptance Criteria:**
- [ ] `ProjectEntry` model with Codable, Identifiable, Sendable, Equatable
- [ ] `ProjectStore` as `@Observable final class` with `static let shared`
- [ ] `pinnedProjects` and `recentProjects` computed properties
- [ ] `recordUsage`, `pin`, `unpin`, `remove`, `addPinned`, `pruneInvalidPaths` methods
- [ ] Auto-pruning: non-pinned entries capped at 20 (oldest by `lastUsedAt` removed)
- [ ] `ClaudeSessionMonitor.handleHookEvent` calls `ProjectStore.recordUsage` on SessionStart
- [ ] `projects` key in Settings.swift using JSONEncoder/JSONDecoder pattern

**Verify:** `xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -5` -> Build Succeeded

**Steps:**

- [ ] **Step 1: Create ProjectEntry.swift**

```swift
//
//  ProjectEntry.swift
//  ClaudeIsland
//
//  Model for a project directory (pinned or recent)
//

import Foundation

struct ProjectEntry: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    let path: String
    var displayName: String
    var lastUsedAt: Date
    var isPinned: Bool
    var pinnedAt: Date?
}
```

- [ ] **Step 2: Create ProjectStore.swift**

```swift
//
//  ProjectStore.swift
//  ClaudeIsland
//
//  Manages pinned and recent project directories
//

import Foundation
import Observation

@Observable
final class ProjectStore {
    // MARK: Lifecycle

    private init() {
        self.entries = AppSettings.projects
        self.pruneInvalidPaths()
    }

    // MARK: Internal

    static let shared = ProjectStore()

    var pinnedProjects: [ProjectEntry] {
        self.entries
            .filter(\.isPinned)
            .sorted { ($0.pinnedAt ?? .distantPast) < ($1.pinnedAt ?? .distantPast) }
    }

    var recentProjects: [ProjectEntry] {
        self.entries
            .filter { !$0.isPinned }
            .sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    func recordUsage(path: String) {
        let normalized = self.normalizePath(path)
        guard !normalized.isEmpty, normalized.hasPrefix("/") else { return }

        if let index = entries.firstIndex(where: { $0.path == normalized }) {
            self.entries[index].lastUsedAt = Date()
        } else {
            let entry = ProjectEntry(
                id: UUID(),
                path: normalized,
                displayName: URL(fileURLWithPath: normalized).lastPathComponent,
                lastUsedAt: Date(),
                isPinned: false,
                pinnedAt: nil,
            )
            self.entries.append(entry)
        }

        self.pruneExcessRecents()
        self.save()
    }

    func pin(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        self.entries[index].isPinned = true
        self.entries[index].pinnedAt = Date()
        self.save()
    }

    func unpin(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        self.entries[index].isPinned = false
        self.entries[index].pinnedAt = nil
        self.save()
    }

    func remove(id: UUID) {
        self.entries.removeAll { $0.id == id }
        self.save()
    }

    func addPinned(path: String) {
        let normalized = self.normalizePath(path)
        guard !normalized.isEmpty, normalized.hasPrefix("/") else { return }
        guard !entries.contains(where: { $0.path == normalized }) else {
            if let index = entries.firstIndex(where: { $0.path == normalized }) {
                self.entries[index].isPinned = true
                self.entries[index].pinnedAt = Date()
                self.save()
            }
            return
        }

        let entry = ProjectEntry(
            id: UUID(),
            path: normalized,
            displayName: URL(fileURLWithPath: normalized).lastPathComponent,
            lastUsedAt: Date(),
            isPinned: true,
            pinnedAt: Date(),
        )
        self.entries.append(entry)
        self.save()
    }

    func pruneInvalidPaths() {
        self.entries.removeAll { entry in
            !entry.isPinned && !FileManager.default.fileExists(atPath: entry.path)
        }
        self.save()
    }

    // MARK: Private

    private var entries: [ProjectEntry] = []

    private func normalizePath(_ path: String) -> String {
        var normalized = path
        while normalized.hasSuffix("/"), normalized.count > 1 {
            normalized.removeLast()
        }
        return normalized
    }

    private func pruneExcessRecents() {
        let recents = self.entries.filter { !$0.isPinned }.sorted { $0.lastUsedAt > $1.lastUsedAt }
        if recents.count > 20, let oldest = recents.last {
            self.entries.removeAll { $0.id == oldest.id }
        }
    }

    private func save() {
        AppSettings.projects = self.entries
    }
}
```

- [ ] **Step 3: Add `projects` key to Settings.swift**

Add key:

```swift
        static let projects = "projects"
```

Add computed property (following `moduleLayoutConfig` pattern):

```swift
    static var projects: [ProjectEntry] {
        get {
            guard let data = defaults.data(forKey: Keys.projects) else { return [] }
            return (try? JSONDecoder().decode([ProjectEntry].self, from: data)) ?? []
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.projects)
            }
        }
    }
```

- [ ] **Step 4: Add recordUsage call to ClaudeSessionMonitor**

In `handleHookEvent` (around line 146), after the `process(.hookReceived(event))` Task, add:

```swift
        if event.event == "SessionStart" {
            ProjectStore.shared.recordUsage(path: event.cwd)
        }
```

- [ ] **Step 5: Build and commit**

```bash
xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -5
git add ClaudeIsland/Models/ProjectEntry.swift ClaudeIsland/Services/ProjectStore.swift ClaudeIsland/Core/Settings.swift ClaudeIsland/Services/Session/ClaudeSessionMonitor.swift
git commit -m "feat: add ProjectEntry model, ProjectStore, and auto-population from sessions"
```

---

## Task 12: Projects Settings View + Directory Picker

**Goal:** Create the projects settings UI in NotchMenuView and the upgraded directory picker for the launcher.

**Files:**
- Create: `ClaudeIsland/UI/Views/ProjectsSettingsView.swift`
- Create: `ClaudeIsland/UI/Views/DirectoryPickerView.swift`
- Modify: `ClaudeIsland/UI/Views/NotchMenuView.swift`
- Modify: `ClaudeIsland/UI/Views/SessionLauncherView.swift`

**Acceptance Criteria:**
- [ ] Expandable "Projects" section in NotchMenuView with pinned/recent lists
- [ ] Hover-to-reveal Unpin/Pin/Remove actions on rows
- [ ] "Add Project..." button with NSOpenPanel
- [ ] DirectoryPickerView as standalone view with `@Binding selectedPath`
- [ ] Keyboard navigation (arrow keys, Enter to select)
- [ ] SessionLauncherView uses DirectoryPickerView

**Verify:** `xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -5` -> Build Succeeded

**Steps:**

- [ ] **Step 1: Create ProjectsSettingsView.swift**

Expandable section following TokenTrackingRow pattern. Pinned section with star icons, recent section with clock icons and relative time (via `SessionPhaseHelpers.timeAgo`). Hover-to-reveal actions. "Add Project..." at bottom.

- [ ] **Step 2: Create DirectoryPickerView.swift**

Standalone view with `@Binding var selectedPath: String`, reads from `ProjectStore.shared`. Shows pinned section, recent section, and "Browse..." row. Arrow key navigation via `@State var highlightedIndex: Int`. Enter to select.

- [ ] **Step 3: Add ProjectsSettingsView to NotchMenuView**

After Hooks row, before AccessibilityRow:

```swift
                        ProjectsSettingsView()
```

- [ ] **Step 4: Replace minimal picker in SessionLauncherView**

Replace the directory picker section with `DirectoryPickerView(selectedPath: self.$selectedDirectory, onSubmit: self.submit)`.

- [ ] **Step 5: Build and commit**

```bash
xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -5
git add ClaudeIsland/UI/Views/ProjectsSettingsView.swift ClaudeIsland/UI/Views/DirectoryPickerView.swift ClaudeIsland/UI/Views/NotchMenuView.swift ClaudeIsland/UI/Views/SessionLauncherView.swift
git commit -m "feat: add Projects settings view and upgraded directory picker"
```

---

## REVIEW CHECKPOINT: Chunk 2 Complete

**Pause and review.** Tasks 11-12 complete Chunk 2. Verify:
1. Projects auto-populate from session starts
2. Projects settings shows pinned/recent with actions
3. "Add Project..." opens NSOpenPanel correctly
4. Launcher directory picker shows pinned and recent projects
5. Arrow key navigation works in directory picker

---

## Task 13: KeyCombo Model + HotkeyManager

**Goal:** Create the global hotkey infrastructure with CGEvent tap.

**Files:**
- Create: `ClaudeIsland/Models/KeyCombo.swift`
- Create: `ClaudeIsland/Services/HotkeyManager.swift`
- Modify: `ClaudeIsland/Core/Settings.swift`

**Acceptance Criteria:**
- [ ] `KeyCombo` with custom Codable (stores modifiers as UInt), display string via UCKeyTranslate
- [ ] `HotkeyManager` with CGEvent tap, deferred start (waits for accessibility)
- [ ] Mutex-protected hotkey dictionary for thread-safe C callback access
- [ ] Tap health check on settings view appear
- [ ] Settings keys for `globalShortcut`, `sessionShortcuts`, `sessionActionOrder`

**Verify:** `xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -5` -> Build Succeeded

**Steps:**

- [ ] **Step 1: Create KeyCombo.swift**

Model with `keyCode: UInt16`, `modifiers: UInt`, computed `displayString` and `modifierFlags`. Custom Codable not needed since all fields are primitive. UCKeyTranslate for key-to-character conversion.

- [ ] **Step 2: Create HotkeyManager.swift**

`@Observable final class` with `static let shared`. CGEvent tap with C callback. `Mutex<[KeyCombo: HotkeyAction]>` for thread-safe dictionary. `startIfPermitted()` checks `AXIsProcessTrusted()`. `register(combo:action:)`, `unregister(combo:)`, `removeShortcut(forSession:)` methods. Load saved shortcuts from `AppSettings` on init.

- [ ] **Step 3: Add settings keys**

Add `globalShortcut`, `sessionShortcuts`, `sessionActionOrder` keys to Settings.swift using JSONEncoder/JSONDecoder pattern.

Also add `SessionActionType` enum:

```swift
enum SessionActionType: String, Codable, CaseIterable, Sendable {
    case chat
    case focus
    case archive
    case copyAttach
    case delete
    case pinProject
    case assignShortcut
}
```

- [ ] **Step 4: Build and commit**

```bash
xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -5
git add ClaudeIsland/Models/KeyCombo.swift ClaudeIsland/Services/HotkeyManager.swift ClaudeIsland/Core/Settings.swift
git commit -m "feat: add KeyCombo model, HotkeyManager with CGEvent tap, action type enum"
```

---

## Task 14: KeyRecorderView + Shortcuts Settings

**Goal:** Create the reusable key recorder component and shortcuts settings section.

**Files:**
- Create: `ClaudeIsland/UI/Views/KeyRecorderView.swift`
- Create: `ClaudeIsland/UI/Views/ShortcutsSettingsView.swift`
- Modify: `ClaudeIsland/UI/Views/NotchMenuView.swift`

**Acceptance Criteria:**
- [ ] Key recorder with recording state, modifier validation, reserved shortcut check
- [ ] Shortcuts settings with Global section (launcher shortcut) and Sessions section (per-session)
- [ ] Recorder handles Escape to cancel, X button to clear
- [ ] Reserved system shortcuts blocked with visual feedback

**Verify:** `xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -5` -> Build Succeeded

**Steps:**

- [ ] **Step 1: Create KeyRecorderView.swift**

SwiftUI view with `@State var isRecording`. Uses `NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged])`. Validates at least one modifier. Checks against reserved system shortcuts. Shows current combo or "Record..." placeholder. X button to clear.

- [ ] **Step 2: Create ShortcutsSettingsView.swift**

Expandable section. Global section: "New Session" + KeyRecorderView. Sessions section: one row per active binding with session title + KeyRecorderView. Empty state when no session shortcuts.

- [ ] **Step 3: Add to NotchMenuView**

After Projects row:

```swift
                        ShortcutsSettingsView()
```

- [ ] **Step 4: Build and commit**

```bash
xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -5
git add ClaudeIsland/UI/Views/KeyRecorderView.swift ClaudeIsland/UI/Views/ShortcutsSettingsView.swift ClaudeIsland/UI/Views/NotchMenuView.swift
git commit -m "feat: add KeyRecorderView and Shortcuts settings section"
```

---

## Task 15: Session Action Overflow Menu + Customizable Actions

**Goal:** Add the `...` overflow button to session rows, the dropdown menu with all actions, and the customizable visible action slots.

**Files:**
- Create: `ClaudeIsland/UI/Views/SessionActionOverflowMenu.swift`
- Create: `ClaudeIsland/UI/Views/SessionActionsSettingsView.swift`
- Modify: `ClaudeIsland/UI/Views/ClaudeInstancesView.swift`
- Modify: `ClaudeIsland/Services/Tmux/TmuxController.swift`
- Modify: `ClaudeIsland/UI/Views/NotchMenuView.swift`

**Acceptance Criteria:**
- [ ] `...` button as 4th action in InstanceRow (not shown during approval/launching states)
- [ ] Overlay dropdown with all 7 actions
- [ ] Conditional action visibility (Focus requires PID, Archive requires idle/waitingForInput, etc.)
- [ ] Copy Attach copies `tmux attach-session -t <name>` with "Copied!" feedback
- [ ] Delete with inline confirmation, kills tmux session
- [ ] Pin Project writes to ProjectStore
- [ ] Assign Shortcut opens key recorder popover
- [ ] Session Actions settings with reorderable list (top 3 visible, rest overflow)

**Verify:** `xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -5` -> Build Succeeded

**Steps:**

- [ ] **Step 1: Create SessionActionOverflowMenu.swift**

ZStack overlay with absolute positioning. Lists all actions not in visible slots. Each row: icon + label + action. Delete row has inline confirmation state.

- [ ] **Step 2: Add `killSession` to TmuxController**

```swift
    func killSession(sessionName: String) async -> Bool {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else { return false }
        do {
            _ = try await ProcessExecutor.shared.run(tmuxPath, arguments: [
                "kill-session", "-t", sessionName,
            ])
            return true
        } catch {
            return false
        }
    }
```

- [ ] **Step 3: Create SessionActionsSettingsView.swift**

Reorderable list of SessionActionType using `.draggable` + `.dropDestination` pattern from ModuleLayoutSettingsView. Top 3 marked as "Visible", rest as "Overflow".

- [ ] **Step 4: Update ClaudeInstancesView**

Add `@State var showOverflowFor: String?` to ClaudeInstancesView. Add `...` button to InstanceRow action area. Pass action order from parent. Add action callbacks for all 7 actions.

- [ ] **Step 5: Add SessionActionsSettingsView to NotchMenuView**

After Shortcuts row:

```swift
                        SessionActionsSettingsView()
```

- [ ] **Step 6: Build and commit**

```bash
xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -5
git add ClaudeIsland/UI/Views/SessionActionOverflowMenu.swift ClaudeIsland/UI/Views/SessionActionsSettingsView.swift ClaudeIsland/UI/Views/ClaudeInstancesView.swift ClaudeIsland/Services/Tmux/TmuxController.swift ClaudeIsland/UI/Views/NotchMenuView.swift
git commit -m "feat: add session overflow menu, customizable action slots, and kill session"
```

---

## Task 16: Session Removal Unification + HotkeyManager Wiring

**Goal:** Unify all session removal paths through `processSessionEnd`, wire HotkeyManager cleanup, and add focus-session shortcut behavior.

**Files:**
- Modify: `ClaudeIsland/Services/State/SessionStore.swift`
- Modify: `ClaudeIsland/App/AppDelegate.swift`
- Modify: `ClaudeIsland/Core/NotchViewModel.swift`
- Modify: `ClaudeIsland/UI/Views/ChatView.swift`

**Acceptance Criteria:**
- [ ] Hook `status == "ended"` routes through `processSessionEnd` instead of direct removal
- [ ] `SessionStore.onSessionRemoved` callback exists and fires from `processSessionEnd`
- [ ] AppDelegate wires `onSessionRemoved` to `HotkeyManager.removeShortcut(forSession:)`
- [ ] HotkeyManager initialized in AppDelegate, `startIfPermitted` called on accessibility grant
- [ ] `focusInputOnAppear` flag on NotchViewModel for per-session shortcut focus
- [ ] ChatView observes `focusInputOnAppear` and sets `@FocusState`

**Verify:** `xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -5` -> Build Succeeded

**Steps:**

- [ ] **Step 1: Unify session removal in SessionStore**

Replace the direct removal in `processHookEvent` (lines 322-325):

```swift
        if event.status == "ended" {
            await self.processSessionEnd(sessionID: sessionID)
            return
        }
```

Add `onSessionRemoved` callback:

```swift
    var onSessionRemoved: (@Sendable (String) -> Void)?
```

Update `processSessionEnd`:

```swift
    private func processSessionEnd(sessionID: String) async {
        if let session = sessions[sessionID], let tmuxName = session.tmuxSessionName {
            self.pendingLaunches.removeValue(forKey: tmuxName)
        }
        self.sessions.removeValue(forKey: sessionID)
        self.cancelPendingSync(sessionID: sessionID)
        self.onSessionRemoved?(sessionID)
    }
```

- [ ] **Step 2: Add `focusInputOnAppear` to NotchViewModel**

```swift
    var focusInputOnAppear = false
```

- [ ] **Step 3: Observe `focusInputOnAppear` in ChatView**

Add `.onChange`:

```swift
.onChange(of: self.viewModel.focusInputOnAppear) { _, newValue in
    if newValue {
        self.isInputFocused = true
        self.viewModel.focusInputOnAppear = false
    }
}
```

- [ ] **Step 4: Wire HotkeyManager in AppDelegate**

In AppDelegate init/setup:

```swift
_ = HotkeyManager.shared

Task(name: "wire-session-removed") {
    await SessionStore.shared.setOnSessionRemoved { sessionID in
        Task(name: "cleanup-shortcut") { @MainActor in
            HotkeyManager.shared.removeShortcut(forSession: sessionID)
        }
    }
}
```

Add `HotkeyManager.shared.startIfPermitted()` to the accessibility grant callback.

- [ ] **Step 5: Build and commit**

```bash
xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -5
git add ClaudeIsland/Services/State/SessionStore.swift ClaudeIsland/App/AppDelegate.swift ClaudeIsland/Core/NotchViewModel.swift ClaudeIsland/UI/Views/ChatView.swift
git commit -m "feat: unify session removal, wire HotkeyManager cleanup and focus-session shortcuts"
```

---

## REVIEW CHECKPOINT: Chunk 3 Complete

**Pause and review.** Tasks 13-16 complete Chunk 3. Verify:
1. Global hotkey opens launcher (if accessibility granted)
2. Per-session shortcuts navigate to chat view
3. Overflow `...` menu shows all actions
4. Copy Attach copies correct tmux command
5. Delete kills tmux session with confirmation
6. Session Actions settings allows reordering visible slots
7. Shortcuts settings shows global + per-session bindings

---

## Task 17: Final Integration + Lint + Build Verification

**Goal:** Run full linting, fix any SwiftLint/SwiftFormat violations, and verify the complete build.

**Files:**
- All modified files

**Acceptance Criteria:**
- [ ] `swiftlint lint --strict ClaudeIsland/` passes (warnings are errors)
- [ ] `swiftformat ClaudeIsland/` makes no changes
- [ ] `xcodebuild -scheme ClaudeIsland -configuration Release build` succeeds
- [ ] No file exceeds 600 lines warning / 1000 lines error
- [ ] No function body exceeds 60 lines warning / 100 lines error

**Verify:** `swiftlint lint --strict ClaudeIsland/ 2>&1 | tail -10 && xcodebuild -scheme ClaudeIsland -configuration Release build 2>&1 | tail -5`

**Steps:**

- [ ] **Step 1: Run SwiftFormat**

```bash
swiftformat ClaudeIsland/
```

- [ ] **Step 2: Run SwiftLint**

```bash
swiftlint lint --strict ClaudeIsland/
```

Fix any violations.

- [ ] **Step 3: Release build**

```bash
xcodebuild -scheme ClaudeIsland -configuration Release build 2>&1 | tail -5
```

- [ ] **Step 4: Commit any fixes**

```bash
git add -A
git commit -m "chore: fix lint and format violations"
```

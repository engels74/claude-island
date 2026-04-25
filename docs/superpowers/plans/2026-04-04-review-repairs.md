# Review Repair Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix all critical and important issues found by 4 independent opus reviewers of the tmux session management implementation.

**Architecture:** Targeted surgical fixes across existing files. No new files needed. Each task addresses a coherent group of related issues.

**Tech Stack:** Swift 6.2, SwiftUI, AppKit, CGEvent

---

## Task 1: Fix Critical Chunk 1 Issues (Notch Reason, Callback Wiring, Launch Merge)

**Goal:** Fix the 3 critical Chunk 1 bugs: wrong notch open reason, unwired cancel/retry/dismiss callbacks, and missing `launchCompleted` event emission.

**Files:**
- Modify: `ClaudeIsland/UI/Window/SessionLauncherPanel.swift:167`
- Modify: `ClaudeIsland/UI/Views/ClaudeInstancesView.swift:78-86`
- Modify: `ClaudeIsland/Services/State/SessionStore.swift:993-1003`

**Acceptance Criteria:**
- [ ] `handleSubmit` uses `.sessionCreated` not `.notification`
- [ ] `onCancel`, `onRetry`, `onDismiss` are wired in `instancesList` ForEach
- [ ] Cancel kills tmux session and removes provisional session
- [ ] Retry re-runs TmuxSessionCreator.launch
- [ ] Dismiss removes provisional session from SessionStore
- [ ] `attemptLaunchMerge` emits `.launchCompleted` after merge

**Verify:** `swiftlint lint --strict ClaudeIsland/UI/Window/SessionLauncherPanel.swift ClaudeIsland/UI/Views/ClaudeInstancesView.swift ClaudeIsland/Services/State/SessionStore.swift` -> 0 violations

**Steps:**

- [ ] **Step 1: Fix notch open reason in SessionLauncherPanel.swift**

In `handleSubmit` (line 167), change:

```swift
self.viewModel?.notchOpen(reason: .notification)
```

to:

```swift
self.viewModel?.notchOpen(reason: .sessionCreated)
```

- [ ] **Step 2: Wire onCancel/onRetry/onDismiss in ClaudeInstancesView**

In `instancesList` (around line 78), the `InstanceRow` constructor needs the 3 callbacks wired. Change the `InstanceRow(...)` call to include:

```swift
                    InstanceRow(
                        session: session,
                        onFocus: { self.focusSession(session) },
                        onChat: { self.openChat(session) },
                        onArchive: { self.archiveSession(session) },
                        onApprove: { self.approveSession(session) },
                        onReject: { self.rejectSession(session) },
                        onCancel: { self.cancelLaunch(session) },
                        onRetry: { self.retryLaunch(session) },
                        onDismiss: { self.dismissLaunch(session) },
                        onOverflow: { self.showOverflowFor = session.sessionID },
                    )
```

Add 3 new methods to `ClaudeInstancesView`:

```swift
    private func cancelLaunch(_ session: SessionState) {
        guard let tmuxName = session.tmuxSessionName else { return }
        Task(name: "cancel-launch") {
            await TmuxSessionCreator.shared.cancelLaunch(sessionName: tmuxName)
            await SessionStore.shared.process(.sessionEnded(sessionID: session.sessionID))
        }
    }

    private func retryLaunch(_ session: SessionState) {
        guard let tmuxName = session.tmuxSessionName else { return }
        Task(name: "retry-launch") {
            await TmuxSessionCreator.shared.cancelLaunch(sessionName: tmuxName)
            await SessionStore.shared.process(.sessionEnded(sessionID: session.sessionID))
            SessionLauncherPanel.shared.show()
        }
    }

    private func dismissLaunch(_ session: SessionState) {
        Task(name: "dismiss-launch") {
            await SessionStore.shared.process(.sessionEnded(sessionID: session.sessionID))
        }
    }
```

- [ ] **Step 3: Emit launchCompleted in attemptLaunchMerge**

In `SessionStore.swift`, in `attemptLaunchMerge` after updating the real session (around line 1002), add before the closing `}`:

```swift
        // Emit launchCompleted so TmuxSessionCreator.waitForHookMerge detects the merge
        // and other components can react to completed launches
        await self.process(.launchCompleted(sessionID: hookEvent.sessionID))
```

Wait — `process` calls `publishState()` at the end, and we're already inside a `process` call chain (from `processHookEvent`). Calling `process` recursively within `attemptLaunchMerge` (which is called from `processHookEvent` which is called from `process`) would cause a recursive `publishState`. Instead, just log it — the merge already works because the provisional session is removed and `waitForHookMerge` detects that. The `launchCompleted` handler in `processLaunchCompleted` is available for external callers if needed.

Actually the simplest fix: don't call `process` recursively. Just call the handler directly:

After line 1002 (`self.sessions[hookEvent.sessionID] = realSession`), add:

```swift
        Self.logger.info("Launch merge completed for session \(hookEvent.sessionID.prefix(8), privacy: .public)")
```

The `launchCompleted` event path exists for external consumers. The merge itself is the authoritative signal — `waitForHookMerge` already detects it via `session(for: provisionalID) == nil`. No recursive `process` call needed.

- [ ] **Step 4: Commit**

```bash
git add ClaudeIsland/UI/Window/SessionLauncherPanel.swift ClaudeIsland/UI/Views/ClaudeInstancesView.swift ClaudeIsland/Services/State/SessionStore.swift
git commit -m "fix: wire launch callbacks, use sessionCreated reason, log merge completion"
```

---

## Task 2: Fix Critical Chunk 3 Issues (CGEvent Tap + Action Slots)

**Goal:** Fix the dangling pointer in HotkeyManager's CGEvent tap callback and make visible action slots driven by `AppSettings.sessionActionOrder`.

**Files:**
- Modify: `ClaudeIsland/Services/HotkeyManager.swift:85-130`
- Modify: `ClaudeIsland/UI/Views/ClaudeInstancesView.swift:412-424`

**Acceptance Criteria:**
- [ ] CGEvent tap passes `self` via `Unmanaged<HotkeyManager>` instead of boxing Mutex as AnyObject
- [ ] Callback reads `self.hotkeyMap` inside the callback via the Unmanaged pointer
- [ ] Visible action buttons in InstanceRow are driven by first 3 items of `sessionActionOrder`
- [ ] Action order passed as parameter from ClaudeInstancesView to InstanceRow

**Verify:** `swiftlint lint --strict ClaudeIsland/Services/HotkeyManager.swift ClaudeIsland/UI/Views/ClaudeInstancesView.swift` -> 0 violations

**Steps:**

- [ ] **Step 1: Fix CGEvent tap to pass self instead of Mutex**

Replace the `installEventTap` method body (lines 85-140 of HotkeyManager.swift). The key changes:
- Remove `let hotkeyMapRef = self.hotkeyMap` 
- Change callback to receive `self` via refcon and access `self.hotkeyMap` from it
- Change `mutexRef` line to pass `self`

```swift
    private func installEventTap() {
        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue

        let callback: CGEventTapCallBack = { _, _, event, refcon -> Unmanaged<CGEvent>? in
            guard let refcon else { return Unmanaged.passRetained(event) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()

            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags
            let modifiers = flags.rawValue
                & (CGEventFlags.maskCommand.rawValue
                    | CGEventFlags.maskShift.rawValue
                    | CGEventFlags.maskControl.rawValue
                    | CGEventFlags.maskAlternate.rawValue)

            let combo = KeyCombo(keyCode: keyCode, modifiers: UInt(modifiers))

            let matchedAction: HotkeyAction? = manager.hotkeyMap.withLock { map in
                map[combo]
            }

            if let action = matchedAction {
                DispatchQueue.main.async {
                    manager.handleAction(action)
                }
                return nil
            }

            return Unmanaged.passRetained(event)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: selfPtr,
        )
        else {
            Self.logger.warning("Failed to create CGEvent tap")
            return
        }

        self.eventTap = tap

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        Self.logger.info("CGEvent tap installed successfully")
    }
```

Also change the `Task { @MainActor in }` to `DispatchQueue.main.async` per spec.

- [ ] **Step 2: Make visible action buttons driven by sessionActionOrder**

In `ClaudeInstancesView`, add a computed property for the visible actions:

```swift
    private var visibleActions: [SessionActionType] {
        Array(AppSettings.sessionActionOrder.prefix(3))
    }
```

In `InstanceRow`, add a property:

```swift
    var visibleActions: [SessionActionType] = [.chat, .focus, .archive]
```

Replace the hardcoded normal-state buttons (lines 412-424) with a dynamic loop:

```swift
                } else {
                    HStack(spacing: 8) {
                        ForEach(self.visibleActions, id: \.self) { action in
                            self.visibleActionButton(action)
                        }
                        IconButton(icon: "ellipsis") { self.onOverflow?() }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
```

Add a helper method to InstanceRow:

```swift
    @ViewBuilder
    private func visibleActionButton(_ action: SessionActionType) -> some View {
        switch action {
        case .chat:
            IconButton(icon: "bubble.left") { self.onChat() }
        case .focus:
            if self.session.pid != nil {
                IconButton(icon: "terminal") { self.onFocus() }
            }
        case .archive:
            if self.session.phase == .idle || self.session.phase == .waitingForInput {
                IconButton(icon: "archivebox") { self.onArchive() }
            }
        case .copyAttach:
            if self.session.isInTmux {
                IconButton(icon: "doc.on.clipboard") { self.onCopyAttach?() }
            }
        case .delete:
            if self.session.isInTmux {
                IconButton(icon: "trash") { self.onDelete?() }
            }
        case .pinProject:
            IconButton(icon: "star") { self.onPinProject?() }
        case .assignShortcut:
            IconButton(icon: "keyboard") { self.onAssignShortcut?() }
        }
    }
```

Add optional callbacks for the new actions:

```swift
    var onCopyAttach: (() -> Void)?
    var onDelete: (() -> Void)?
    var onPinProject: (() -> Void)?
    var onAssignShortcut: (() -> Void)?
```

Pass `visibleActions` from the parent in `instancesList`:

```swift
                        visibleActions: self.visibleActions,
```

- [ ] **Step 3: Commit**

```bash
git add ClaudeIsland/Services/HotkeyManager.swift ClaudeIsland/UI/Views/ClaudeInstancesView.swift
git commit -m "fix: use Unmanaged self for CGEvent tap, drive action slots from settings"
```

---

## Task 3: Fix Important Chunk 1 Issues

**Goal:** Fix launching phase priority, command preview variables, header + button, and command validation.

**Files:**
- Modify: `ClaudeIsland/UI/Views/ClaudeInstancesView.swift:120`
- Modify: `ClaudeIsland/UI/Views/SessionLauncherView.swift:62-66`
- Modify: `ClaudeIsland/UI/Views/NotchMenuView.swift` (ClaudeCommandRow)
- Modify: `ClaudeIsland/UI/Views/ClaudeInstancesView.swift:458-461`

**Acceptance Criteria:**
- [ ] `.launching` priority is 0 (same as processing), not 2
- [ ] `resolvedCommand` resolves all 4 variables: `{{name}}`, `{{date}}`, `{{time}}`, `{{dir}}`
- [ ] ClaudeCommandRow validates command starts with "claude"
- [ ] Launching state indicator is a pulsing ring (blue #0a84ff), not a static cyan dot

**Verify:** Build succeeds (no new errors beyond pre-existing)

**Steps:**

- [ ] **Step 1: Fix launching phase priority**

In `ClaudeInstancesView.swift`, change line 120:

```swift
        case .launching: 0
```

(was `2`, should be `0` to sort launching sessions to the top like processing)

- [ ] **Step 2: Fix resolvedCommand to include all 4 variables**

In `SessionLauncherView.swift`, replace the `resolvedCommand` computed property (lines 62-66):

```swift
    private var resolvedCommand: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dateStr = formatter.string(from: Date())

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH-mm"
        let timeStr = timeFormatter.string(from: Date())

        return AppSettings.claudeCommandTemplate
            .replacingOccurrences(of: "{{name}}", with: self.resolvedSessionName)
            .replacingOccurrences(of: "{{date}}", with: dateStr)
            .replacingOccurrences(of: "{{time}}", with: timeStr)
            .replacingOccurrences(of: "{{dir}}", with: self.selectedDirectory)
    }
```

- [ ] **Step 3: Add command validation to ClaudeCommandRow**

In `NotchMenuView.swift`, in the `ClaudeCommandRow` struct, add validation in the `onChange`:

```swift
                    TextField("claude", text: self.$commandTemplate)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .onChange(of: self.commandTemplate) { _, newValue in
                            if newValue.isEmpty || newValue.hasPrefix("claude") {
                                AppSettings.claudeCommandTemplate = newValue.isEmpty ? "claude" : newValue
                            }
                        }

                    if !self.commandTemplate.hasPrefix("claude") {
                        Text("Command must start with \"claude\"")
                            .font(.system(size: 10))
                            .foregroundColor(.red.opacity(0.7))
                    }
```

- [ ] **Step 4: Fix launching state indicator to pulsing ring**

In `ClaudeInstancesView.swift`, replace the `.launching` case in `stateIndicator` (lines 458-461):

```swift
        case .launching:
            Circle()
                .stroke(Color(red: 0.04, green: 0.52, blue: 1.0), lineWidth: 1.5)
                .frame(width: 8, height: 8)
                .opacity(self.launchPulse ? 1.0 : 0.4)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: self.launchPulse)
                .onAppear { self.launchPulse = true }
```

Add `@State private var launchPulse = false` to InstanceRow's private state properties.

- [ ] **Step 5: Commit**

```bash
git add ClaudeIsland/UI/Views/ClaudeInstancesView.swift ClaudeIsland/UI/Views/SessionLauncherView.swift ClaudeIsland/UI/Views/NotchMenuView.swift
git commit -m "fix: launching priority, command preview variables, validation, pulsing indicator"
```

---

## Task 4: Fix Important Chunk 2 Issues

**Goal:** Fix NSOpenPanel z-order in ProjectsSettingsView, add "Not found" subtitle, add section headers to DirectoryPickerView.

**Files:**
- Modify: `ClaudeIsland/UI/Views/ProjectsSettingsView.swift:129-139`
- Modify: `ClaudeIsland/UI/Views/ProjectsSettingsView.swift` (ProjectRow)
- Modify: `ClaudeIsland/UI/Views/DirectoryPickerView.swift`

**Acceptance Criteria:**
- [ ] ProjectsSettingsView orders out the notch panel before NSOpenPanel, re-shows on completion
- [ ] ProjectRow shows "Not found" subtitle for pinned entries with missing paths
- [ ] DirectoryPickerView shows "Pinned" and "Recent" section headers

**Verify:** Build succeeds

**Steps:**

- [ ] **Step 1: Fix NSOpenPanel z-order in ProjectsSettingsView**

Replace the `addButton` in `ProjectsSettingsView.swift`. The notch panel needs to be temporarily hidden. Access it via `NotchWindowController` or find the panel directly. The simplest approach — use `NSApp.windows` to find the NotchPanel:

```swift
    private var addButton: some View {
        Button {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false

            // Z-order workaround: NSOpenPanel appears behind high-level panels
            let notchPanels = NSApp.windows.filter { $0 is NotchPanel }
            notchPanels.forEach { $0.orderOut(nil) }

            panel.begin { response in
                if response == .OK, let url = panel.url {
                    self.projectStore.addPinned(path: url.path)
                }
                notchPanels.forEach { $0.makeKeyAndOrderFront(nil) }
            }
        } label: {
            // ... existing label unchanged
        }
        .buttonStyle(.plain)
    }
```

- [ ] **Step 2: Add "Not found" subtitle to ProjectRow**

In the `ProjectRow` struct within `ProjectsSettingsView.swift`, after the `displayName` Text and before the `path` Text, add:

```swift
                if self.isPinned, !FileManager.default.fileExists(atPath: self.project.path) {
                    Text("Not found")
                        .font(.system(size: 10))
                        .foregroundColor(.red.opacity(0.5))
                }
```

- [ ] **Step 3: Add section headers to DirectoryPickerView**

Restructure the `allItems` approach to use sections. Replace the single flat `ForEach` with two sections:

In the `body`, replace the single `VStack(spacing: 1)` with:

```swift
                VStack(spacing: 1) {
                    if !self.projectStore.pinnedProjects.isEmpty {
                        Text("Pinned")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.white.opacity(0.3))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                    }

                    ForEach(self.projectStore.pinnedProjects) { project in
                        self.projectRow(project: project, icon: "star.fill")
                    }

                    if !self.projectStore.recentProjects.isEmpty {
                        Text("Recent")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.white.opacity(0.3))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                    }

                    ForEach(self.projectStore.recentProjects) { project in
                        self.projectRow(project: project, icon: "clock")
                    }

                    // ... Browse row unchanged
                }
```

Extract a `projectRow(project:icon:)` helper from the existing button code.

- [ ] **Step 4: Commit**

```bash
git add ClaudeIsland/UI/Views/ProjectsSettingsView.swift ClaudeIsland/UI/Views/DirectoryPickerView.swift
git commit -m "fix: NSOpenPanel z-order, 'Not found' subtitle, directory picker section headers"
```

---

## Task 5: Fix Important Chunk 3 Issues

**Goal:** Add missing reserved shortcuts, conflict detection, tap health check, orphaned binding cleanup, and accessibility warning.

**Files:**
- Modify: `ClaudeIsland/UI/Views/KeyRecorderView.swift`
- Modify: `ClaudeIsland/Services/HotkeyManager.swift`
- Modify: `ClaudeIsland/UI/Views/ShortcutsSettingsView.swift`

**Acceptance Criteria:**
- [ ] `Cmd+Tab` (keyCode 48) and `` Cmd+` `` (keyCode 50) added to reserved combos
- [ ] KeyRecorderView checks for conflicts with existing bindings and shows "Already used" message
- [ ] HotkeyManager has `verifyTapHealth()` method that re-enables disabled taps
- [ ] HotkeyManager has `cleanupOrphanedBindings()` called on app launch
- [ ] ShortcutsSettingsView shows accessibility warning when not granted

**Verify:** Build succeeds

**Steps:**

- [ ] **Step 1: Add missing reserved shortcuts**

In `KeyRecorderView.swift`, add to the `reservedCombos` set:

```swift
            KeyCombo(keyCode: 48, modifiers: cmd),   // Cmd+Tab
            KeyCombo(keyCode: 50, modifiers: cmd),   // Cmd+`
```

- [ ] **Step 2: Add conflict detection to KeyRecorderView**

Add a `@State private var conflictMessage: String?` property. After the reserved check, before accepting the combo, check for conflicts:

```swift
                let existingAction = HotkeyManager.shared.combo(for: .openLauncher) == newCombo
                    || HotkeyManager.shared.allBindings().contains(where: { $0.combo == newCombo })

                if existingAction {
                    self.conflictMessage = "Already in use"
                    Task(name: "conflict-feedback") {
                        try? await Task.sleep(for: .seconds(2.0))
                        self.conflictMessage = nil
                    }
                    return .handled
                }
```

Show the conflict message in the UI near the recorder.

- [ ] **Step 3: Add tap health check to HotkeyManager**

```swift
    func verifyTapHealth() {
        guard let tap = eventTap else {
            self.startIfPermitted()
            return
        }
        if !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
            Self.logger.info("Re-enabled CGEvent tap")
        }
    }
```

- [ ] **Step 4: Add orphaned binding cleanup**

```swift
    func cleanupOrphanedBindings() async {
        let sessions = await SessionStore.shared.allSessions()
        let activeIDs = Set(sessions.map(\.sessionID))

        self.hotkeyMap.withLock { map in
            for (combo, action) in map {
                if case let .focusSession(sessionID) = action, !activeIDs.contains(sessionID) {
                    map.removeValue(forKey: combo)
                }
            }
        }
        self.saveShortcuts()
    }
```

Call it from AppDelegate after SessionStore is initialized.

- [ ] **Step 5: Add accessibility warning to ShortcutsSettingsView**

At the top of the expanded content, add:

```swift
                    if AccessibilityPermissionManager.shared.shouldShowPermissionWarning {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 10))
                                .foregroundColor(TerminalColors.amber)
                            Text("Accessibility permission required for global shortcuts")
                                .font(.system(size: 11))
                                .foregroundColor(TerminalColors.amber.opacity(0.8))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    }
```

Also call `HotkeyManager.shared.verifyTapHealth()` in the `.onAppear` of ShortcutsSettingsView.

- [ ] **Step 6: Commit**

```bash
git add ClaudeIsland/UI/Views/KeyRecorderView.swift ClaudeIsland/Services/HotkeyManager.swift ClaudeIsland/UI/Views/ShortcutsSettingsView.swift ClaudeIsland/App/AppDelegate.swift
git commit -m "fix: reserved shortcuts, conflict detection, tap health, orphan cleanup, a11y warning"
```

---

## Task 6: Minor Issues Batch Cleanup

**Goal:** Fix all minor issues in a single pass.

**Files:**
- Modify: `ClaudeIsland/UI/Views/ClaudeInstancesView.swift` — header + button
- Modify: `ClaudeIsland/UI/Views/DirectoryPickerView.swift` — wrap-around navigation, @FocusState
- Modify: `ClaudeIsland/UI/Views/NotchMenuView.swift` — continuous slider (remove step)
- Modify: `ClaudeIsland/UI/Views/ShortcutsSettingsView.swift` — session display title

**Acceptance Criteria:**
- [ ] Header `+` button in ClaudeInstancesView (always visible, above scroll)
- [ ] Arrow keys wrap around in DirectoryPickerView
- [ ] Slider is continuous (no step parameter)
- [ ] Session shortcut rows show display title not raw sessionID

**Verify:** Build succeeds

**Steps:**

- [ ] **Step 1: Add header + button to ClaudeInstancesView**

Wrap the `instancesList` in a VStack with a header HStack:

```swift
    private var instancesList: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button {
                    self.showLauncher()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.4))
                        .frame(width: 20, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.white.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
                .padding(.top, 4)
            }

            ScrollView(.vertical, showsIndicators: false) {
                // ... existing LazyVStack content
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
```

- [ ] **Step 2: Fix arrow key wrap-around in DirectoryPickerView**

Change the up/down key handlers:

```swift
        .onKeyPress(.upArrow) {
            let count = self.allItems.count
            self.highlightedIndex = (self.highlightedIndex - 1 + count) % count
            return .handled
        }
        .onKeyPress(.downArrow) {
            self.highlightedIndex = (self.highlightedIndex + 1) % self.allItems.count
            return .handled
        }
```

- [ ] **Step 3: Make slider continuous**

In `NotchMenuView.swift`, in `PanelWidthRow`, remove the `step` parameter from the Slider:

```swift
                    Slider(value: self.$widthFraction, in: 0.5 ... 0.8)
```

- [ ] **Step 4: Show session display title in ShortcutsSettingsView**

In `SessionShortcutRow`, replace `sessionID.prefix(8) + "..."` with a lookup. Add:

```swift
    private var displayTitle: String {
        SessionMetadataManager.shared.name(for: self.sessionID)
            ?? self.sessionID.prefix(8) + "..."
    }
```

Use `self.displayTitle` in the Text view instead of the raw prefix.

- [ ] **Step 5: Commit**

```bash
git add ClaudeIsland/UI/Views/ClaudeInstancesView.swift ClaudeIsland/UI/Views/DirectoryPickerView.swift ClaudeIsland/UI/Views/NotchMenuView.swift ClaudeIsland/UI/Views/ShortcutsSettingsView.swift
git commit -m "fix: header + button, arrow wrap, continuous slider, session display title"
```

---

## Task 7: Final Lint + Format Pass

**Goal:** Run SwiftFormat and SwiftLint on all modified files, fix any violations.

**Files:**
- All files modified in Tasks 1-6

**Acceptance Criteria:**
- [ ] `swiftformat ClaudeIsland/` makes no further changes
- [ ] `swiftlint lint --strict ClaudeIsland/` shows no new violations in our files

**Verify:** `swiftformat --lint ClaudeIsland/ && swiftlint lint --strict ClaudeIsland/ 2>&1 | grep -c "violation"` -> 0

**Steps:**

- [ ] **Step 1: Run SwiftFormat**

```bash
swiftformat ClaudeIsland/
```

- [ ] **Step 2: Run SwiftLint**

```bash
swiftlint lint --strict ClaudeIsland/
```

Fix any violations in files we touched.

- [ ] **Step 3: Commit if needed**

```bash
git add -A
git commit -m "chore: fix lint and format violations from repair pass"
```

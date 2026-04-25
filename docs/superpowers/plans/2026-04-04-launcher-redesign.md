# Launcher Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redesign the SessionLauncherView from a cluttered layout to a minimal Raycast-style interface with progressive disclosure — prompt on top, "in [project]" row below, session name and directory picker revealed on demand.

**Architecture:** Full rewrite of `SessionLauncherView.swift` and `DirectoryPickerView.swift`, minor change to `SessionLauncherPanel.swift`. The view keeps the same `onSubmit`/`onDismiss` interface contract — the panel doesn't change. The directory picker becomes an inline expandable section controlled by `@State isDropdownOpen` on the parent view.

**Tech Stack:** SwiftUI (TextEditor, @FocusState, .onKeyPress), AppKit (NSOpenPanel, NSPanel)

**Spec:** `docs/superpowers/specs/2026-04-04-launcher-redesign.md`

---

## File Map

- `ClaudeIsland/UI/Views/SessionLauncherView.swift` — **full rewrite**: new layout with prompt, "as" name row, "in" directory row, dropdown, conditional bottom bar
- `ClaudeIsland/UI/Views/DirectoryPickerView.swift` — **refactor**: becomes a dropdown-styled expandable section, no longer a standalone inline list
- `ClaudeIsland/UI/Window/SessionLauncherPanel.swift` — **minor**: remove local Esc key monitor from `installMonitors()`

---

## Task 1: Rewrite SessionLauncherView

**Goal:** Replace the current layout with the new minimal design: prompt field, "as" name row (Tab to reveal), "in" directory row, dropdown picker, conditional bottom bar, and Esc priority chain.

**Files:**
- Modify: `ClaudeIsland/UI/Views/SessionLauncherView.swift` — full rewrite

**Acceptance Criteria:**
- [ ] Prompt field is auto-focused on appear (150ms delay)
- [ ] Placeholder has `.allowsHitTesting(false)`
- [ ] Focus border (blue, 1.5px) shown on active field, animates in/out
- [ ] Enter submits, Shift+Enter for newline
- [ ] Tab reveals "as [name]" row with auto-generated session name as placeholder
- [ ] "in [project]" row shows current directory with star/clock icon
- [ ] Click on directory row toggles `isDropdownOpen`
- [ ] DirectoryPickerView rendered inline when `isDropdownOpen` is true (panel grows)
- [ ] Esc priority: close dropdown first → hide name field → call onDismiss
- [ ] No Launch button
- [ ] Bottom bar: hints only when template is "claude", command + hints when template has `{{`
- [ ] Hint text updates by state (prompt focused vs name focused vs dropdown open)
- [ ] `.onKeyPress` for arrow keys only active when `isDropdownOpen`

**Verify:** `xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -3` -> BUILD SUCCEEDED

**Steps:**

- [ ] **Step 1: Replace the entire contents of SessionLauncherView.swift**

```swift
//
//  SessionLauncherView.swift
//  ClaudeIsland
//
//  Raycast-style session launcher with progressive disclosure
//

import SwiftUI

struct SessionLauncherView: View {
    // MARK: Internal

    let onSubmit: (String, String, String) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Prompt
            self.promptField
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)

            // Session name (hidden by default)
            if self.showNameField {
                self.nameField
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Divider
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)
                .padding(.horizontal, 16)

            // Directory row
            self.directoryRow
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            // Directory picker dropdown (inline, grows panel)
            if self.isDropdownOpen {
                DirectoryPickerView(
                    selectedPath: self.$selectedDirectory,
                    onSelect: {
                        withAnimation(.easeOut(duration: 0.15)) {
                            self.isDropdownOpen = false
                        }
                    },
                    onBrowse: { self.openBrowser() },
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Bottom bar
            self.bottomBar
        }
        .frame(width: 500)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: self.showNameField)
        .animation(.spring(response: 0.2, dampingFraction: 0.85), value: self.isDropdownOpen)
        .onAppear {
            Task(name: "focus-launcher-prompt") {
                try? await Task.sleep(for: .seconds(0.15))
                guard !Task.isCancelled else { return }
                self.focusedField = .prompt
            }
        }
        .onKeyPress(.escape) {
            if self.isDropdownOpen {
                withAnimation { self.isDropdownOpen = false }
                return .handled
            }
            if self.showNameField, self.focusedField == .name {
                withAnimation { self.showNameField = false }
                self.focusedField = .prompt
                return .handled
            }
            self.onDismiss()
            return .handled
        }
    }

    // MARK: Private

    private enum Field: Hashable {
        case prompt
        case name
    }

    @State private var prompt = ""
    @State private var sessionName = ""
    @State private var selectedDirectory: String = AppSettings.lastUsedDirectory
        ?? ProjectStore.shared.pinnedProjects.first?.path
        ?? FileManager.default.homeDirectoryForCurrentUser.path
    @State private var showNameField = false
    @State private var isDropdownOpen = false
    @FocusState private var focusedField: Field?

    private let accentBlue = Color(red: 0.04, green: 0.52, blue: 1.0)

    private var resolvedSessionName: String {
        if !self.sessionName.isEmpty {
            return self.sessionName
        }
        if !self.prompt.isEmpty {
            return String(self.prompt.prefix(30))
                .lowercased()
                .replacingOccurrences(of: " ", with: "-")
                .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return "claude-\(formatter.string(from: Date()))"
    }

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

    private var hasCustomTemplate: Bool {
        AppSettings.claudeCommandTemplate.contains("{{")
    }

    private var selectedProjectName: String {
        URL(fileURLWithPath: self.selectedDirectory).lastPathComponent
    }

    private var selectedProjectIsPinned: Bool {
        ProjectStore.shared.pinnedProjects.contains { $0.path == self.selectedDirectory }
    }

    private var hintText: String {
        if self.isDropdownOpen {
            return "\u{2191}\u{2193} navigate \u{00B7} \u{23CE} select \u{00B7} Esc close"
        }
        if self.focusedField == .name {
            return "\u{23CE} launch \u{00B7} Esc cancel"
        }
        return "Tab: session name \u{00B7} \u{23CE} launch \u{00B7} Esc cancel"
    }

    // MARK: - Prompt Field

    private var promptField: some View {
        ZStack(alignment: .topLeading) {
            if self.prompt.isEmpty {
                Text("What should Claude do?")
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(0.25))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 10)
                    .allowsHitTesting(false)
            }

            TextEditor(text: self.$prompt)
                .font(.system(size: 15))
                .foregroundColor(.white)
                .scrollContentBackground(.hidden)
                .focused(self.$focusedField, equals: .prompt)
                .frame(minHeight: 44, maxHeight: 120)
                .fixedSize(horizontal: false, vertical: true)
                .onKeyPress(.return, phases: .down) { keyPress in
                    if keyPress.modifiers.contains(.shift) {
                        return .ignored
                    }
                    self.submit()
                    return .handled
                }
                .onKeyPress(.tab, phases: .down) { _ in
                    withAnimation {
                        self.showNameField = true
                    }
                    self.focusedField = .name
                    return .handled
                }
        }
        .padding(8)
        .background(Color.white.opacity(0.06))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    self.accentBlue.opacity(self.focusedField == .prompt ? 0.4 : 0),
                    lineWidth: 1.5,
                ),
        )
        .animation(.easeInOut(duration: 0.15), value: self.focusedField)
    }

    // MARK: - Name Field

    private var nameField: some View {
        HStack(spacing: 8) {
            Text("AS")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.3))
                .tracking(0.5)

            TextField(self.resolvedSessionName, text: self.$sessionName)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .focused(self.$focusedField, equals: .name)
                .onSubmit { self.submit() }
                .padding(8)
                .background(Color.white.opacity(0.06))
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(
                            self.accentBlue.opacity(self.focusedField == .name ? 0.4 : 0),
                            lineWidth: 1.5,
                        ),
                )
                .animation(.easeInOut(duration: 0.15), value: self.focusedField)
        }
    }

    // MARK: - Directory Row

    private var directoryRow: some View {
        Button {
            withAnimation {
                self.isDropdownOpen.toggle()
            }
        } label: {
            HStack(spacing: 10) {
                Text("IN")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.3))
                    .tracking(0.5)

                Image(systemName: self.selectedProjectIsPinned ? "star.fill" : "clock")
                    .font(.system(size: 11))
                    .foregroundColor(self.selectedProjectIsPinned ? .yellow.opacity(0.7) : .white.opacity(0.4))

                Text(self.selectedProjectName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))

                Spacer()

                Image(systemName: self.isDropdownOpen ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.3))
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)

            VStack(spacing: 2) {
                if self.hasCustomTemplate {
                    Text(self.resolvedCommand)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.22))
                        .lineLimit(1)
                        .padding(.top, 6)

                    Text(self.hintText)
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.13))
                        .padding(.bottom, 6)
                } else {
                    Text(self.hintText)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.18))
                        .padding(.vertical, 7)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Actions

    private func submit() {
        let trimmedPrompt = self.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        self.onSubmit(trimmedPrompt, self.resolvedSessionName, self.selectedDirectory)
    }

    private func openBrowser() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: self.selectedDirectory)

        SessionLauncherPanel.shared.orderOut(nil)

        panel.begin { response in
            if response == .OK, let url = panel.url {
                self.selectedDirectory = url.path
                ProjectStore.shared.recordUsage(path: url.path)
            }
            SessionLauncherPanel.shared.makeKeyAndOrderFront(nil)
        }
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -3`
Expected: BUILD SUCCEEDED (DirectoryPickerView will have a compile error since its interface changed — that's expected and fixed in Task 2)

Actually, Task 1 and Task 2 must be done together since they depend on each other. The new `SessionLauncherView` calls `DirectoryPickerView(selectedPath:onSelect:onBrowse:)` which doesn't exist yet. Both files must be committed together.

Proceed to Task 2 before building.

- [ ] **Step 3: Commit (after Task 2 is also complete)**

```bash
git add ClaudeIsland/UI/Views/SessionLauncherView.swift ClaudeIsland/UI/Views/DirectoryPickerView.swift
git commit -m "feat: redesign session launcher with minimal Raycast-style layout"
```

---

## Task 2: Refactor DirectoryPickerView as Dropdown

**Goal:** Refactor `DirectoryPickerView` from a standalone inline list to a dropdown-styled expandable section that renders inside the launcher when `isDropdownOpen` is true.

**Files:**
- Modify: `ClaudeIsland/UI/Views/DirectoryPickerView.swift` — full rewrite

**Acceptance Criteria:**
- [ ] New interface: `init(selectedPath:onSelect:onBrowse:)`
- [ ] Dark background with border and shadow (dropdown styling)
- [ ] "Pinned" and "Recent" section headers
- [ ] Pinned rows: star icon + name + checkmark if selected
- [ ] Recent rows: clock icon + name + relative time
- [ ] "Browse..." row at bottom
- [ ] Arrow key navigation (up/down with wrap, skipping headers)
- [ ] Enter selects highlighted item
- [ ] Empty state shows Home directory
- [ ] Max height 200px with scroll

**Verify:** `xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -3` -> BUILD SUCCEEDED

**Steps:**

- [ ] **Step 1: Replace the entire contents of DirectoryPickerView.swift**

```swift
//
//  DirectoryPickerView.swift
//  ClaudeIsland
//
//  Dropdown directory picker for the session launcher
//

import SwiftUI

// MARK: - DirectoryPickerView

struct DirectoryPickerView: View {
    // MARK: Lifecycle

    init(
        selectedPath: Binding<String>,
        onSelect: @escaping () -> Void,
        onBrowse: @escaping () -> Void,
    ) {
        self._selectedPath = selectedPath
        self.onSelect = onSelect
        self.onBrowse = onBrowse
    }

    // MARK: Internal

    @Binding var selectedPath: String

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                // Pinned section
                if !self.projectStore.pinnedProjects.isEmpty {
                    self.sectionHeader("Pinned")
                    ForEach(self.projectStore.pinnedProjects) { project in
                        self.projectRow(
                            icon: "star.fill",
                            iconColor: .yellow.opacity(0.7),
                            name: project.displayName,
                            trailing: self.selectedPath == project.path
                                ? AnyView(Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundColor(.white.opacity(0.5)))
                                : nil,
                            isHighlighted: self.highlightedPath == project.path,
                            isSelected: self.selectedPath == project.path,
                        ) {
                            self.selectedPath = project.path
                            self.onSelect()
                        }
                    }
                }

                // Recent section
                if !self.projectStore.recentProjects.isEmpty {
                    if !self.projectStore.pinnedProjects.isEmpty {
                        Rectangle()
                            .fill(Color.white.opacity(0.06))
                            .frame(height: 1)
                            .padding(.horizontal, 4)
                    }
                    self.sectionHeader("Recent")
                    ForEach(self.projectStore.recentProjects) { project in
                        self.projectRow(
                            icon: "clock",
                            iconColor: .white.opacity(0.4),
                            name: project.displayName,
                            trailing: AnyView(
                                Text(SessionPhaseHelpers.timeAgo(project.lastUsedAt, now: Date()))
                                    .font(.system(size: 10))
                                    .foregroundColor(.white.opacity(0.3)),
                            ),
                            isHighlighted: self.highlightedPath == project.path,
                            isSelected: self.selectedPath == project.path,
                        ) {
                            self.selectedPath = project.path
                            self.onSelect()
                        }
                    }
                }

                // Empty state
                if self.projectStore.pinnedProjects.isEmpty, self.projectStore.recentProjects.isEmpty {
                    let homePath = FileManager.default.homeDirectoryForCurrentUser.path
                    self.projectRow(
                        icon: "house",
                        iconColor: .white.opacity(0.4),
                        name: "Home",
                        trailing: self.selectedPath == homePath
                            ? AnyView(Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundColor(.white.opacity(0.5)))
                            : nil,
                        isHighlighted: false,
                        isSelected: self.selectedPath == homePath,
                    ) {
                        self.selectedPath = homePath
                        self.onSelect()
                    }
                }

                // Browse
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 1)
                    .padding(.horizontal, 4)

                Button {
                    self.onBrowse()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.4))
                            .frame(width: 14)
                        Text("Browse...")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.5))
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxHeight: 200)
        .background(Color(red: 0.06, green: 0.06, blue: 0.12).opacity(0.98))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.1), lineWidth: 1),
        )
        .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
    }

    // MARK: Private

    private let onSelect: () -> Void
    private let onBrowse: () -> Void

    @State private var highlightedPath: String?
    private var projectStore = ProjectStore.shared

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(.white.opacity(0.25))
            .tracking(0.5)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }

    private func projectRow(
        icon: String,
        iconColor: Color,
        name: String,
        trailing: AnyView?,
        isHighlighted: Bool,
        isSelected: Bool,
        action: @escaping () -> Void,
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundColor(iconColor)
                    .frame(width: 14)

                Text(name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(isSelected ? 0.95 : 0.7))

                Spacer()

                if let trailing {
                    trailing
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                isSelected
                    ? Color(red: 0.04, green: 0.52, blue: 1.0).opacity(0.15)
                    : (isHighlighted ? Color.white.opacity(0.06) : Color.clear),
            )
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 2: Build both files together**

Run: `xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -3`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit both files**

```bash
git add ClaudeIsland/UI/Views/SessionLauncherView.swift ClaudeIsland/UI/Views/DirectoryPickerView.swift
git commit -m "feat: redesign session launcher with minimal Raycast-style layout"
```

---

## Task 3: Remove Esc Monitor from SessionLauncherPanel

**Goal:** Remove the local Escape key monitor from the panel since Esc is now handled in SwiftUI's `.onKeyPress(.escape)` on `SessionLauncherView`.

**Files:**
- Modify: `ClaudeIsland/UI/Window/SessionLauncherPanel.swift:137-143`

**Acceptance Criteria:**
- [ ] The `keyCode == 53` check is removed from `installMonitors()`
- [ ] The local monitor still exists for other potential key events (or is removed entirely if Esc was the only use)
- [ ] Esc still dismisses the panel (via SwiftUI -> onDismiss -> panel.dismiss)
- [ ] Click-outside still dismisses (global monitor unchanged)

**Verify:** `xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -3` -> BUILD SUCCEEDED

**Steps:**

- [ ] **Step 1: Remove the Esc key handling from installMonitors**

In `SessionLauncherPanel.swift`, the `installMonitors()` method (line 137) has a local monitor that only catches Esc (keyCode 53). Since that was its only purpose, remove the entire local monitor. Keep the global monitor for click-outside.

Replace `installMonitors()`:

```swift
    private func installMonitors() {
        self.globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard let self, self.isVisible else { return }
            if !self.frame.contains(NSEvent.mouseLocation) {
                self.dismiss()
            }
        }
    }
```

Remove the `localMonitor` property and its cleanup in `removeMonitors()`:

```swift
    private func removeMonitors() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
    }
```

Remove `private var localMonitor: Any?` from the properties.

Also remove `cancelOperation` override since Esc is handled in SwiftUI now:

Remove:
```swift
    override func cancelOperation(_: Any?) {
        self.dismiss()
    }
```

- [ ] **Step 2: Build**

Run: `xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -3`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add ClaudeIsland/UI/Window/SessionLauncherPanel.swift
git commit -m "fix: remove Esc monitor from panel, handled in SwiftUI now"
```

---

## Task 4: Lint + Format Pass

**Goal:** Run SwiftFormat and SwiftLint on the 3 modified files.

**Files:**
- All 3 modified files

**Acceptance Criteria:**
- [ ] `swiftformat` makes no further changes
- [ ] `swiftlint lint --strict` shows no violations in modified files

**Verify:** `swiftformat --lint ClaudeIsland/UI/Views/SessionLauncherView.swift ClaudeIsland/UI/Views/DirectoryPickerView.swift ClaudeIsland/UI/Window/SessionLauncherPanel.swift`

**Steps:**

- [ ] **Step 1: Run SwiftFormat**

```bash
swiftformat ClaudeIsland/UI/Views/SessionLauncherView.swift ClaudeIsland/UI/Views/DirectoryPickerView.swift ClaudeIsland/UI/Window/SessionLauncherPanel.swift
```

- [ ] **Step 2: Run SwiftLint**

```bash
swiftlint lint --strict ClaudeIsland/UI/Views/SessionLauncherView.swift ClaudeIsland/UI/Views/DirectoryPickerView.swift ClaudeIsland/UI/Window/SessionLauncherPanel.swift
```

Fix any violations.

- [ ] **Step 3: Commit if changes were made**

```bash
git add ClaudeIsland/UI/Views/SessionLauncherView.swift ClaudeIsland/UI/Views/DirectoryPickerView.swift ClaudeIsland/UI/Window/SessionLauncherPanel.swift
git commit -m "chore: fix lint and format for launcher redesign"
```

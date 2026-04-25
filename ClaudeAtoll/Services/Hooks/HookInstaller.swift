//
//  HookInstaller.swift
//  ClaudeAtoll
//
//  Auto-installs Claude Code hooks on app launch
//

import Darwin
import Foundation
import os.log

// MARK: - HookInstaller

// swiftlint:disable type_body_length
/// Hook installer — MainActor (default) protects static mutable state
/// This ensures thread-safe access to detectedRuntime across all call sites
enum HookInstaller {
    // MARK: Internal

    /// Cached detected runtime for command generation
    /// Protected by @MainActor isolation to prevent data races
    private(set) static var detectedRuntime: PythonRuntimeDetector.PythonRuntime?

    /// Install hook script and update settings.json on app launch
    /// Supports cooperative cancellation - checks Task.isCancelled at key points
    static func installIfNeeded() async {
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
        let hooksDir = claudeDir.appendingPathComponent("hooks")
        let pythonScript = hooksDir.appendingPathComponent(Self.hookScriptName)
        let legacyPythonScript = hooksDir.appendingPathComponent(Self.legacyHookScriptName)
        let settings = claudeDir.appendingPathComponent("settings.json")

        // Check for cancellation before file operations
        guard !Task.isCancelled else { return }

        try? FileManager.default.createDirectory(
            at: hooksDir,
            withIntermediateDirectories: true,
        )

        if let bundled = Bundle.main.url(forResource: "claude-atoll-state", withExtension: "py") {
            do {
                try FileManager.default.atomicCopy(from: bundled, to: pythonScript)
            } catch {
                Self.logger.error("Failed to install hook script: \(error.localizedDescription)")
            }
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: pythonScript.path,
            )
        }
        try? FileManager.default.removeItem(at: legacyPythonScript)

        // Check for cancellation before async runtime detection
        guard !Task.isCancelled else { return }

        await self.detectPythonRuntime()

        // Check for cancellation after async operation (state may have changed)
        guard !Task.isCancelled else { return }

        // Skip settings update if no runtime available (alert was already shown during detection)
        // Use ? suffix for optional pattern matching (required to match .some(.unavailable(...)))
        if case .unavailable? = self.detectedRuntime {
            return
        }
        await self.updateSettings(at: settings)
    }

    /// Check if hooks are currently installed
    static func isInstalled() -> Bool {
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
        let settings = claudeDir.appendingPathComponent("settings.json")

        guard let data = try? Data(contentsOf: settings),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any]
        else {
            return false
        }

        for (_, value) in hooks {
            if let entries = value as? [[String: Any]] {
                // Check both modern wrapped format and legacy direct format
                for entry in entries where self.containsClaudeAtollCommand(entry) {
                    return true
                }
            }
        }
        return false
    }

    /// Uninstall hooks from settings.json and remove script
    static func uninstall() async {
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
        let hooksDir = claudeDir.appendingPathComponent("hooks")
        let settings = claudeDir.appendingPathComponent("settings.json")

        for scriptName in Self.managedHookScriptNames {
            try? FileManager.default.removeItem(at: hooksDir.appendingPathComponent(scriptName))
        }

        await self.withLockedSettings(at: settings) { json in
            guard var hooks = json["hooks"] as? [String: Any] else {
                return
            }

            for (event, value) in hooks {
                if var entries = value as? [[String: Any]] {
                    // Remove both modern wrapped format and legacy direct format entries
                    entries.removeAll { entry in
                        self.containsClaudeAtollCommand(entry)
                    }

                    if entries.isEmpty {
                        hooks.removeValue(forKey: event)
                    } else {
                        hooks[event] = entries
                    }
                }
            }

            if hooks.isEmpty {
                json.removeValue(forKey: "hooks")
            } else {
                json["hooks"] = hooks
            }
        }
    }

    // MARK: Private

    private static let hookScriptName = "claude-atoll-state.py"
    private static let legacyHookScriptName = "claude-island-state.py"
    private static let managedHookScriptNames = [hookScriptName, legacyHookScriptName]

    nonisolated private static let logger = Logger(subsystem: "com.engels74.ClaudeAtoll", category: "HookInstaller")

    /// Perform a locked read-modify-write on a settings JSON file.
    /// Uses a sidecar `.lock` file with non-blocking `flock` + async retry loop.
    /// Falls back to unlocked access if the lock cannot be acquired.
    private static func withLockedSettings(
        at settingsURL: URL,
        body: (inout [String: Any]) -> Void,
    ) async {
        let maxRetries = 5
        let fd = open(settingsURL.path + ".lock", O_CREAT | O_WRONLY | O_CLOEXEC, 0o644)

        guard fd >= 0 else {
            FileManager.default.readModifyWriteJSON(at: settingsURL, body: body)
            return
        }
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }

        var locked = false
        for _ in 1 ... maxRetries {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { locked = true; break }
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }
        if !locked {
            Self.logger.warning("Could not acquire settings lock after \(maxRetries) retries; proceeding without lock")
        }

        FileManager.default.readModifyWriteJSON(at: settingsURL, body: body)
    }

    /// Detect the best available Python runtime
    private static func detectPythonRuntime() async {
        self.detectedRuntime = await PythonRuntimeDetector.shared.detectRuntime()

        // Already on MainActor, can call directly without wrapper
        // Use ? suffix for optional pattern matching (required to match .some(.unavailable(...)))
        if case let .unavailable(reason)? = detectedRuntime {
            PythonRuntimeAlert.showUnavailableAlert(reason: reason)
        }
    }

    private static func updateSettings(at settingsURL: URL) async {
        guard let runtime = detectedRuntime,
              let command = PythonRuntimeDetector.shared.getCommand(
                  for: "~/.claude/hooks/\(hookScriptName)",
                  runtime: runtime,
              )
        else {
            self.logger.warning("Skipping hook settings update - no suitable Python runtime")
            return
        }

        Self.logger.info("Using hook command: \(command)")

        await self.withLockedSettings(at: settingsURL) { json in
            var hooks = json["hooks"] as? [String: Any] ?? [:]
            let hookEvents = self.buildHookConfigurations(command: command)

            for (event, config) in hookEvents {
                hooks[event] = self.updateOrAddHookEntries(
                    existing: hooks[event] as? [[String: Any]],
                    config: config,
                    command: command,
                    eventName: event,
                )
            }

            // TODO(anthropics/claude-code#15897): Remove this cleanup call once PreToolUse is re-registered.
            // Remove managed entries from deprecated hook events (e.g. PreToolUse).
            // Preserves unrelated entries (e.g. rtk).
            self.removeDeprecatedHookEntries(from: &hooks)

            json["hooks"] = hooks
        }
    }

    /// Build hook configurations for all events
    private static func buildHookConfigurations(command: String) -> [(String, [[String: Any]])] {
        let hookEntry: [[String: Any]] = [["type": "command", "command": command]]
        let hookEntryWithTimeout: [[String: Any]] = [["type": "command", "command": command, "timeout": 86400]]
        let withMatcher: [[String: Any]] = [["matcher": "*", "hooks": hookEntry]]
        let withMatcherAndTimeout: [[String: Any]] = [["matcher": "*", "hooks": hookEntryWithTimeout]]
        let withoutMatcher: [[String: Any]] = [["hooks": hookEntry]]
        let preCompactConfig: [[String: Any]] = [
            ["matcher": "auto", "hooks": hookEntry],
            ["matcher": "manual", "hooks": hookEntry],
        ]

        // TODO(anthropics/claude-code#15897): Re-add ("PreToolUse", withMatcher) once upstream
        // fixes parallel hook updatedInput aggregation. Removed to prevent rtk interference.
        return [
            ("UserPromptSubmit", withoutMatcher),
            ("PostToolUse", withMatcher),
            ("PermissionRequest", withMatcherAndTimeout),
            ("Notification", withMatcher),
            ("Stop", withoutMatcher),
            ("SubagentStop", withoutMatcher),
            ("SessionStart", withoutMatcher),
            ("SessionEnd", withoutMatcher),
            ("PreCompact", preCompactConfig),
        ]
    }

    /// Update existing hook entries or add new ones, deduplicating managed entries by matcher
    private static func updateOrAddHookEntries(
        existing: [[String: Any]]?,
        config: [[String: Any]],
        command: String,
        eventName: String,
    ) -> [[String: Any]] {
        guard var existingEvent = existing else {
            return config
        }

        // First, remove any legacy direct format entries (not wrapped in "hooks")
        existingEvent.removeAll { self.isLegacyDirectEntry($0) }

        // Deduplicate and update managed entries, preserving user hooks
        let (updatedEntries, seenMatchers) = self.deduplicateClaudeAtollEntries(
            in: existingEvent, command: command, eventName: eventName,
        )
        existingEvent = updatedEntries

        // Add any missing configurations (matchers not already present)
        for configEntry in config {
            let configMatcher = (configEntry["matcher"] as? String) ?? ""
            if !seenMatchers.contains(configMatcher) {
                existingEvent.append(configEntry)
            }
        }

        return existingEvent
    }

    /// Deduplicate managed entries by matcher, merging user hooks from duplicates
    /// Returns updated entries and set of seen matchers
    private static func deduplicateClaudeAtollEntries(
        in entries: [[String: Any]],
        command: String,
        eventName: String,
    ) -> ([[String: Any]], Set<String>) {
        var result = entries
        var matcherToFirstIndex: [String: Int] = [:]
        var indicesToRemove = [Int]()

        for i in result.indices {
            guard var entryHooks = result[i]["hooks"] as? [[String: Any]],
                  self.isClaudeAtollHookEntry(entryHooks)
            else { continue }

            let matcherKey = (result[i]["matcher"] as? String) ?? ""

            if let firstIndex = matcherToFirstIndex[matcherKey] {
                // Duplicate - merge user hooks into first entry, then mark for removal
                self.mergeUserHooks(from: entryHooks, into: &result, at: firstIndex, eventName: eventName)
                indicesToRemove.append(i)
            } else {
                // First occurrence - update command and track matcher
                matcherToFirstIndex[matcherKey] = i
                self.updateClaudeAtollCommand(in: &entryHooks, to: command)
                result[i]["hooks"] = entryHooks
            }
        }

        // Remove duplicates in reverse order to preserve indices
        if !indicesToRemove.isEmpty {
            Self.logger.info("Removed \(indicesToRemove.count) duplicate Claude Atoll hook entry(ies) from \(eventName)")
            for index in indicesToRemove.reversed() {
                result.remove(at: index)
            }
        }

        return (result, Set(matcherToFirstIndex.keys))
    }

    /// Remove managed entries from hook events we no longer register on.
    /// Preserves unrelated entries (e.g. rtk's PreToolUse hooks).
    /// TODO(anthropics/claude-code#15897): Remove this method once PreToolUse is re-registered.
    private static func removeDeprecatedHookEntries(from hooks: inout [String: Any]) {
        let activeEvents = Set(self.buildHookConfigurations(command: "").map(\.0))
        let deprecatedEvents = ["PreToolUse"]

        for event in deprecatedEvents where !activeEvents.contains(event) {
            guard var entries = hooks[event] as? [[String: Any]] else { continue }

            // Remove legacy direct format entries
            entries.removeAll { self.isLegacyDirectEntry($0) }

            // For modern wrapped format: remove managed hooks from each entry,
            // but preserve entries that have unrelated hooks
            var indicesToRemove = [Int]()
            for i in entries.indices {
                guard var entryHooks = entries[i]["hooks"] as? [[String: Any]] else { continue }
                let hadClaudeAtoll = entryHooks.contains { hook in
                    self.isManagedHookCommand(hook["command"] as? String)
                }
                guard hadClaudeAtoll else { continue }

                entryHooks.removeAll { hook in
                    self.isManagedHookCommand(hook["command"] as? String)
                }

                if entryHooks.isEmpty {
                    indicesToRemove.append(i)
                } else {
                    entries[i]["hooks"] = entryHooks
                }
            }

            for index in indicesToRemove.reversed() {
                entries.remove(at: index)
            }

            if entries.isEmpty {
                hooks.removeValue(forKey: event)
                Self.logger.info("Removed deprecated Claude Atoll hook entries from \(event)")
            } else {
                hooks[event] = entries
                Self.logger.info("Cleaned Claude Atoll hooks from \(event), preserved \(entries.count) other entry(ies)")
            }
        }
    }

    /// Check if hooks array contains a managed hook
    private static func isClaudeAtollHookEntry(_ hooks: [[String: Any]]) -> Bool {
        hooks.contains { hook in
            self.isManagedHookCommand(hook["command"] as? String)
        }
    }

    /// Merge unrelated hooks from source into the target entry
    private static func mergeUserHooks(
        from sourceHooks: [[String: Any]],
        into entries: inout [[String: Any]],
        at targetIndex: Int,
        eventName: String,
    ) {
        let userHooks = sourceHooks.filter { hook in
            guard let cmd = hook["command"] as? String else { return true }
            return !self.isManagedHookCommand(cmd)
        }

        guard !userHooks.isEmpty,
              var targetHooks = entries[targetIndex]["hooks"] as? [[String: Any]]
        else { return }

        targetHooks.append(contentsOf: userHooks)
        entries[targetIndex]["hooks"] = targetHooks
        Self.logger.info("Merged \(userHooks.count) user hook(s) from duplicate entry in \(eventName)")
    }

    /// Update managed command in hooks array
    private static func updateClaudeAtollCommand(in hooks: inout [[String: Any]], to command: String) {
        for j in hooks.indices where self.isManagedHookCommand(hooks[j]["command"] as? String) {
            hooks[j]["command"] = command
        }
    }

    /// Check if entry is a legacy direct format (type: command at top level, not wrapped in hooks)
    private static func isLegacyDirectEntry(_ entry: [String: Any]) -> Bool {
        // Legacy format: {"type": "command", "command": "...claude-atoll-state.py..."}
        // Modern format: {"hooks": [{"type": "command", "command": "..."}]}
        if entry["hooks"] != nil {
            return false // This is the modern wrapped format
        }
        if let type = entry["type"] as? String, type == "command",
           let cmd = entry["command"] as? String,
           self.isManagedHookCommand(cmd) {
            return true
        }
        return false
    }

    /// Check if entry contains a Claude Atoll command (either wrapped or direct format)
    private static func containsClaudeAtollCommand(_ entry: [String: Any]) -> Bool {
        // Check modern wrapped format: {"hooks": [{"type": "command", "command": "..."}]}
        if let entryHooks = entry["hooks"] as? [[String: Any]] {
            for hook in entryHooks {
                if let cmd = hook["command"] as? String,
                   self.isManagedHookCommand(cmd) {
                    return true
                }
            }
        }
        // Check legacy direct format: {"type": "command", "command": "..."}
        if self.isLegacyDirectEntry(entry) {
            return true
        }
        return false
    }

    private static func isManagedHookCommand(_ command: String?) -> Bool {
        guard let command else { return false }
        return Self.managedHookScriptNames.contains { command.contains($0) }
    }
}

// swiftlint:enable type_body_length

// MARK: - SettingsIO

/// Logger holder for the FileManager extension (extensions on external types cannot have stored static properties)
private enum SettingsIO {
    nonisolated static let logger = Logger(subsystem: "com.engels74.ClaudeAtoll", category: "HookInstaller")
}

// MARK: - FileManager Atomic Operations

extension FileManager {
    /// Read a JSON file, apply a mutation via `body`, and atomic-write it back.
    /// Skips the write if `body` made no changes or the result is an empty object with no existing file.
    func readModifyWriteJSON(at fileURL: URL, body: (inout [String: Any]) -> Void) {
        let fileExisted = fileExists(atPath: fileURL.path)
        var json: [String: Any] = [:]
        let originalData: Data?
        if fileExisted,
           let data = try? Data(contentsOf: fileURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
            originalData = data
        } else {
            originalData = nil
        }

        body(&json)

        // Don't create a new file just to write an empty object
        if !fileExisted, json.isEmpty {
            return
        }

        guard let newData = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys],
        )
        else {
            return
        }

        // Skip write if content is unchanged
        if let originalData, newData == originalData {
            return
        }

        do {
            try self.atomicWrite(newData, to: fileURL)
        } catch {
            SettingsIO.logger.error("Failed to write \(fileURL.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Atomically write data to a file using write-to-temp + rename.
    /// Uses `replaceItemAt` when the target exists, `moveItem` for first-time creation.
    func atomicWrite(_ data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        let tempURL = directory.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: tempURL)
        do {
            if fileExists(atPath: destination.path) {
                _ = try replaceItemAt(destination, withItemAt: tempURL)
            } else {
                try moveItem(at: tempURL, to: destination)
            }
        } catch {
            try? removeItem(at: tempURL)
            throw error
        }
    }

    /// Atomically replace a file with a copy of the source using copy-to-temp + rename.
    /// Uses `replaceItemAt` when the target exists, `moveItem` for first-time creation.
    func atomicCopy(from source: URL, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        let tempURL = directory.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        try copyItem(at: source, to: tempURL)
        do {
            if fileExists(atPath: destination.path) {
                _ = try replaceItemAt(destination, withItemAt: tempURL)
            } else {
                try moveItem(at: tempURL, to: destination)
            }
        } catch {
            try? removeItem(at: tempURL)
            throw error
        }
    }
}

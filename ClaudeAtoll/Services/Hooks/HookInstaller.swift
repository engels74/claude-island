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

/// Hook installer — MainActor (default) protects static mutable state
/// This ensures thread-safe access to detectedRuntime across all call sites
enum HookInstaller {
    // MARK: Internal

    /// Cached detected runtime for command generation
    /// Protected by @MainActor isolation to prevent data races
    private(set) static var detectedRuntime: PythonRuntimeDetector.PythonRuntime?

    // MARK: Managed Hooks

    static let hookScriptName = "claude-atoll-state.py"
    static let legacyHookScriptName = "claude-island-state.py"
    static let managedHookScriptNames = [hookScriptName, legacyHookScriptName]

    /// Install hook script and update settings.json on app launch
    /// Supports cooperative cancellation - checks Task.isCancelled at key points
    static func installIfNeeded() async {
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
        let hooksDir = claudeDir.appendingPathComponent("hooks")
        let pythonScript = hooksDir.appendingPathComponent(Self.hookScriptName)
        let legacyPythonScript = hooksDir.appendingPathComponent(Self.legacyHookScriptName)
        let settings = claudeDir.appendingPathComponent("settings.json")
        var didInstallHookScript = false

        // Check for cancellation before file operations
        guard !Task.isCancelled else { return }

        try? FileManager.default.createDirectory(
            at: hooksDir,
            withIntermediateDirectories: true,
        )

        if let bundled = Bundle.main.url(forResource: "claude-atoll-state", withExtension: "py") {
            do {
                try FileManager.default.atomicCopy(from: bundled, to: pythonScript)
                do {
                    try FileManager.default.setAttributes(
                        [.posixPermissions: 0o755],
                        ofItemAtPath: pythonScript.path,
                    )
                } catch {
                    Self.logger.error("Failed to set executable permission on hook script: \(error.localizedDescription)")
                    return
                }
                didInstallHookScript = true
            } catch {
                Self.logger.error("Failed to install hook script: \(error.localizedDescription)")
            }
        }

        let hasHookScript = didInstallHookScript || FileManager.default.fileExists(atPath: pythonScript.path)
        if !hasHookScript {
            Self.logger.warning("Skipping hook settings update - hook script was not installed")
            return
        }

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
        let didUpdateSettings = await self.updateSettings(at: settings)
        if didInstallHookScript, didUpdateSettings {
            try? FileManager.default.removeItem(at: legacyPythonScript)
        }
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

        _ = await self.withLockedSettings(at: settings) { json in
            guard var hooks = json["hooks"] as? [String: Any] else {
                return
            }

            for (event, value) in hooks {
                if var entries = value as? [[String: Any]] {
                    self.removeClaudeAtollHooks(from: &entries)

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

    // MARK: Managed Hook Configuration

    /// Build hook configurations for all events
    static func buildHookConfigurations(command: String) -> [(String, [[String: Any]])] {
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

    // MARK: Private

    nonisolated private static let logger = Logger(subsystem: "com.engels74.ClaudeAtoll", category: "HookInstaller")

    /// Perform a locked read-modify-write on a settings JSON file.
    /// Uses a sidecar `.lock` file with non-blocking `flock` + async retry loop.
    /// Falls back to unlocked access if the lock cannot be acquired.
    private static func withLockedSettings(
        at settingsURL: URL,
        body: (inout [String: Any]) -> Void,
    ) async -> Bool {
        let maxRetries = 5
        let fd = open(settingsURL.path + ".lock", O_CREAT | O_WRONLY | O_CLOEXEC, 0o644)

        guard fd >= 0 else {
            return FileManager.default.readModifyWriteJSON(at: settingsURL, body: body)
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

        return FileManager.default.readModifyWriteJSON(at: settingsURL, body: body)
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

    private static func updateSettings(at settingsURL: URL) async -> Bool {
        guard let runtime = detectedRuntime,
              let command = PythonRuntimeDetector.shared.getCommand(
                  for: "~/.claude/hooks/\(hookScriptName)",
                  runtime: runtime,
              )
        else {
            self.logger.warning("Skipping hook settings update - no suitable Python runtime")
            return false
        }

        Self.logger.info("Using hook command: \(command)")

        return await self.withLockedSettings(at: settingsURL) { json in
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
}

// MARK: - SettingsIO

/// Logger holder for the FileManager extension (extensions on external types cannot have stored static properties)
private enum SettingsIO {
    nonisolated static let logger = Logger(subsystem: "com.engels74.ClaudeAtoll", category: "HookInstaller")
}

// MARK: - FileManager Atomic Operations

extension FileManager {
    /// Read a JSON file, apply a mutation via `body`, and atomic-write it back.
    /// Skips the write if `body` made no changes or the result is an empty object with no existing file.
    func readModifyWriteJSON(at fileURL: URL, body: (inout [String: Any]) -> Void) -> Bool {
        let fileExisted = fileExists(atPath: fileURL.path)
        var json: [String: Any] = [:]
        let originalData: Data?

        if fileExisted {
            let data: Data
            do {
                data = try Data(contentsOf: fileURL)
            } catch {
                SettingsIO.logger.error(
                    "Skipping JSON update for \(fileURL.lastPathComponent): failed to read existing file: \(error.localizedDescription)",
                )
                return false
            }

            do {
                let object = try JSONSerialization.jsonObject(with: data)
                guard let existing = object as? [String: Any] else {
                    SettingsIO.logger.error("Skipping JSON update for \(fileURL.lastPathComponent): existing file is not a JSON object")
                    return false
                }
                json = existing
                originalData = data
            } catch {
                SettingsIO.logger.error(
                    "Skipping JSON update for \(fileURL.lastPathComponent): failed to parse existing JSON: \(error.localizedDescription)",
                )
                return false
            }
        } else {
            originalData = nil
        }

        body(&json)

        // Don't create a new file just to write an empty object
        if !fileExisted, json.isEmpty {
            return true
        }

        let newData: Data
        do {
            newData = try JSONSerialization.data(
                withJSONObject: json,
                options: [.prettyPrinted, .sortedKeys],
            )
        } catch {
            SettingsIO.logger.error("Failed to serialize \(fileURL.lastPathComponent): \(error.localizedDescription)")
            return false
        }

        // Skip write if content is unchanged
        if let originalData, newData == originalData {
            return true
        }

        do {
            try self.atomicWrite(newData, to: fileURL)
            return true
        } catch {
            SettingsIO.logger.error("Failed to write \(fileURL.lastPathComponent): \(error.localizedDescription)")
            return false
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

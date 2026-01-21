//
//  HookInstaller.swift
//  ClaudeIsland
//
//  Auto-installs Claude Code hooks on app launch
//

import Foundation
import os.log

/// Logger for hook installation
private let logger = Logger(subsystem: "com.engels74.ClaudeIsland", category: "HookInstaller")

// MARK: - HookInstaller

enum HookInstaller {
    // MARK: Internal

    /// Cached detected runtime for command generation
    private(set) static var detectedRuntime: PythonRuntimeDetector.PythonRuntime?

    /// Install hook script and update settings.json on app launch
    static func installIfNeeded() async {
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
        let hooksDir = claudeDir.appendingPathComponent("hooks")
        let pythonScript = hooksDir.appendingPathComponent("claude-island-state.py")
        let settings = claudeDir.appendingPathComponent("settings.json")

        try? FileManager.default.createDirectory(
            at: hooksDir,
            withIntermediateDirectories: true
        )

        if let bundled = Bundle.main.url(forResource: "claude-island-state", withExtension: "py") {
            try? FileManager.default.removeItem(at: pythonScript)
            try? FileManager.default.copyItem(at: bundled, to: pythonScript)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: pythonScript.path
            )
        }

        await self.detectPythonRuntime()

        // Only update settings if a runtime is available
        guard case .unavailable = self.detectedRuntime else {
            self.updateSettings(at: settings)
            return
        }
        // Don't update settings if no runtime available - alert was already shown
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
                for entry in entries {
                    if let entryHooks = entry["hooks"] as? [[String: Any]] {
                        for hook in entryHooks {
                            if let cmd = hook["command"] as? String,
                               cmd.contains("claude-island-state.py") {
                                return true
                            }
                        }
                    }
                }
            }
        }
        return false
    }

    /// Uninstall hooks from settings.json and remove script
    static func uninstall() {
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
        let hooksDir = claudeDir.appendingPathComponent("hooks")
        let pythonScript = hooksDir.appendingPathComponent("claude-island-state.py")
        let settings = claudeDir.appendingPathComponent("settings.json")

        try? FileManager.default.removeItem(at: pythonScript)

        guard let data = try? Data(contentsOf: settings),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = json["hooks"] as? [String: Any]
        else {
            return
        }

        for (event, value) in hooks {
            if var entries = value as? [[String: Any]] {
                entries.removeAll { entry in
                    if let entryHooks = entry["hooks"] as? [[String: Any]] {
                        return entryHooks.contains { hook in
                            let cmd = hook["command"] as? String ?? ""
                            return cmd.contains("claude-island-state.py")
                        }
                    }
                    return false
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

        if let data = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: settings)
        }
    }

    // MARK: Private

    /// Detect the best available Python runtime
    private static func detectPythonRuntime() async {
        self.detectedRuntime = await PythonRuntimeDetector.shared.detectRuntime()

        if case let .unavailable(reason) = detectedRuntime {
            await MainActor.run {
                PythonRuntimeAlert.showUnavailableAlert(reason: reason)
            }
        }
    }

    private static func updateSettings(at settingsURL: URL) {
        guard let runtime = detectedRuntime,
              let command = PythonRuntimeDetector.shared.getCommand(
                  for: "~/.claude/hooks/claude-island-state.py",
                  runtime: runtime
              )
        else {
            logger.warning("Skipping hook settings update - no suitable Python runtime")
            return
        }

        logger.info("Using hook command: \(command)")

        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }

        var hooks = json["hooks"] as? [String: Any] ?? [:]
        let hookEvents = self.buildHookConfigurations(command: command)

        for (event, config) in hookEvents {
            hooks[event] = self.updateOrAddHookEntries(
                existing: hooks[event] as? [[String: Any]],
                config: config,
                command: command
            )
        }

        json["hooks"] = hooks

        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: settingsURL)
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

        return [
            ("UserPromptSubmit", withoutMatcher),
            ("PreToolUse", withMatcher),
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

    /// Update existing hook entries or add new ones
    private static func updateOrAddHookEntries(
        existing: [[String: Any]]?,
        config: [[String: Any]],
        command: String
    ) -> [[String: Any]] {
        guard var existingEvent = existing else {
            return config
        }

        var updated = false
        for i in existingEvent.indices {
            if var entry = existingEvent[i] as? [String: Any],
               var entryHooks = entry["hooks"] as? [[String: Any]] {
                for j in entryHooks.indices {
                    if var hook = entryHooks[j] as? [String: Any],
                       let cmd = hook["command"] as? String,
                       cmd.contains("claude-island-state.py") {
                        hook["command"] = command
                        entryHooks[j] = hook
                        updated = true
                    }
                }
                entry["hooks"] = entryHooks
                existingEvent[i] = entry
            }
        }

        if !updated {
            existingEvent.append(contentsOf: config)
        }
        return existingEvent
    }
}

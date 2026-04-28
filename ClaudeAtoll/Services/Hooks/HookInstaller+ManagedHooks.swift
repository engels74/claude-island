//
//  HookInstaller+ManagedHooks.swift
//  ClaudeAtoll
//
//  Helpers for matching, updating, and removing app-managed Claude Code hooks
//

import Foundation
import os.log

// MARK: - HookInstaller Managed Hooks

extension HookInstaller {
    /// Update existing hook entries or add new ones, deduplicating managed entries by matcher
    static func updateOrAddHookEntries(
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

    /// Remove managed entries from hook events we no longer register on.
    /// Preserves unrelated entries (e.g. rtk's PreToolUse hooks).
    /// TODO(anthropics/claude-code#15897): Remove this method once PreToolUse is re-registered.
    static func removeDeprecatedHookEntries(from hooks: inout [String: Any]) {
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
                HookInstallerManagedHooksLogger.logger.info("Removed deprecated Claude Atoll hook entries from \(event)")
            } else {
                hooks[event] = entries
                HookInstallerManagedHooksLogger.logger
                    .info("Cleaned Claude Atoll hooks from \(event), preserved \(entries.count) other entry(ies)")
            }
        }
    }

    /// Check if entry contains a Claude Atoll command (either wrapped or direct format)
    static func containsClaudeAtollCommand(_ entry: [String: Any]) -> Bool {
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

    /// Remove managed hooks from entries while preserving unrelated user hooks.
    static func removeClaudeAtollHooks(from entries: inout [[String: Any]]) {
        entries.removeAll { self.isLegacyDirectEntry($0) }

        var indicesToRemove = [Int]()
        for i in entries.indices {
            guard var entryHooks = entries[i]["hooks"] as? [[String: Any]] else { continue }
            let originalCount = entryHooks.count

            entryHooks.removeAll { hook in
                self.isManagedHookCommand(hook["command"] as? String)
            }
            guard entryHooks.count != originalCount else { continue }

            if entryHooks.isEmpty {
                indicesToRemove.append(i)
            } else {
                entries[i]["hooks"] = entryHooks
            }
        }

        for index in indicesToRemove.reversed() {
            entries.remove(at: index)
        }
    }

    /// Deduplicate managed entries by matcher, merging user hooks from duplicates.
    /// Returns updated entries and set of seen matchers.
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
            HookInstallerManagedHooksLogger.logger
                .info("Removed \(indicesToRemove.count) duplicate Claude Atoll hook entry(ies) from \(eventName)")
            for index in indicesToRemove.reversed() {
                result.remove(at: index)
            }
        }

        return (result, Set(matcherToFirstIndex.keys))
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
        HookInstallerManagedHooksLogger.logger.info("Merged \(userHooks.count) user hook(s) from duplicate entry in \(eventName)")
    }

    /// Update a single managed command in hooks array, removing duplicate managed hooks
    private static func updateClaudeAtollCommand(in hooks: inout [[String: Any]], to command: String) {
        let retainedIndex = hooks.firstIndex { hook in
            guard let hookCommand = hook["command"] as? String else { return false }
            return hookCommand.contains(Self.hookScriptName)
        } ?? hooks.firstIndex { hook in
            self.isManagedHookCommand(hook["command"] as? String)
        }

        guard let retainedIndex else { return }

        var updatedHooks = [[String: Any]]()
        updatedHooks.reserveCapacity(hooks.count)
        for (index, hook) in hooks.enumerated() {
            if index == retainedIndex {
                var updatedHook = hook
                updatedHook["command"] = command
                updatedHooks.append(updatedHook)
            } else if !self.isManagedHookCommand(hook["command"] as? String) {
                updatedHooks.append(hook)
            }
        }
        hooks = updatedHooks
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

    private static func isManagedHookCommand(_ command: String?) -> Bool {
        guard let command else { return false }
        return Self.managedHookScriptNames.contains { command.contains($0) }
    }
}

// MARK: - HookInstallerManagedHooksLogger

private enum HookInstallerManagedHooksLogger {
    nonisolated static let logger = Logger(subsystem: "com.engels74.ClaudeAtoll", category: "HookInstaller")
}

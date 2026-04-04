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
        let tmuxPath = try await self.validatePreconditions(directory: directory)
        let resolvedName = await self.resolveSessionName(sessionName, tmuxPath: tmuxPath)

        let provisionalID = UUID().uuidString
        let payload = SessionLaunchPayload(
            sessionID: provisionalID,
            sessionName: resolvedName,
            cwd: directory,
            prompt: prompt,
            commandTemplate: commandTemplate,
        )
        await SessionStore.shared.process(.sessionLaunching(payload))

        try await self.createTmuxSession(
            tmuxPath: tmuxPath,
            sessionName: resolvedName,
            directory: directory,
            provisionalID: provisionalID,
        )

        try await self.sendClaudeCommand(
            tmuxPath: tmuxPath,
            sessionName: resolvedName,
            directory: directory,
            commandTemplate: commandTemplate,
            provisionalID: provisionalID,
        )

        let hookReceived = await self.waitForHookMerge(provisionalID: provisionalID, timeout: 15.0)
        guard hookReceived else {
            await SessionStore.shared.process(.launchFailed(
                sessionID: provisionalID,
                error: .claudeStartTimeout,
            ))
            throw .claudeStartTimeout
        }

        await SessionStore.shared.process(.launchProgressUpdated(
            sessionID: provisionalID,
            progress: .sendingPrompt,
        ))

        await self.sendPromptIfNeeded(prompt: prompt, tmuxPath: tmuxPath, sessionName: resolvedName)
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

    private func validatePreconditions(directory: String) async throws(LaunchError) -> String {
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
        return tmuxPath
    }

    private func createTmuxSession(
        tmuxPath: String,
        sessionName: String,
        directory: String,
        provisionalID: String,
    ) async throws(LaunchError) {
        await SessionStore.shared.process(.launchProgressUpdated(
            sessionID: provisionalID,
            progress: .creatingTmuxSession,
        ))
        do {
            _ = try await ProcessExecutor.shared.run(tmuxPath, arguments: [
                "new-session", "-d", "-s", sessionName, "-c", directory,
            ])
        } catch {
            await SessionStore.shared.process(.launchFailed(
                sessionID: provisionalID,
                error: .tmuxSessionCreationFailed(error.localizedDescription),
            ))
            throw .tmuxSessionCreationFailed(error.localizedDescription)
        }
    }

    private func sendClaudeCommand(
        tmuxPath: String,
        sessionName: String,
        directory: String,
        commandTemplate: String,
        provisionalID: String,
    ) async throws(LaunchError) {
        await SessionStore.shared.process(.launchProgressUpdated(
            sessionID: provisionalID,
            progress: .startingClaude,
        ))
        let resolvedCommand = self.resolveTemplate(commandTemplate, name: sessionName, directory: directory)
        do {
            _ = try await ProcessExecutor.shared.run(tmuxPath, arguments: [
                "send-keys", "-t", sessionName, "-l", resolvedCommand,
            ])
            _ = try await ProcessExecutor.shared.run(tmuxPath, arguments: [
                "send-keys", "-t", sessionName, "Enter",
            ])
            await SessionStore.shared.process(.launchProgressUpdated(
                sessionID: provisionalID,
                progress: .waitingForHook,
            ))
        } catch {
            await SessionStore.shared.process(.launchFailed(
                sessionID: provisionalID,
                error: .promptSendFailed(error.localizedDescription),
            ))
            throw .promptSendFailed(error.localizedDescription)
        }
    }

    private func sendPromptIfNeeded(prompt: String, tmuxPath: String, sessionName: String) async {
        guard !prompt.isEmpty else { return }
        try? await Task.sleep(for: .milliseconds(200))
        do {
            _ = try await ProcessExecutor.shared.run(tmuxPath, arguments: [
                "send-keys", "-t", sessionName, "-l", prompt,
            ])
            _ = try await ProcessExecutor.shared.run(tmuxPath, arguments: [
                "send-keys", "-t", sessionName, "Enter",
            ])
        } catch {
            Self.logger.warning("Failed to send prompt: \(error.localizedDescription, privacy: .public)")
        }
    }

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

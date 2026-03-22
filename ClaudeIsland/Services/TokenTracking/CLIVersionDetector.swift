//
//  CLIVersionDetector.swift
//  ClaudeIsland
//
//  Detects the installed Claude CLI version for dynamic User-Agent strings
//  Follows PythonRuntimeDetector.swift pattern for actor structure, caching, and reentrancy-safe detection
//

import Foundation
import os.log

// MARK: - CLIVersionDetector

/// Actor that detects the Claude CLI version with caching
/// Follows PythonRuntimeDetector.swift pattern for executable discovery
actor CLIVersionDetector {
    // MARK: Lifecycle

    private init() {}

    // MARK: Internal

    static let shared = CLIVersionDetector()

    /// Returns a User-Agent string based on the detected CLI version.
    /// Uses `"claude-code/{version}"` when the CLI is found, otherwise falls back
    /// to `"claude-island/{bundleVersion}"`.
    func userAgent() async -> String {
        let version = await detectVersion()
        if let version {
            return "claude-code/\(version)"
        }
        let bundleVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        return "claude-island/\(bundleVersion)"
    }

    // MARK: Private

    /// Logger for CLI version detection
    nonisolated private static let logger = Logger(subsystem: "com.engels74.ClaudeIsland", category: "CLIVersionDetector")

    /// Cached detection result
    private var cachedVersion: String??

    /// In-flight detection task (reentrancy-safe pattern per Swift guidelines)
    private var detectionTask: Task<String?, Never>?

    /// Detect CLI version (cached after first call)
    private func detectVersion() async -> String? {
        // Return cached result if available
        if let cached = cachedVersion {
            return cached
        }

        // If detection already in progress, await existing task (reentrancy-safe)
        if let existingTask = detectionTask {
            return await existingTask.value
        }

        // Start new detection task, store BEFORE await (per Swift guidelines)
        let task = Task(name: "detect-cli-version") { await self.performDetection() }
        self.detectionTask = task

        let version = await task.value
        self.cachedVersion = .some(version)
        self.detectionTask = nil
        return version
    }

    /// Perform the actual CLI version detection
    private func performDetection() async -> String? {
        Self.logger.info("Starting Claude CLI version detection")

        guard let claudePath = await findClaudeBinary() else {
            Self.logger.warning("Claude CLI binary not found")
            return nil
        }

        Self.logger.info("Found Claude CLI at \(claudePath)")

        let result = await ProcessExecutor.shared.runWithResult(claudePath, arguments: ["--version"])
        guard case let .success(processResult) = result, processResult.isSuccess else {
            Self.logger.warning("Failed to run claude --version")
            return nil
        }

        let output = processResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let version = parseVersion(from: output) else {
            Self.logger.warning("Failed to parse version from output: \(output)")
            return nil
        }

        Self.logger.info("Detected Claude CLI version: \(version)")
        return version
    }

    /// Find the claude binary by checking known paths, then falling back to `which`
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

        // Fallback to which
        let result = await ProcessExecutor.shared.runWithResult("/usr/bin/which", arguments: ["claude"])
        if case let .success(processResult) = result, processResult.isSuccess {
            let path = processResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty && FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        return nil
    }

    /// Parse version from `claude --version` output, stripping ANSI escape codes
    private func parseVersion(from output: String) -> String? {
        // Strip ANSI escape codes (e.g., color codes from terminal output)
        let ansiPattern = #"\x1B\[[0-9;]*[a-zA-Z]"#
        let stripped = output.replacingOccurrences(
            of: ansiPattern,
            with: "",
            options: .regularExpression,
        )

        // Extract first version-like token (e.g., "1.2.3" or "1.2.3-beta.1")
        let versionPattern = #"(\d+\.\d+\.\d+(?:[-+][a-zA-Z0-9.]+)*)"#
        guard let regex = try? NSRegularExpression(pattern: versionPattern),
              let match = regex.firstMatch(
                  in: stripped,
                  range: NSRange(stripped.startIndex..., in: stripped),
              ),
              let versionRange = Range(match.range(at: 1), in: stripped)
        else {
            return nil
        }

        return String(stripped[versionRange])
    }
}

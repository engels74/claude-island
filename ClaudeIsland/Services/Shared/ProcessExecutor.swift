//
//  ProcessExecutor.swift
//  ClaudeIsland
//
//  Shared utility for executing shell commands with proper error handling
//

import Foundation
import os.log

// MARK: - ProcessExecutorError

/// Errors that can occur during process execution
enum ProcessExecutorError: Error, LocalizedError {
    case executionFailed(command: String, exitCode: Int32, stderr: String?)
    case invalidOutput(command: String)
    case commandNotFound(String)
    case launchFailed(command: String, underlying: Error)

    // MARK: Internal

    var errorDescription: String? {
        switch self {
        case let .executionFailed(command, exitCode, stderr):
            let stderrInfo = stderr.map { ", stderr: \($0)" } ?? ""
            return "Command '\(command)' failed with exit code \(exitCode)\(stderrInfo)"
        case let .invalidOutput(command):
            return "Command '\(command)' produced invalid output"
        case let .commandNotFound(command):
            return "Command not found: \(command)"
        case let .launchFailed(command, underlying):
            return "Failed to launch '\(command)': \(underlying.localizedDescription)"
        }
    }
}

// MARK: - ProcessResult

/// Result type for process execution
struct ProcessResult: Sendable {
    let output: String
    let exitCode: Int32
    let stderr: String?

    var isSuccess: Bool { self.exitCode == 0 }
}

// MARK: - ProcessExecuting

/// Protocol for executing shell commands (enables testing)
protocol ProcessExecuting: Sendable {
    func run(_ executable: String, arguments: [String]) async throws -> String
    func runWithResult(_ executable: String, arguments: [String]) async -> Result<ProcessResult, ProcessExecutorError>
    func runSync(_ executable: String, arguments: [String]) -> Result<String, ProcessExecutorError>
}

// MARK: - ProcessExecutor

/// Default implementation using Foundation.Process
actor ProcessExecutor: ProcessExecuting {
    // MARK: Lifecycle

    private init() {}

    // MARK: Internal

    /// Shared instance - actors are inherently thread-safe and static let is lazily initialized
    /// with thread-safety guaranteed by Swift, so no special annotations are needed.
    static let shared = ProcessExecutor()

    /// Logger for process execution (nonisolated static for cross-context access)
    nonisolated static let logger = Logger(subsystem: "com.engels74.ClaudeIsland", category: "ProcessExecutor")

    /// Run a command asynchronously and return output (throws on failure)
    func run(_ executable: String, arguments: [String]) async throws -> String {
        let result = await runWithResult(executable, arguments: arguments)
        switch result {
        case let .success(processResult):
            return processResult.output
        case let .failure(error):
            throw error
        }
    }

    /// Run a command asynchronously and return a full Result with exit code and stderr
    ///
    /// Note: Blocking operations (waitUntilExit, readDataToEndOfFile) are dispatched to a background
    /// queue to avoid blocking the cooperative thread pool.
    func runWithResult(_ executable: String, arguments: [String]) async -> Result<ProcessResult, ProcessExecutorError> {
        await withCheckedContinuation { continuation in
            // Dispatch blocking work to background queue to avoid exhausting cooperative thread pool
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()

                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                    process.waitUntilExit()

                    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                    let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                    let stderr = String(data: stderrData, encoding: .utf8)

                    let result = ProcessResult(
                        output: stdout,
                        exitCode: process.terminationStatus,
                        stderr: stderr
                    )

                    if process.terminationStatus == 0 {
                        continuation.resume(returning: .success(result))
                    } else {
                        Self.logger
                            .warning(
                                "Command failed: \(executable) \(arguments.joined(separator: " "), privacy: .public) - exit code \(process.terminationStatus)"
                            )
                        continuation.resume(returning: .failure(.executionFailed(
                            command: executable,
                            exitCode: process.terminationStatus,
                            stderr: stderr
                        )))
                    }
                } catch let error as NSError {
                    if error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
                        Self.logger.error("Command not found: \(executable, privacy: .public)")
                        continuation.resume(returning: .failure(.commandNotFound(executable)))
                    } else {
                        Self.logger
                            .error("Failed to launch command: \(executable, privacy: .public) - \(error.localizedDescription, privacy: .public)")
                        continuation.resume(returning: .failure(.launchFailed(command: executable, underlying: error)))
                    }
                } catch {
                    Self.logger.error("Failed to launch command: \(executable, privacy: .public) - \(error.localizedDescription, privacy: .public)")
                    continuation.resume(returning: .failure(.launchFailed(command: executable, underlying: error)))
                }
            }
        }
    }

    /// Run a command synchronously (for use in nonisolated contexts)
    /// Returns Result instead of optional for better error handling
    ///
    /// - Important: This method performs blocking I/O and must not be called from the main thread.
    ///   Use `run()` or `runWithResult()` async methods instead for main thread contexts.
    nonisolated func runSync(_ executable: String, arguments: [String]) -> Result<String, ProcessExecutorError> {
        precondition(!Thread.isMainThread, "runSync must not be called on main thread - use async run() instead")
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
            let stderr = String(data: stderrData, encoding: .utf8)

            if process.terminationStatus == 0 {
                return .success(stdout)
            } else {
                Self.logger.warning("Sync command failed: \(executable, privacy: .public) - exit code \(process.terminationStatus)")
                return .failure(.executionFailed(
                    command: executable,
                    exitCode: process.terminationStatus,
                    stderr: stderr
                ))
            }
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
                Self.logger.error("Command not found: \(executable, privacy: .public)")
                return .failure(.commandNotFound(executable))
            } else {
                Self.logger.error("Sync command launch failed: \(executable, privacy: .public) - \(error.localizedDescription, privacy: .public)")
                return .failure(.launchFailed(command: executable, underlying: error))
            }
        } catch {
            Self.logger.error("Sync command launch failed: \(executable, privacy: .public) - \(error.localizedDescription, privacy: .public)")
            return .failure(.launchFailed(command: executable, underlying: error))
        }
    }
}

// MARK: - Convenience Extensions

extension ProcessExecutor {
    /// Run a command and return output, returning nil only if the command itself fails to execute
    /// (as opposed to non-zero exit codes which may still have useful output)
    func runOrNil(_ executable: String, arguments: [String]) async -> String? {
        let result = await runWithResult(executable, arguments: arguments)
        switch result {
        case let .success(processResult):
            return processResult.output
        case .failure:
            return nil
        }
    }

    /// Run a command synchronously, returning nil on failure (backwards compatible)
    nonisolated func runSyncOrNil(_ executable: String, arguments: [String]) -> String? {
        switch self.runSync(executable, arguments: arguments) {
        case let .success(output):
            output
        case .failure:
            nil
        }
    }
}

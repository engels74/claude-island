//
//  FileSyncScheduler.swift
//  ClaudeIsland
//
//  Handles debounced file sync scheduling for session JSONL files.
//  Extracted from SessionStore to reduce complexity.
//

import Foundation
import os.log

/// Manages debounced file sync operations for session data
actor FileSyncScheduler {
    // MARK: Internal

    /// Callback type for when a sync should be performed
    typealias SyncHandler = @Sendable (String, String) async -> Void

    /// Logger for file sync (nonisolated static for cross-context access)
    nonisolated static let logger = Logger(subsystem: "com.claudeisland", category: "FileSync")

    /// Schedule a debounced file sync for a session
    /// - Parameters:
    ///   - sessionId: The session to sync
    ///   - cwd: The working directory
    ///   - handler: Callback to perform the actual sync
    func schedule(sessionID: String, cwd: String, handler: @escaping SyncHandler) {
        // Cancel existing pending sync
        cancel(sessionID: sessionID)

        // Schedule new debounced sync
        pendingSyncs[sessionID] = Task { [debounceNs] in
            try? await Task.sleep(nanoseconds: debounceNs)
            guard !Task.isCancelled else { return }

            Self.logger.debug("Executing sync for session \(sessionID.prefix(8), privacy: .public)")
            await handler(sessionID, cwd)
        }
    }

    /// Cancel any pending sync for a session
    func cancel(sessionID: String) {
        if let existing = pendingSyncs.removeValue(forKey: sessionID) {
            existing.cancel()
            Self.logger.debug("Cancelled pending sync for session \(sessionID.prefix(8), privacy: .public)")
        }
    }

    /// Cancel all pending syncs
    func cancelAll() {
        for (_, task) in pendingSyncs {
            task.cancel()
        }
        pendingSyncs.removeAll()
    }

    /// Check if a sync is pending for a session
    func hasPendingSync(sessionID: String) -> Bool {
        pendingSyncs[sessionID] != nil
    }

    // MARK: Private

    /// Pending sync tasks keyed by sessionID
    private var pendingSyncs: [String: Task<Void, Never>] = [:]

    /// Debounce interval in nanoseconds (100ms)
    private let debounceNs: UInt64 = 100_000_000
}

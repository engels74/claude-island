//
//  SessionStore+PeriodicCheck.swift
//  ClaudeIsland
//
//  Periodic session status checking to detect terminated processes.
//

import Foundation

extension SessionStore {
    // MARK: - Periodic Status Check

    /// Start periodic status checking
    func startPeriodicStatusCheck() {
        guard statusCheckTask == nil else { return }

        statusCheckTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self.statusCheckIntervalNs)
                guard !Task.isCancelled else { break }
                await self.recheckAllSessions()
            }
        }
    }

    /// Stop periodic status checking
    func stopPeriodicStatusCheck() {
        statusCheckTask?.cancel()
        statusCheckTask = nil
    }

    /// Check all sessions for process termination
    func recheckAllSessions() async {
        for (sessionID, session) in sessions {
            // Skip ended sessions
            guard session.phase != .ended else { continue }

            // Check if process is still running
            if let pid = session.pid, !isProcessRunning(pid: pid) {
                await process(.sessionEnded(sessionID: sessionID))
                continue
            }

            // Refresh state for active sessions
            if session.phase == .processing || session.phase.isWaitingForApproval {
                scheduleFileSync(sessionID: sessionID, cwd: session.cwd)
            }
        }
    }

    /// Check if a process is running using kill(pid, 0)
    nonisolated func isProcessRunning(pid: Int) -> Bool {
        kill(Int32(pid), 0) == 0
    }
}

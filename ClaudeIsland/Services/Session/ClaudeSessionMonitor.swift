//
//  ClaudeSessionMonitor.swift
//  ClaudeIsland
//
//  MainActor wrapper around SessionStore for UI binding.
//  Uses @Observable for efficient property-level change tracking (macOS 14+).
//

import AppKit
import Combine
import Foundation
import Observation

// MARK: - ClaudeSessionMonitor

/// Session monitor using modern @Observable macro for efficient SwiftUI updates.
/// Subscribes to SessionStore's Combine publisher to receive session state changes.
@Observable
@MainActor
final class ClaudeSessionMonitor {
    // MARK: Lifecycle

    init() {
        SessionStore.shared.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.updateFromSessions(sessions)
            }
            .store(in: &self.cancellables)

        InterruptWatcherManager.shared.delegate = self
    }

    // MARK: Internal

    var instances: [SessionState] = []
    var pendingInstances: [SessionState] = []

    // MARK: - Monitoring Lifecycle

    func startMonitoring() {
        HookSocketServer.shared.start(
            onEvent: { [weak self] event in
                // HookSocketServer calls this callback on its internal socket queue.
                // We must hop to MainActor before accessing self (a @MainActor type).
                Task { @MainActor [weak self] in
                    guard let self else { return }

                    let task = Task {
                        await SessionStore.shared.process(.hookReceived(event))
                    }
                    self.trackTask(task)

                    if event.sessionPhase == .processing {
                        let watchTask = Task { @MainActor in
                            InterruptWatcherManager.shared.startWatching(
                                sessionID: event.sessionID,
                                cwd: event.cwd
                            )
                        }
                        self.trackTask(watchTask)
                    }

                    if event.status == "ended" {
                        let stopTask = Task { @MainActor in
                            InterruptWatcherManager.shared.stopWatching(sessionID: event.sessionID)
                        }
                        self.trackTask(stopTask)
                    }

                    if event.event == "Stop" {
                        HookSocketServer.shared.cancelPendingPermissions(sessionID: event.sessionID)
                    }

                    if event.event == "PostToolUse", let toolUseID = event.toolUseID {
                        HookSocketServer.shared.cancelPendingPermission(toolUseID: toolUseID)
                    }
                }
            },
            onPermissionFailure: { [weak self] sessionID, toolUseID in
                // Same as above - hop to MainActor before accessing self
                Task { @MainActor [weak self] in
                    guard let self else { return }

                    let task = Task {
                        await SessionStore.shared.process(
                            .permissionSocketFailed(sessionID: sessionID, toolUseID: toolUseID)
                        )
                    }
                    self.trackTask(task)
                }
            }
        )

        // Start periodic session status check
        Task {
            await SessionStore.shared.startPeriodicStatusCheck()
        }
    }

    func stopMonitoring() {
        self.cancelAllTasks()
        HookSocketServer.shared.stop()

        // Stop periodic session status check
        Task {
            await SessionStore.shared.stopPeriodicStatusCheck()
        }
    }

    // MARK: - Permission Handling

    func approvePermission(sessionID: String) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionID),
                  let permission = session.activePermission
            else {
                return
            }

            HookSocketServer.shared.respondToPermission(
                toolUseID: permission.toolUseID,
                decision: "allow"
            )

            await SessionStore.shared.process(
                .permissionApproved(sessionID: sessionID, toolUseID: permission.toolUseID)
            )
        }
    }

    func denyPermission(sessionID: String, reason: String?) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionID),
                  let permission = session.activePermission
            else {
                return
            }

            HookSocketServer.shared.respondToPermission(
                toolUseID: permission.toolUseID,
                decision: "deny",
                reason: reason
            )

            await SessionStore.shared.process(
                .permissionDenied(sessionID: sessionID, toolUseID: permission.toolUseID, reason: reason)
            )
        }
    }

    /// Archive (remove) a session from the instances list
    func archiveSession(sessionID: String) {
        Task {
            await SessionStore.shared.process(.sessionEnded(sessionID: sessionID))
        }
    }

    // MARK: - History Loading (for UI)

    /// Request history load for a session
    func loadHistory(sessionID: String, cwd: String) {
        Task {
            await SessionStore.shared.process(.loadHistory(sessionID: sessionID, cwd: cwd))
        }
    }

    // MARK: Private

    /// Combine subscriptions - ignored by Observation since these don't affect UI state
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()

    /// Active tasks that should be cancelled when monitoring stops
    @ObservationIgnored private var activeTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private let tasksLock = NSLock()

    /// Track a task for cancellation on stop
    private func trackTask(_ task: Task<Void, Never>) {
        let id = UUID()
        self.tasksLock.lock()
        self.activeTasks[id] = task
        self.tasksLock.unlock()

        // Auto-remove when task completes
        Task {
            _ = await task.result
            self.tasksLock.lock()
            self.activeTasks.removeValue(forKey: id)
            self.tasksLock.unlock()
        }
    }

    /// Cancel all tracked tasks
    private func cancelAllTasks() {
        self.tasksLock.lock()
        let tasks = self.activeTasks.values
        self.activeTasks.removeAll()
        self.tasksLock.unlock()

        for task in tasks {
            task.cancel()
        }
    }

    // MARK: - State Update

    private func updateFromSessions(_ sessions: [SessionState]) {
        self.instances = sessions
        self.pendingInstances = sessions.filter(\.needsAttention)
    }
}

// MARK: JSONLInterruptWatcherDelegate

extension ClaudeSessionMonitor: JSONLInterruptWatcherDelegate {
    nonisolated func didDetectInterrupt(sessionID: String) {
        // Combined task for interrupt handling - both actions should complete together
        Task { @MainActor in
            await SessionStore.shared.process(.interruptDetected(sessionID: sessionID))
            InterruptWatcherManager.shared.stopWatching(sessionID: sessionID)
        }
    }
}

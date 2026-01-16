//
//  ClaudeSessionMonitor.swift
//  ClaudeIsland
//
//  MainActor wrapper around SessionStore for UI binding.
//  Publishes SessionState arrays for SwiftUI observation.
//

import AppKit
import Combine
import Foundation

// MARK: - ClaudeSessionMonitor

@MainActor
class ClaudeSessionMonitor: ObservableObject {
    // MARK: Lifecycle

    init() {
        SessionStore.shared.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.updateFromSessions(sessions)
            }
            .store(in: &cancellables)

        InterruptWatcherManager.shared.delegate = self
    }

    // MARK: Internal

    @Published var instances: [SessionState] = []
    @Published var pendingInstances: [SessionState] = []

    // MARK: - Monitoring Lifecycle

    func startMonitoring() {
        HookSocketServer.shared.start(
            onEvent: { event in
                Task {
                    await SessionStore.shared.process(.hookReceived(event))
                }

                if event.sessionPhase == .processing {
                    Task { @MainActor in
                        InterruptWatcherManager.shared.startWatching(
                            sessionID: event.sessionID,
                            cwd: event.cwd
                        )
                    }
                }

                if event.status == "ended" {
                    Task { @MainActor in
                        InterruptWatcherManager.shared.stopWatching(sessionID: event.sessionID)
                    }
                }

                if event.event == "Stop" {
                    HookSocketServer.shared.cancelPendingPermissions(sessionID: event.sessionID)
                }

                if event.event == "PostToolUse", let toolUseID = event.toolUseID {
                    HookSocketServer.shared.cancelPendingPermission(toolUseID: toolUseID)
                }
            },
            onPermissionFailure: { sessionID, toolUseID in
                Task {
                    await SessionStore.shared.process(
                        .permissionSocketFailed(sessionID: sessionID, toolUseID: toolUseID)
                    )
                }
            }
        )
    }

    func stopMonitoring() {
        HookSocketServer.shared.stop()
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

    private var cancellables = Set<AnyCancellable>()

    // MARK: - State Update

    private func updateFromSessions(_ sessions: [SessionState]) {
        instances = sessions
        pendingInstances = sessions.filter(\.needsAttention)
    }
}

// MARK: JSONLInterruptWatcherDelegate

extension ClaudeSessionMonitor: JSONLInterruptWatcherDelegate {
    nonisolated func didDetectInterrupt(sessionID: String) {
        Task {
            await SessionStore.shared.process(.interruptDetected(sessionID: sessionID))
        }

        Task { @MainActor in
            InterruptWatcherManager.shared.stopWatching(sessionID: sessionID)
        }
    }
}

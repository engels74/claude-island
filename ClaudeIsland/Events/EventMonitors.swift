//
//  EventMonitors.swift
//  ClaudeIsland
//
//  Singleton that aggregates all event monitors
//

import AppKit
import ApplicationServices
import Combine

// MARK: - SendableEvent

/// Wrapper to safely pass NSEvent across MainActor boundaries.
/// Safe because NSEvent monitor handlers are documented to run on main thread.
private struct SendableEvent: @unchecked Sendable {
    nonisolated(unsafe) let event: NSEvent
}

// MARK: - EventMonitors

/// Singleton that aggregates all event monitors.
/// @MainActor ensures thread-safe access to mutable state and Combine publishers
/// since NSEvent monitors dispatch handlers on the main thread.
@MainActor
final class EventMonitors {
    // MARK: Lifecycle

    private init() {}

    // MARK: Internal

    static let shared = EventMonitors()

    let mouseLocation = CurrentValueSubject<CGPoint, Never>(.zero)
    let mouseDown = PassthroughSubject<NSEvent, Never>()

    /// Start event monitors only if accessibility permission is already granted.
    /// Must be called after the user grants Accessibility permission (or on launch if already granted).
    /// Safe to call multiple times — subsequent calls are no-ops.
    func startMonitorsIfPermitted() {
        guard !self.monitorsStarted else { return }
        guard AXIsProcessTrusted() else { return }
        self.monitorsStarted = true
        self.setupMonitors()
    }

    // MARK: Private

    private var monitorsStarted = false
    private var mouseMoveMonitor: EventMonitor?
    private var mouseDownMonitor: EventMonitor?
    private var mouseDraggedMonitor: EventMonitor?

    private func setupMonitors() {
        // NSEvent monitor handlers are documented to run on the main thread.
        // Using MainActor.assumeIsolated is safe and avoids Swift 6 Sendable warnings
        // when passing NSEvent across isolation boundaries.
        self.mouseMoveMonitor = EventMonitor(mask: .mouseMoved) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.mouseLocation.send(NSEvent.mouseLocation)
            }
        }
        self.mouseMoveMonitor?.start()

        self.mouseDownMonitor = EventMonitor(mask: .leftMouseDown) { [weak self] event in
            let wrapper = SendableEvent(event: event)
            MainActor.assumeIsolated {
                self?.mouseDown.send(wrapper.event)
            }
        }
        self.mouseDownMonitor?.start()

        self.mouseDraggedMonitor = EventMonitor(mask: .leftMouseDragged) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.mouseLocation.send(NSEvent.mouseLocation)
            }
        }
        self.mouseDraggedMonitor?.start()
    }
}

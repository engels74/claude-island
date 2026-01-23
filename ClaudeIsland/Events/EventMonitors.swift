//
//  EventMonitors.swift
//  ClaudeIsland
//
//  Singleton that aggregates all event monitors
//

import AppKit
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

    private init() {
        self.setupMonitors()
    }

    // MARK: Internal

    static let shared = EventMonitors()

    let mouseLocation = CurrentValueSubject<CGPoint, Never>(.zero)
    let mouseDown = PassthroughSubject<NSEvent, Never>()

    // MARK: Private

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

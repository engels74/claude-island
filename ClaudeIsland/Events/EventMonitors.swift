//
//  EventMonitors.swift
//  ClaudeIsland
//
//  Singleton that aggregates all event monitors
//

import AppKit
import Combine

/// Singleton that aggregates all event monitors.
/// @MainActor ensures thread-safe access to mutable state and Combine publishers
/// since NSEvent monitors dispatch handlers on the main thread.
@MainActor
final class EventMonitors {
    // MARK: Lifecycle

    private init() {
        setupMonitors()
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
        mouseMoveMonitor = EventMonitor(mask: .mouseMoved) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.mouseLocation.send(NSEvent.mouseLocation)
            }
        }
        mouseMoveMonitor?.start()

        mouseDownMonitor = EventMonitor(mask: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated {
                self?.mouseDown.send(event)
            }
        }
        mouseDownMonitor?.start()

        mouseDraggedMonitor = EventMonitor(mask: .leftMouseDragged) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.mouseLocation.send(NSEvent.mouseLocation)
            }
        }
        mouseDraggedMonitor?.start()
    }
}

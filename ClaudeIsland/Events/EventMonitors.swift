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
        // Note: Apple documents that NSEvent monitor handlers run on the main thread.
        // Using DispatchQueue.main.async provides defensive safety in case this ever changes,
        // avoiding potential crashes from MainActor.assumeIsolated violations.
        mouseMoveMonitor = EventMonitor(mask: .mouseMoved) { [weak self] _ in
            DispatchQueue.main.async {
                self?.mouseLocation.send(NSEvent.mouseLocation)
            }
        }
        mouseMoveMonitor?.start()

        mouseDownMonitor = EventMonitor(mask: .leftMouseDown) { [weak self] event in
            DispatchQueue.main.async {
                self?.mouseDown.send(event)
            }
        }
        mouseDownMonitor?.start()

        mouseDraggedMonitor = EventMonitor(mask: .leftMouseDragged) { [weak self] _ in
            DispatchQueue.main.async {
                self?.mouseLocation.send(NSEvent.mouseLocation)
            }
        }
        mouseDraggedMonitor?.start()
    }
}

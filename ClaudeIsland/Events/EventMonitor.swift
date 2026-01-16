//
//  EventMonitor.swift
//  ClaudeIsland
//
//  Wraps NSEvent monitoring for safe lifecycle management
//

import AppKit

/// Wraps NSEvent monitoring with proper lifecycle management.
/// Thread-safety: This class should be used from the main thread since NSEvent
/// monitors deliver their handlers on the main thread. The monitor tokens are
/// stored as instance state that should not be accessed concurrently.
final class EventMonitor: @unchecked Sendable {
    // MARK: Lifecycle

    init(mask: NSEvent.EventTypeMask, handler: @escaping @Sendable (NSEvent) -> Void) {
        self.mask = mask
        self.handler = handler
    }

    deinit {
        stopInternal()
    }

    // MARK: Internal

    /// Start monitoring events. Must be called on the main thread.
    @MainActor
    func start() {
        // Global monitor for events outside our app
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handler(event)
        }

        // Local monitor for events inside our app
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handler(event)
            return event
        }
    }

    /// Stop monitoring events. Must be called on the main thread.
    @MainActor
    func stop() {
        stopInternal()
    }

    // MARK: Private

    /// nonisolated(unsafe) is safe here because:
    /// 1. These are only written in start() which runs on @MainActor
    /// 2. They are read in stopInternal() which is either called from stop() (@MainActor)
    ///    or from deinit when there are no other references
    /// 3. The values themselves (opaque monitor tokens) are immutable once created
    private nonisolated(unsafe) var globalMonitor: Any?
    private nonisolated(unsafe) var localMonitor: Any?
    private let mask: NSEvent.EventTypeMask
    private let handler: @Sendable (NSEvent) -> Void

    /// Internal stop that can be called from deinit
    private func stopInternal() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }
}

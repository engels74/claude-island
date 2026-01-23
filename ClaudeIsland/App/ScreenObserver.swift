//
//  ScreenObserver.swift
//  ClaudeIsland
//
//  Monitors screen configuration changes
//

import AppKit

/// `@unchecked Sendable` because thread safety is managed via main thread
/// notification delivery and debounced DispatchWorkItem execution
final class ScreenObserver: @unchecked Sendable {
    // MARK: Lifecycle

    init(onScreenChange: @escaping () -> Void) {
        self.onScreenChange = onScreenChange
        self.startObserving()
    }

    deinit {
        stopObserving()
    }

    // MARK: Private

    /// nonisolated(unsafe) is safe here because:
    /// 1. These are only written in startObserving() which runs on init (implicitly @MainActor)
    /// 2. They are read in stopObserving() which is either called from @MainActor or from deinit
    ///    when there are no other references
    private nonisolated(unsafe) var observer: Any?
    private nonisolated(unsafe) let onScreenChange: () -> Void
    private nonisolated(unsafe) var pendingWork: DispatchWorkItem?

    /// Debounce interval to coalesce rapid screen change notifications
    /// (e.g., when waking from sleep, displays reconnect in stages)
    private let debounceInterval: TimeInterval = 0.5

    private func startObserving() {
        self.observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleScreenChange()
            }
        }
    }

    private func scheduleScreenChange() {
        self.pendingWork?.cancel()

        let work = DispatchWorkItem { [weak self] in
            self?.onScreenChange()
        }
        self.pendingWork = work

        DispatchQueue.main.asyncAfter(
            deadline: .now() + self.debounceInterval,
            execute: work
        )
    }

    private nonisolated func stopObserving() {
        self.pendingWork?.cancel()
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

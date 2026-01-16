//
//  ScreenObserver.swift
//  ClaudeIsland
//
//  Monitors screen configuration changes
//

import AppKit

class ScreenObserver {
    // MARK: Lifecycle

    init(onScreenChange: @escaping () -> Void) {
        self.onScreenChange = onScreenChange
        startObserving()
    }

    deinit {
        stopObserving()
    }

    // MARK: Private

    private var observer: Any?
    private let onScreenChange: () -> Void
    private var pendingWork: DispatchWorkItem?

    /// Debounce interval to coalesce rapid screen change notifications
    /// (e.g., when waking from sleep, displays reconnect in stages)
    private let debounceInterval: TimeInterval = 0.5

    private func startObserving() {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleScreenChange()
        }
    }

    private func scheduleScreenChange() {
        pendingWork?.cancel()

        let work = DispatchWorkItem { [weak self] in
            self?.onScreenChange()
        }
        pendingWork = work

        DispatchQueue.main.asyncAfter(
            deadline: .now() + debounceInterval,
            execute: work
        )
    }

    private func stopObserving() {
        pendingWork?.cancel()
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

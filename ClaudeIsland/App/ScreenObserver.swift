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

    private func startObserving() {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onScreenChange()
        }
    }

    private func stopObserving() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

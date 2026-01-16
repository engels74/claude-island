//
//  TmuxPathFinder.swift
//  ClaudeIsland
//
//  Finds tmux executable path
//

import Foundation

/// Finds and caches the tmux executable path
actor TmuxPathFinder {
    // MARK: Lifecycle

    private init() {}

    // MARK: Internal

    static let shared = TmuxPathFinder()

    /// Get the path to tmux executable
    func getTmuxPath() -> String? {
        if let cached = cachedPath {
            return cached
        }

        let possiblePaths = [
            "/opt/homebrew/bin/tmux", // Apple Silicon Homebrew
            "/usr/local/bin/tmux", // Intel Homebrew
            "/usr/bin/tmux", // System
            "/bin/tmux",
        ]

        for path in possiblePaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                cachedPath = path
                return path
            }
        }

        return nil
    }

    /// Check if tmux is available
    func isTmuxAvailable() -> Bool {
        getTmuxPath() != nil
    }

    // MARK: Private

    private var cachedPath: String?
}

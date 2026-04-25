//
//  ChatMessageHelpers.swift
//  ClaudeIsland
//
//  Shared utilities for chat message analysis
//

import Foundation

enum ChatMessageHelpers {
    static func isErrorMessage(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("error:") || lowered.contains("api error")
            || lowered.hasPrefix("error") || lowered.contains("failed:")
            || lowered.contains("exception:") || lowered.contains("fatal:")
    }
}

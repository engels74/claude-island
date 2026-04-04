//
//  ProjectEntry.swift
//  ClaudeIsland
//
//  Model for a project directory (pinned or recent)
//

import Foundation

struct ProjectEntry: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    let path: String
    var displayName: String
    var lastUsedAt: Date
    var isPinned: Bool
    var pinnedAt: Date?
}

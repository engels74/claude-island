//
//  ReleaseInfo.swift
//  ClaudeIsland
//
//  Data model for a GitHub release, used by the What's New feature.
//

import Foundation

nonisolated struct ReleaseInfo: Codable, Sendable, Identifiable {
    let id: String
    let name: String
    let publishedAt: Date
    let changes: [String]
}

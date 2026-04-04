//
//  ProjectStore.swift
//  ClaudeIsland
//
//  Manages pinned and recent project directories
//

import Foundation
import Observation

// MARK: - ProjectStore

@Observable
final class ProjectStore {
    // MARK: Lifecycle

    private init() {
        self.entries = AppSettings.projects
        self.pruneInvalidPaths()
    }

    // MARK: Internal

    static let shared = ProjectStore()

    var pinnedProjects: [ProjectEntry] {
        self.entries
            .filter(\.isPinned)
            .sorted { ($0.pinnedAt ?? .distantPast) < ($1.pinnedAt ?? .distantPast) }
    }

    var recentProjects: [ProjectEntry] {
        self.entries
            .filter { !$0.isPinned }
            .sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    func recordUsage(path: String) {
        let normalized = self.normalizePath(path)
        guard !normalized.isEmpty, normalized.hasPrefix("/") else { return }

        if let index = entries.firstIndex(where: { $0.path == normalized }) {
            self.entries[index].lastUsedAt = Date()
        } else {
            let entry = ProjectEntry(
                id: UUID(),
                path: normalized,
                displayName: URL(fileURLWithPath: normalized).lastPathComponent,
                lastUsedAt: Date(),
                isPinned: false,
                pinnedAt: nil
            )
            self.entries.append(entry)
        }

        self.pruneExcessRecents()
        self.save()
    }

    func pin(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        self.entries[index].isPinned = true
        self.entries[index].pinnedAt = Date()
        self.save()
    }

    func unpin(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        self.entries[index].isPinned = false
        self.entries[index].pinnedAt = nil
        self.save()
    }

    func remove(id: UUID) {
        self.entries.removeAll { $0.id == id }
        self.save()
    }

    func addPinned(path: String) {
        let normalized = self.normalizePath(path)
        guard !normalized.isEmpty, normalized.hasPrefix("/") else { return }

        if let index = entries.firstIndex(where: { $0.path == normalized }) {
            self.entries[index].isPinned = true
            self.entries[index].pinnedAt = Date()
            self.save()
            return
        }

        let entry = ProjectEntry(
            id: UUID(),
            path: normalized,
            displayName: URL(fileURLWithPath: normalized).lastPathComponent,
            lastUsedAt: Date(),
            isPinned: true,
            pinnedAt: Date()
        )
        self.entries.append(entry)
        self.save()
    }

    func pruneInvalidPaths() {
        self.entries.removeAll { entry in
            !entry.isPinned && !FileManager.default.fileExists(atPath: entry.path)
        }
        self.save()
    }

    // MARK: Private

    private var entries: [ProjectEntry] = []

    private func normalizePath(_ path: String) -> String {
        var normalized = path
        while normalized.hasSuffix("/"), normalized.count > 1 {
            normalized.removeLast()
        }
        return normalized
    }

    private func pruneExcessRecents() {
        let recents = self.entries.filter { !$0.isPinned }.sorted { $0.lastUsedAt > $1.lastUsedAt }
        if recents.count > 20, let oldest = recents.last {
            self.entries.removeAll { $0.id == oldest.id }
        }
    }

    private func save() {
        AppSettings.projects = self.entries
    }
}

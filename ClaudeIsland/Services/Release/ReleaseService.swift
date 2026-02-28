//
//  ReleaseService.swift
//  ClaudeIsland
//
//  Service for fetching GitHub releases and caching them locally.
//

import Foundation
import os.log

// MARK: - GitHubRelease

private nonisolated struct GitHubRelease: Decodable {
    let tagName: String
    let name: String
    let publishedAt: String
    let body: String?
}

// MARK: - ReleaseService

@Observable
final class ReleaseService {
    // MARK: Internal

    static let shared = ReleaseService()

    private(set) var releases: [ReleaseInfo] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    func fetchReleases() async {
        self.isLoading = true
        defer { isLoading = false }

        if self.releases.isEmpty {
            self.loadCachedReleases()
        }

        do {
            let fetched = try await fetchFromGitHub()
            self.releases = fetched
            self.saveCachedReleases(fetched)
            self.errorMessage = nil
        } catch is CancellationError {
            Self.logger.info("Release fetch cancelled")
        } catch {
            Self.logger.error("Failed to fetch releases: \(error.localizedDescription)")
            if self.releases.isEmpty {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Private

    private nonisolated static let logger = Logger(subsystem: "com.engels74.ClaudeIsland", category: "ReleaseService")

    private static let releasesURL = "https://api.github.com/repos/engels74/claude-island/releases"

    private nonisolated static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private nonisolated static let fractionalDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static var cacheDirectoryURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            .map { $0.appendingPathComponent("com.engels74.ClaudeIsland") }
    }

    private static var cacheFileURL: URL? {
        cacheDirectoryURL.map { $0.appendingPathComponent("releases.json") }
    }

    private func parseChanges(_ body: String) -> [String] {
        let lines = body.components(separatedBy: "\n")

        guard let whatsChangedIndex = lines.firstIndex(where: { $0.hasPrefix("## What's Changed") }) else {
            return []
        }

        let prURLPattern = #/https://github\.com/[^/]+/[^/]+/pull/(\d+)/#

        var results: [String] = []
        var index = whatsChangedIndex + 1

        while index < lines.count {
            let line = lines[index]

            if line.hasPrefix("**Full Changelog**") || line.hasPrefix("---") || line.hasPrefix("## ") {
                break
            }

            if line.hasPrefix("* ") {
                let stripped = String(line.dropFirst(2))
                let cleaned = stripped.replacing(prURLPattern) { match in
                    "#\(match.1)"
                }
                results.append(cleaned)
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                let hasMoreItems = ((index + 1) < lines.count) && lines[index + 1].hasPrefix("* ")
                if !hasMoreItems {
                    break
                }
            } else {
                break
            }

            index += 1
        }

        return results
    }

    private func fetchFromGitHub() async throws -> [ReleaseInfo] {
        guard let url = URL(string: Self.releasesURL) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.httpMethod = "GET"
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard httpResponse.statusCode == 200 else {
            Self.logger.error("GitHub API returned status \(httpResponse.statusCode)")
            throw URLError(.badServerResponse)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let githubReleases = try decoder.decode([GitHubRelease].self, from: data)

        return githubReleases.map { release in
            let date = Self.fractionalDateFormatter.date(from: release.publishedAt)
                ?? Self.dateFormatter.date(from: release.publishedAt)
                ?? Date.distantPast
            let changes = self.parseChanges(release.body ?? "")

            return ReleaseInfo(
                id: release.tagName,
                name: release.name,
                publishedAt: date,
                changes: changes,
            )
        }
    }

    // MARK: - Disk Cache

    private func loadCachedReleases() {
        guard let fileURL = Self.cacheFileURL else { return }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            self.releases = try decoder.decode([ReleaseInfo].self, from: data)
            Self.logger.debug("Loaded \(self.releases.count) cached releases")
        } catch {
            Self.logger.warning("Failed to load cached releases: \(error.localizedDescription)")
        }
    }

    private func saveCachedReleases(_ releases: [ReleaseInfo]) {
        guard let directoryURL = Self.cacheDirectoryURL,
              let fileURL = Self.cacheFileURL
        else { return }

        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(releases)
            try data.write(to: fileURL, options: .atomic)
            Self.logger.debug("Saved \(releases.count) releases to cache")
        } catch {
            Self.logger.warning("Failed to save releases cache: \(error.localizedDescription)")
        }
    }
}

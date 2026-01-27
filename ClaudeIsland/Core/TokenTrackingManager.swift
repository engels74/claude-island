//
//  TokenTrackingManager.swift
//  ClaudeIsland
//
//  Central manager for token usage tracking
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.engels74.ClaudeIsland", category: "TokenTrackingManager")

struct UsageMetric: Equatable, Sendable {
    let used: Int
    let limit: Int
    let percentage: Double
    let resetTime: Date?

    static let zero = UsageMetric(used: 0, limit: 0, percentage: 0, resetTime: nil)
}

@Observable
@MainActor
final class TokenTrackingManager {
    static let shared = TokenTrackingManager()

    private(set) var sessionUsage: UsageMetric = .zero
    private(set) var weeklyUsage: UsageMetric = .zero
    private(set) var lastError: String?
    private(set) var isRefreshing = false

    var sessionPercentage: Double { self.sessionUsage.percentage }
    var weeklyPercentage: Double { self.weeklyUsage.percentage }
    var sessionResetTime: Date? { self.sessionUsage.resetTime }
    var weeklyResetTime: Date? { self.weeklyUsage.resetTime }

    var isEnabled: Bool {
        AppSettings.tokenTrackingMode != .disabled
    }

    private var refreshTask: Task<Void, Never>?
    private var periodicRefreshTask: Task<Void, Never>?

    private init() {
        self.startPeriodicRefresh()
    }

    func refresh() async {
        logger.warning("[DEBUG] refresh() called, isEnabled: \(self.isEnabled), mode: \(String(describing: AppSettings.tokenTrackingMode))")

        guard self.isEnabled else {
            logger.warning("[DEBUG] Token tracking disabled, returning zero")
            self.sessionUsage = .zero
            self.weeklyUsage = .zero
            self.lastError = nil
            return
        }

        self.isRefreshing = true
        defer { self.isRefreshing = false }

        do {
            switch AppSettings.tokenTrackingMode {
            case .disabled:
                self.sessionUsage = .zero
                self.weeklyUsage = .zero

            case .api:
                logger.warning("[DEBUG] Using API mode for refresh")
                try await self.refreshFromAPI()
            }
            self.lastError = nil
            logger.warning("[DEBUG] Refresh complete - session: \(self.sessionPercentage)%, weekly: \(self.weeklyPercentage)%")
        } catch {
            logger.error("[DEBUG] Token tracking refresh FAILED: \(error.localizedDescription)")
            self.lastError = error.localizedDescription
        }
    }

    func stopRefreshing() {
        self.periodicRefreshTask?.cancel()
        self.periodicRefreshTask = nil
        self.refreshTask?.cancel()
        self.refreshTask = nil
    }

    private func startPeriodicRefresh() {
        self.periodicRefreshTask?.cancel()
        self.periodicRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()

                let interval: TimeInterval = 60
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func refreshFromAPI() async throws {
        logger.warning("[DEBUG] refreshFromAPI called, mode: \(String(describing: AppSettings.tokenTrackingMode))")
        let apiService = ClaudeAPIService.shared

        if AppSettings.tokenUseCliOAuth {
            logger.warning("[DEBUG] CLI OAuth mode enabled, checking for token...")
            if let oauthToken = self.getCliOAuthToken() {
                logger.warning("[DEBUG] Found OAuth token, fetching usage...")
                let response = try await apiService.fetchUsage(oauthToken: oauthToken)
                self.updateFromAPIResponse(response)
                return
            } else {
                logger.warning("[DEBUG] CLI OAuth enabled but no token found, falling back to session key")
            }
        }

        guard let sessionKey = AppSettings.tokenApiSessionKey, !sessionKey.isEmpty else {
            logger.error("[DEBUG] No session key configured")
            throw TokenTrackingError.noCredentials
        }

        let keyPrefix = String(sessionKey.prefix(20))
        logger.warning("[DEBUG] Using session key starting with: \(keyPrefix)...")
        let response = try await apiService.fetchUsage(sessionKey: sessionKey)
        self.updateFromAPIResponse(response)
    }

    private func updateFromAPIResponse(_ response: APIUsageResponse) {
        logger.warning("[DEBUG] Updating from API response - session: \(response.fiveHour.utilization)%, weekly: \(response.sevenDay.utilization)%")

        self.sessionUsage = UsageMetric(
            used: 0,
            limit: 0,
            percentage: response.fiveHour.utilization,
            resetTime: response.fiveHour.resetsAt
        )

        self.weeklyUsage = UsageMetric(
            used: 0,
            limit: 0,
            percentage: response.sevenDay.utilization,
            resetTime: response.sevenDay.resetsAt
        )

        logger.warning("[DEBUG] After update - sessionUsage.percentage: \(self.sessionUsage.percentage), weeklyUsage.percentage: \(self.weeklyUsage.percentage)")
    }

    private func getCliOAuthToken() -> String? {
        let keychainQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "claude-cli",
            kSecAttrAccount as String: "oauth-tokens",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(keychainQuery as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["accessToken"] as? String
        else {
            return nil
        }

        if let expiresAt = json["expiresAt"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let expiryDate = formatter.date(from: expiresAt), expiryDate < Date() {
                logger.warning("CLI OAuth token is expired")
                return nil
            }
        }

        return accessToken
    }
}

enum TokenTrackingError: Error, LocalizedError {
    case noCredentials
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .noCredentials:
            "No API credentials configured"
        case let .apiError(message):
            message
        }
    }
}

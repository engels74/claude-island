//
//  TokenTrackingManager.swift
//  ClaudeIsland
//
//  Central manager for token usage tracking
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.engels74.ClaudeIsland", category: "TokenTrackingManager")

// MARK: - UsageMetric

struct UsageMetric: Equatable, Sendable {
    static let zero = Self(used: 0, limit: 0, percentage: 0, resetTime: nil)

    let used: Int
    let limit: Int
    let percentage: Double
    let resetTime: Date?
}

// MARK: - TokenTrackingManager

@Observable
@MainActor
final class TokenTrackingManager {
    // MARK: Lifecycle

    private init() {
        self.migrateSessionKeyFromDefaults()
        self.startPeriodicRefresh()
    }

    // MARK: Internal

    static let shared = TokenTrackingManager()

    private(set) var sessionUsage: UsageMetric = .zero
    private(set) var weeklyUsage: UsageMetric = .zero
    private(set) var lastError: String?
    private(set) var isRefreshing = false

    var sessionPercentage: Double {
        self.sessionUsage.percentage
    }

    var weeklyPercentage: Double {
        self.weeklyUsage.percentage
    }

    var sessionResetTime: Date? {
        self.sessionUsage.resetTime
    }

    var weeklyResetTime: Date? {
        self.weeklyUsage.resetTime
    }

    var isEnabled: Bool {
        AppSettings.tokenTrackingMode != .disabled
    }

    func refresh() async {
        logger.debug("refresh() called, isEnabled: \(self.isEnabled), mode: \(String(describing: AppSettings.tokenTrackingMode))")

        guard self.isEnabled else {
            logger.debug("Token tracking disabled, returning zero")
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
                logger.debug("Using API mode for refresh")
                try await self.refreshFromAPI()
            }
            self.lastError = nil
            logger.debug("Refresh complete - session: \(self.sessionPercentage)%, weekly: \(self.weeklyPercentage)%")
        } catch {
            logger.error("Token tracking refresh failed: \(error.localizedDescription)")
            self.lastError = error.localizedDescription
        }
    }

    func stopRefreshing() {
        self.periodicRefreshTask?.cancel()
        self.periodicRefreshTask = nil
        self.refreshTask?.cancel()
        self.refreshTask = nil
    }

    // MARK: - Keychain Helpers for Session Key

    @discardableResult
    func saveSessionKey(_ key: String?) -> Bool {
        let service = "com.engels74.ClaudeIsland"
        let account = "token-api-session-key"

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        // If key is nil or empty, just delete
        guard let key, !key.isEmpty else {
            SecItemDelete(baseQuery as CFDictionary)
            return true
        }

        let valueData = Data(key.utf8)

        // Try to update existing item first to avoid deleting before a successful write
        let updateAttributes: [String: Any] = [kSecValueData as String: valueData]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttributes as CFDictionary)

        if updateStatus == errSecSuccess {
            return true
        }

        if updateStatus == errSecItemNotFound {
            // Item doesn't exist yet, add new
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = valueData
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus == errSecSuccess {
                return true
            }
            logger.error("Failed to save session key to Keychain: \(addStatus)")
            return false
        }

        logger.error("Failed to update session key in Keychain: \(updateStatus)")
        return false
    }

    func loadSessionKey() -> String? {
        let service = "com.engels74.ClaudeIsland"
        let account = "token-api-session-key"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else {
            return nil
        }

        return key
    }

    // MARK: Private

    private var refreshTask: Task<Void, Never>?
    private var periodicRefreshTask: Task<Void, Never>?

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

    /// Migrate session key from UserDefaults to Keychain (one-time migration)
    private func migrateSessionKeyFromDefaults() {
        // If Keychain already has a value, skip migration
        if self.loadSessionKey() != nil { return }

        // Check if UserDefaults has a value to migrate
        let defaults = UserDefaults.standard
        let legacyKey = "tokenApiSessionKey"
        if let existingKey = defaults.string(forKey: legacyKey), !existingKey.isEmpty {
            if self.saveSessionKey(existingKey) {
                defaults.removeObject(forKey: legacyKey)
                logger.info("Migrated session key from UserDefaults to Keychain")
            } else {
                logger.error("Failed to migrate session key to Keychain, keeping UserDefaults entry")
            }
        }
    }

    private func refreshFromAPI() async throws {
        logger.debug("refreshFromAPI called")
        let apiService = ClaudeAPIService.shared

        if AppSettings.tokenUseCLIOAuth {
            logger.debug("CLI OAuth mode enabled, checking for token...")
            if let oauthToken = self.getCLIOAuthToken() {
                logger.debug("Found OAuth token, fetching usage...")
                let response = try await apiService.fetchUsage(oauthToken: oauthToken)
                self.updateFromAPIResponse(response)
                return
            } else {
                logger.debug("CLI OAuth enabled but no token found, falling back to session key")
            }
        }

        guard let sessionKey = self.loadSessionKey(), !sessionKey.isEmpty else {
            logger.error("No session key configured")
            throw TokenTrackingError.noCredentials
        }

        let response = try await apiService.fetchUsage(sessionKey: sessionKey)
        self.updateFromAPIResponse(response)
    }

    private func updateFromAPIResponse(_ response: APIUsageResponse) {
        logger.debug("Updating from API response - session: \(response.fiveHour.utilization)%, weekly: \(response.sevenDay.utilization)%")

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
    }

    private func getCLIOAuthToken() -> String? {
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

// MARK: - TokenTrackingError

enum TokenTrackingError: Error, LocalizedError {
    case noCredentials
    case apiError(String)

    // MARK: Internal

    var errorDescription: String? {
        switch self {
        case .noCredentials:
            "No API credentials configured"
        case let .apiError(message):
            message
        }
    }
}

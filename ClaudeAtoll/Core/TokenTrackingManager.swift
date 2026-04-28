//
//  TokenTrackingManager.swift
//  ClaudeAtoll
//
//  Central manager for token usage tracking
//

import Foundation
import LocalAuthentication
import os.log

// MARK: - InteractionContext

enum InteractionContext: Sendable {
    case userInitiated
    case background
}

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
final class TokenTrackingManager {
    // MARK: Lifecycle

    private init() {
        self.migrateKeychainItemsFromLegacyService()
        self.migrateSessionKeyFromDefaults()
        UserDefaults.standard.removeObject(forKey: "cliKeychainLastAttempt")
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

    func refresh(interaction: InteractionContext = .background) async {
        Self.logger.debug("refresh() called, isEnabled: \(self.isEnabled), mode: \(String(describing: AppSettings.tokenTrackingMode))")

        guard self.isEnabled else {
            Self.logger.debug("Token tracking disabled, returning zero")
            self.sessionUsage = .zero
            self.weeklyUsage = .zero
            self.lastError = nil
            return
        }

        self.isRefreshing = true
        defer { self.isRefreshing = false }

        do throws(TokenTrackingError) {
            switch AppSettings.tokenTrackingMode {
            case .disabled:
                self.sessionUsage = .zero
                self.weeklyUsage = .zero

            case .api:
                Self.logger.debug("Using API mode for refresh")
                try await self.refreshFromAPI(interaction: interaction)
            }
            self.lastError = nil
            self.consecutiveFailures = 0
            self.retryAfterOverride = nil
            Self.logger.debug("Refresh complete - session: \(self.sessionPercentage)%, weekly: \(self.weeklyPercentage)%")
        } catch {
            self.consecutiveFailures += 1
            Self.logger.error("Token tracking refresh failed: \(error.errorDescription ?? "unknown", privacy: .public)")
            self.lastError = error.errorDescription
            let interval = self.currentRefreshInterval
            if interval > 60 {
                Self.logger.info("Backing off, next refresh in \(interval)s")
            }
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
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.sessionKeyAccount,
        ]

        // If key is nil or empty, just delete
        guard let key, !key.isEmpty else {
            SecItemDelete(baseQuery as CFDictionary)
            return true
        }

        let valueData = Data(key.utf8)

        // Try to update existing item first to avoid deleting before a successful write
        let updateAttributes: [String: Any] = [
            kSecValueData as String: valueData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttributes as CFDictionary)

        if updateStatus == errSecSuccess {
            return true
        }

        // errSecItemNotFound: item doesn't exist yet
        // errSecParam: existing item may have incompatible attributes (e.g. different kSecAttrAccessible)
        if updateStatus == errSecItemNotFound || updateStatus == errSecParam {
            if updateStatus == errSecParam {
                SecItemDelete(baseQuery as CFDictionary)
            }
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = valueData
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus == errSecSuccess {
                return true
            }
            Self.logger.error("Failed to save session key to Keychain: \(addStatus)")
            return false
        }

        Self.logger.error("Failed to update session key in Keychain: \(updateStatus)")
        return false
    }

    func loadSessionKey() -> String? {
        guard let data = self.readKeychainData(service: Self.keychainService, account: Self.sessionKeyAccount),
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else {
            return nil
        }

        return key
    }

    // MARK: Private

    private enum KeychainReadResult {
        case found(Data)
        case notFound
        case failed(OSStatus)
        case invalidResult
    }

    nonisolated private static let logger = Logger(subsystem: "com.engels74.ClaudeAtoll", category: "TokenTrackingManager")

    private static let keychainService = "com.engels74.ClaudeAtoll"
    private static let legacyKeychainService = "com.engels74.ClaudeIsland"
    private static let legacyDefaultsDomain = "com.engels74.ClaudeIsland"
    private static let sessionKeyAccount = "token-api-session-key"
    private static let cliOAuthCacheAccount = "cli-oauth-cache"
    private static let sessionKeyDefaultsKey = "tokenApiSessionKey"

    private var refreshTask: Task<Void, Never>?
    private var periodicRefreshTask: Task<Void, Never>?
    private var consecutiveFailures = 0
    private var retryAfterOverride: TimeInterval?

    private var currentRefreshInterval: TimeInterval {
        if let override = self.retryAfterOverride { return override }
        guard self.consecutiveFailures > 0 else { return 60 }
        // Exponential backoff: 2min, 4min, 8min, 16min, capped at 30min
        let backoff = 120.0 * pow(2.0, Double(self.consecutiveFailures - 1))
        return min(backoff, 1800)
    }

    private func startPeriodicRefresh() {
        self.periodicRefreshTask?.cancel()
        self.periodicRefreshTask = Task(name: "token-refresh") { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let interval = self?.currentRefreshInterval ?? 60
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func refreshFromAPI(interaction: InteractionContext) async throws(TokenTrackingError) {
        Self.logger.debug("refreshFromAPI called (interaction: \(String(describing: interaction)))")
        let apiService = ClaudeAPIService.shared

        if AppSettings.tokenUseCLIOAuth {
            Self.logger.debug("CLI OAuth mode enabled, checking for token...")
            if let oauthToken = self.resolveOAuthToken(interaction: interaction) {
                Self.logger.debug("Found OAuth token, fetching usage...")
                do {
                    let response = try await apiService.fetchUsage(oauthToken: oauthToken)
                    self.updateFromAPIResponse(response)
                    return
                } catch {
                    if case let .rateLimited(retryAfter) = error {
                        self.retryAfterOverride = retryAfter
                        // Don't invalidate caches — token is valid, just rate-limited
                        // When retryAfter is nil, use post-increment failure count so the
                        // message matches the actual backoff used by startPeriodicRefresh
                        let interval: TimeInterval
                        if let retryAfter {
                            interval = retryAfter
                        } else {
                            let nextFailures = self.consecutiveFailures + 1
                            interval = min(120.0 * pow(2.0, Double(nextFailures - 1)), 1800)
                        }
                        let message = if interval >= 60 {
                            "Rate limited, retrying in \(Int(interval / 60))m"
                        } else {
                            "Rate limited, retrying in \(Int(interval))s"
                        }
                        throw TokenTrackingError.apiError(message)
                    } else if case let .httpError(statusCode) = error,
                              statusCode == 401 || statusCode == 403 {
                        // Only invalidate cache for authentication rejections — transient errors
                        // should not wipe a valid token and re-trigger keychain prompts
                        self.invalidateOAuthCaches()
                    }
                    throw TokenTrackingError.apiError(error.errorDescription ?? "API request failed")
                }
            } else {
                Self.logger.debug("CLI OAuth enabled but no token found, falling back to session key")
            }
        }

        guard let sessionKey = self.loadSessionKey(), !sessionKey.isEmpty else {
            Self.logger.error("No session key configured")
            throw TokenTrackingError.noCredentials
        }

        do {
            let response = try await apiService.fetchUsage(sessionKey: sessionKey)
            self.updateFromAPIResponse(response)
        } catch {
            throw TokenTrackingError.apiError(error.errorDescription ?? "API request failed")
        }
    }

    private func updateFromAPIResponse(_ response: APIUsageResponse) {
        Self.logger.debug("Updating from API response - session: \(response.fiveHour.utilization)%, weekly: \(response.sevenDay.utilization)%")

        self.sessionUsage = UsageMetric(
            used: 0,
            limit: 0,
            percentage: response.fiveHour.utilization,
            resetTime: response.fiveHour.resetsAt,
        )

        self.weeklyUsage = UsageMetric(
            used: 0,
            limit: 0,
            percentage: response.sevenDay.utilization,
            resetTime: response.sevenDay.resetsAt,
        )
    }
}

// MARK: - Migration and Keychain Helpers

private extension TokenTrackingManager {
    /// Migrate session key from UserDefaults to Keychain (one-time migration)
    private func migrateSessionKeyFromDefaults() {
        // If Keychain already has a value, skip migration
        switch self.readKeychainDataResult(service: Self.keychainService, account: Self.sessionKeyAccount) {
        case let .found(data):
            if let key = String(data: data, encoding: .utf8), !key.isEmpty {
                return
            }

        case .notFound:
            break

        case let .failed(status):
            Self.logger.warning("Skipping session key defaults migration because Keychain read failed: \(status)")
            return

        case .invalidResult:
            Self.logger.warning("Skipping session key defaults migration because Keychain returned a non-data result")
            return
        }

        // Check if UserDefaults has a value to migrate
        let defaults = UserDefaults.standard
        if let existingKey = defaults.string(forKey: Self.sessionKeyDefaultsKey), !existingKey.isEmpty {
            if self.saveSessionKey(existingKey) {
                defaults.removeObject(forKey: Self.sessionKeyDefaultsKey)
                Self.logger.info("Migrated session key from UserDefaults to Keychain")
            } else {
                Self.logger.error("Failed to migrate session key to Keychain, keeping UserDefaults entry")
            }
            return
        }

        if let existingKey = self.legacyDefaultsSessionKey(), !existingKey.isEmpty {
            if self.saveSessionKey(existingKey) {
                self.removeLegacyDefaultsSessionKey()
                Self.logger.info("Migrated session key from legacy UserDefaults domain to Keychain")
            } else {
                Self.logger.error("Failed to migrate legacy UserDefaults session key to Keychain, keeping legacy entry")
            }
        }
    }

    private func migrateKeychainItemsFromLegacyService() {
        self.copyLegacyKeychainItemIfNeeded(account: Self.sessionKeyAccount, label: "session key")
        self.copyLegacyKeychainItemIfNeeded(account: Self.cliOAuthCacheAccount, label: "CLI OAuth cache")
    }

    private func copyLegacyKeychainItemIfNeeded(account: String, label: String) {
        switch self.readKeychainDataResult(service: Self.keychainService, account: account) {
        case .found:
            return

        case .notFound:
            break

        case let .failed(status):
            Self.logger.warning("Skipping legacy \(label) Keychain migration because Claude Atoll item could not be read: \(status)")
            return

        case .invalidResult:
            Self.logger.warning("Skipping legacy \(label) Keychain migration because Claude Atoll item returned a non-data result")
            return
        }

        let legacyData: Data
        switch self.readKeychainDataResult(service: Self.legacyKeychainService, account: account, allowUserInteraction: false) {
        case let .found(data):
            legacyData = data

        case .notFound:
            return

        case let .failed(status):
            Self.logger.warning("Skipping legacy \(label) Keychain migration because legacy item could not be read: \(status)")
            return

        case .invalidResult:
            Self.logger.warning("Skipping legacy \(label) Keychain migration because legacy item returned a non-data result")
            return
        }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account,
            kSecValueData as String: legacyData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecSuccess {
            Self.logger.info("Copied legacy \(label) Keychain item to Claude Atoll service")
            return
        }

        if status == errSecDuplicateItem {
            Self.logger.warning("Skipped copying legacy \(label) Keychain item because a Claude Atoll item already exists")
            return
        }

        Self.logger.error("Failed to copy legacy \(label) Keychain item: \(status)")
    }

    private func legacyDefaultsSessionKey() -> String? {
        UserDefaults.standard.persistentDomain(forName: Self.legacyDefaultsDomain)?[Self.sessionKeyDefaultsKey] as? String
    }

    private func removeLegacyDefaultsSessionKey() {
        guard var domain = UserDefaults.standard.persistentDomain(forName: Self.legacyDefaultsDomain) else {
            return
        }

        domain.removeValue(forKey: Self.sessionKeyDefaultsKey)
        if domain.isEmpty {
            UserDefaults.standard.removePersistentDomain(forName: Self.legacyDefaultsDomain)
        } else {
            UserDefaults.standard.setPersistentDomain(domain, forName: Self.legacyDefaultsDomain)
        }
    }

    private func readKeychainData(service: String, account: String, allowUserInteraction: Bool = true) -> Data? {
        guard case let .found(data) = self.readKeychainDataResult(
            service: service,
            account: account,
            allowUserInteraction: allowUserInteraction,
        )
        else {
            return nil
        }

        return data
    }

    private func readKeychainDataResult(service: String, account: String, allowUserInteraction: Bool = true) -> KeychainReadResult {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        if !allowUserInteraction {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                return .invalidResult
            }
            return .found(data)

        case errSecItemNotFound:
            return .notFound

        default:
            return .failed(status)
        }
    }
}

// MARK: - CLI OAuth Keychain Operations

extension TokenTrackingManager {
    /// Save CLI OAuth JSON blob to Claude Atoll's own keychain (never prompts).
    @discardableResult
    func saveCLIOAuthCache(_ data: Data) -> Bool {
        let account = Self.cliOAuthCacheAccount

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account,
        ]

        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttributes as CFDictionary)

        if updateStatus == errSecSuccess {
            Self.logger.debug("Updated CLI OAuth cache in Keychain")
            return true
        }

        // errSecItemNotFound: item doesn't exist yet
        // errSecParam: existing item may have incompatible attributes (e.g. different kSecAttrAccessible)
        if updateStatus == errSecItemNotFound || updateStatus == errSecParam {
            if updateStatus == errSecParam {
                SecItemDelete(baseQuery as CFDictionary)
            }
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus == errSecSuccess {
                Self.logger.debug("Saved CLI OAuth cache to Keychain")
                return true
            }
            Self.logger.error("Failed to save CLI OAuth cache to Keychain: \(addStatus)")
            return false
        }

        Self.logger.error("Failed to update CLI OAuth cache in Keychain: \(updateStatus)")
        return false
    }

    /// Load cached CLI OAuth JSON blob (never prompts).
    func loadCLIOAuthCache() -> Data? {
        self.readKeychainData(service: Self.keychainService, account: Self.cliOAuthCacheAccount, allowUserInteraction: false)
    }

    /// Delete the cached CLI OAuth data.
    func deleteCLIOAuthCache() {
        let account = Self.cliOAuthCacheAccount

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            Self.logger.debug("Deleted CLI OAuth cache from Keychain")
        } else {
            Self.logger.error("Failed to delete CLI OAuth cache from Keychain: \(status)")
        }
    }

    /// Parse CLI OAuth JSON data and return the access token.
    /// When `ignoreExpiry` is `true`, return the token even if locally expired —
    /// the API will reject with 401/403 if truly invalid, triggering cache invalidation.
    func extractOAuthToken(from data: Data, ignoreExpiry: Bool = false) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Self.logger.error("Failed to parse CLI OAuth Keychain data as JSON")
            return nil
        }

        let accessToken: String
        let expirySource: [String: Any]

        if let nested = json["claudeAiOauth"] as? [String: Any],
           let token = nested["accessToken"] as? String {
            accessToken = token
            expirySource = nested
        } else if let token = json["accessToken"] as? String {
            accessToken = token
            expirySource = json
        } else {
            Self.logger.error("No accessToken found in CLI OAuth Keychain data")
            return nil
        }

        if !ignoreExpiry, self.isOAuthTokenExpired(expirySource) {
            return nil
        }

        return accessToken
    }

    /// Returns `true` if the token is expired and should not be used.
    private func isOAuthTokenExpired(_ source: [String: Any]) -> Bool {
        if let ms = source["expiresAt"] as? Double {
            let expiry = Date(timeIntervalSince1970: ms / 1000)
            if expiry < Date() {
                Self.logger.warning("CLI OAuth token is expired (expiry: \(expiry))")
                return true
            }
            Self.logger.debug("CLI OAuth token valid (expires: \(expiry))")
        } else if let ms = source["expiresAt"] as? Int {
            let expiry = Date(timeIntervalSince1970: Double(ms) / 1000)
            if expiry < Date() {
                Self.logger.warning("CLI OAuth token is expired (expiry: \(expiry))")
                return true
            }
            Self.logger.debug("CLI OAuth token valid (expires: \(expiry))")
        } else if let str = source["expiresAt"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var expiry = formatter.date(from: str)
            if expiry == nil {
                formatter.formatOptions = [.withInternetDateTime]
                expiry = formatter.date(from: str)
            }
            if let expiry {
                if expiry < Date() {
                    Self.logger.warning("CLI OAuth token is expired (expiry: \(expiry))")
                    return true
                }
                Self.logger.debug("CLI OAuth token valid (expires: \(expiry))")
            } else {
                Self.logger.debug("Could not parse expiresAt string, assuming token is valid")
            }
        } else {
            Self.logger.debug("No expiresAt field found, assuming token is valid")
        }

        return false
    }
}

// MARK: - TokenTrackingError

enum TokenTrackingError: Error, LocalizedError, Sendable {
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

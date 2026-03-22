//
//  TokenTrackingManager+CredentialCache.swift
//  ClaudeIsland
//
//  Three-tier OAuth credential caching: memory → own keychain → CLI keychain (via gate)
//

import Foundation
import os.log
import Synchronization

// MARK: - TokenTrackingManager + CredentialCache

extension TokenTrackingManager {
    // MARK: Internal

    /// Three-tier OAuth token resolver.
    /// Tier 1: In-process memory cache (Mutex-protected, 30-min TTL)
    /// Tier 2: Own keychain cache (never prompts)
    /// Tier 3: CLI keychain via CLIOAuthKeychainGate (may prompt on user-initiated)
    func resolveOAuthToken(interaction: InteractionContext) -> String? {
        // Step 0: Invalidate tier-1 and tier-2 caches if credential file changed on disk
        if self.checkCredentialFileChanged() {
            Self.cacheLogger.info("Credential file changed, invalidating memory and keychain caches")
            Self.memoryCache.withLock { $0.clear() }
            self.deleteCLIOAuthCache()
            CLIOAuthKeychainGate.shared.clearCooldown()
        }

        // Tier 1: Memory cache (Mutex-protected, 30-min TTL)
        let memoryCachedToken = Self.memoryCache.withLock { cache -> String? in
            guard cache.isValid, let token = cache.token else { return nil }
            return token
        }
        if let memoryCachedToken {
            Self.cacheLogger.debug("Tier 1: Using memory-cached OAuth token")
            return memoryCachedToken
        }

        // Tier 2: Own keychain cache (never prompts)
        // Use ignoreExpiry: the API will reject 401/403 if truly invalid,
        // which triggers invalidateOAuthCaches() in refreshFromAPI()
        if let cachedData = self.loadCLIOAuthCache(),
           let token = self.extractOAuthToken(from: cachedData, ignoreExpiry: true) {
            Self.cacheLogger.debug("Tier 2: Using keychain-cached OAuth token")
            // Populate memory cache for next time
            Self.memoryCache.withLock { $0.store(token: token) }
            return token
        }

        // Tier 3: CLI keychain via gate (may prompt on user-initiated, never on background)
        guard let data = CLIOAuthKeychainGate.shared.attemptRead(interaction: interaction) else {
            Self.cacheLogger.debug("Tier 3: No CLI keychain data available")
            return nil
        }

        // Extract token first — only cache if the blob contains a valid token
        // Use ignoreExpiry (same as tier-2): the API will reject 401/403 if truly invalid,
        // which triggers invalidateOAuthCaches() in refreshFromAPI()
        guard let token = self.extractOAuthToken(from: data, ignoreExpiry: true) else {
            Self.cacheLogger.debug("Tier 3: CLI keychain data did not contain a valid token, skipping cache")
            return nil
        }

        // Cache the validated data in our own keychain (never prompts on future reads)
        self.saveCLIOAuthCache(data)
        Self.memoryCache.withLock { $0.store(token: token) }
        Self.cacheLogger.debug("Tier 3: Resolved OAuth token from CLI keychain, cached in all tiers")
        return token
    }

    /// Invalidate all OAuth caches. Called on 401/403 API rejection.
    func invalidateOAuthCaches() {
        // Clear memory cache
        Self.memoryCache.withLock { $0.clear() }
        // Delete our keychain cache
        self.deleteCLIOAuthCache()
        // Clear gate cooldown so next refresh can re-read CLI keychain
        CLIOAuthKeychainGate.shared.clearCooldown()
        Self.cacheLogger.info("All OAuth caches invalidated")
    }

    // MARK: Private

    nonisolated private static let cacheLogger = Logger(
        subsystem: "com.engels74.ClaudeIsland",
        category: "CredentialCache",
    )

    private static let memoryCache = Mutex(OAuthMemoryCache())
    private static let memoryCacheTTL: TimeInterval = 1800 // 30 minutes

    private struct OAuthMemoryCache {
        var token: String?
        var cachedAt: Date?
        var credentialFileModDate: Date?

        var isValid: Bool {
            guard let cachedAt else { return false }
            return Date().timeIntervalSince(cachedAt) < TokenTrackingManager.memoryCacheTTL
        }

        mutating func clear() {
            self.token = nil
            self.cachedAt = nil
            // Keep credentialFileModDate — it tracks the file, not the cache
        }

        mutating func store(token: String) {
            self.token = token
            self.cachedAt = Date()
        }
    }

    /// Detect external changes to `~/.claude/.credentials.json`.
    private func checkCredentialFileChanged() -> Bool {
        let path = NSHomeDirectory() + "/.claude/.credentials.json"
        let fileManager = FileManager.default

        let attrs = try? fileManager.attributesOfItem(atPath: path)
        let modDate = attrs?[.modificationDate] as? Date

        return Self.memoryCache.withLock { cache in
            if let modDate {
                // File exists
                guard let storedModDate = cache.credentialFileModDate else {
                    // First check — record the date, don't treat as change
                    cache.credentialFileModDate = modDate
                    return false
                }

                if modDate != storedModDate {
                    cache.credentialFileModDate = modDate
                    return true // File changed
                }
                return false
            } else {
                // File doesn't exist or can't be read
                if cache.credentialFileModDate != nil {
                    // File was previously tracked but is now gone (e.g. CLI logout) — treat as change
                    cache.credentialFileModDate = nil
                    return true
                }
                return false
            }
        }
    }
}

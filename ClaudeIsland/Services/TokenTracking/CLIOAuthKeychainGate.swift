//
//  CLIOAuthKeychainGate.swift
//  ClaudeIsland
//
//  Encapsulates CLI keychain access with non-interactive preflight and denial cooldown.
//

import Foundation
import LocalAuthentication
import os.log

// MARK: - CLIOAuthKeychainGate

/// Encapsulates CLI keychain access with non-interactive preflight and denial cooldown.
/// Stateless service — all cooldown state lives in UserDefaults, making Sendable trivially correct.
/// `InteractionContext` is defined in TokenTrackingManager.swift (same module).
nonisolated struct CLIOAuthKeychainGate: Sendable {
    // MARK: Lifecycle

    nonisolated private init() {}

    // MARK: Internal

    enum PreflightResult: Sendable {
        case available(Data)
        case wouldPrompt
        case notFound
        case denied
    }

    nonisolated static let shared = Self()

    func attemptRead(interaction: InteractionContext) -> Data? {
        switch interaction {
        case .userInitiated:
            self.clearCooldown()
            return self.readCLIKeychain()

        case .background:
            if self.isInCooldown() {
                Self.logger.debug("Background read: in cooldown, skipping")
                return nil
            }

            let preflight = self.nonInteractivePreflight()
            switch preflight {
            case let .available(data):
                return data
            case .wouldPrompt:
                Self.logger.debug("Background read: would prompt, skipping")
                return nil
            case .notFound:
                return nil
            case .denied:
                self.enterCooldown()
                return nil
            }
        }
    }

    func clearCooldown() {
        UserDefaults.standard.removeObject(forKey: Self.cooldownKey)
        Self.logger.debug("Cooldown cleared")
    }

    // MARK: Private

    nonisolated private static let logger = Logger(
        subsystem: "com.engels74.ClaudeIsland",
        category: "CLIOAuthKeychainGate",
    )

    private static let cooldownInterval: TimeInterval = 60 * 60 * 6
    private static let cooldownKey = "cliKeychainDenialCooldown"
    private static let candidates: [(service: String, account: String)] = [
        ("Claude Code-credentials", NSUserName()),
        ("claude-cli", "oauth-tokens"),
    ]

    private func nonInteractivePreflight() -> PreflightResult {
        var anyDenied = false
        var worstResult: PreflightResult = .notFound

        for candidate in Self.candidates {
            let context = LAContext()
            context.interactionNotAllowed = true

            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: candidate.service,
                kSecAttrAccount as String: candidate.account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecUseAuthenticationContext as String: context,
            ]

            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)

            switch status {
            case errSecSuccess:
                if let data = result as? Data {
                    Self.logger.debug(
                        "Preflight: data available without prompt (service: \(candidate.service, privacy: .public))",
                    )
                    return .available(data)
                }
                Self.logger.warning(
                    "Preflight: errSecSuccess but no data (service: \(candidate.service, privacy: .public))",
                )

            case errSecInteractionNotAllowed:
                Self.logger.debug("Preflight: would prompt (service: \(candidate.service, privacy: .public))")
                worstResult = .wouldPrompt

            case errSecItemNotFound:
                Self.logger.debug("Preflight: not found (service: \(candidate.service, privacy: .public))")

            case errSecUserCanceled,
                 errSecAuthFailed:
                Self.logger.warning(
                    "Preflight: denied (status: \(status), service: \(candidate.service, privacy: .public))",
                )
                anyDenied = true

            case errSecNoAccessForItem:
                Self.logger.warning(
                    "Preflight: no access for item (service: \(candidate.service, privacy: .public))",
                )
                anyDenied = true

            default:
                Self.logger.debug(
                    "Preflight: status \(status) (service: \(candidate.service, privacy: .public))",
                )
            }
        }
        return anyDenied ? .denied : worstResult
    }

    private func readCLIKeychain() -> Data? {
        var anyDenied = false

        for candidate in Self.candidates {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: candidate.service,
                kSecAttrAccount as String: candidate.account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]

            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)

            if status == errSecSuccess, let data = result as? Data {
                Self.logger.debug(
                    "Direct read: found credentials (service: \(candidate.service, privacy: .public))",
                )
                return data
            }

            if status == errSecUserCanceled || status == errSecAuthFailed || status == errSecNoAccessForItem {
                Self.logger.warning(
                    "Direct read: denied (status: \(status), service: \(candidate.service, privacy: .public))",
                )
                anyDenied = true
                continue
            }

            Self.logger.debug(
                "Direct read: status \(status) (service: \(candidate.service, privacy: .public))",
            )
        }

        if anyDenied {
            self.enterCooldown()
        }
        return nil
    }

    private func isInCooldown() -> Bool {
        guard let deniedUntil = UserDefaults.standard.object(forKey: Self.cooldownKey) as? Date else {
            return false
        }
        return Date() < deniedUntil
    }

    private func enterCooldown() {
        let deniedUntil = Date().addingTimeInterval(Self.cooldownInterval)
        UserDefaults.standard.set(deniedUntil, forKey: Self.cooldownKey)
        Self.logger.info("Entering cooldown until \(deniedUntil)")
    }
}

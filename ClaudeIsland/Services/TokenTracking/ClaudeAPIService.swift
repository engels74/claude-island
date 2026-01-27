//
//  ClaudeAPIService.swift
//  ClaudeIsland
//
//  Service for fetching token usage data from Claude API
//

import Foundation
import os.log

// swiftlint:disable:next nonisolated_static_on_actor
private nonisolated(unsafe) let logger = Logger(subsystem: "com.engels74.ClaudeIsland", category: "ClaudeAPIService")

struct APIUsageResponse: Sendable {
    let fiveHour: UsageWindow
    let sevenDay: UsageWindow
}

struct UsageWindow: Sendable {
    let utilization: Double
    let resetsAt: Date
}

actor ClaudeAPIService {
    static let shared = ClaudeAPIService()

    private let baseURL = "https://claude.ai/api"
    private let oauthUsageURL = "https://api.anthropic.com/api/oauth/usage"

    func fetchUsage(sessionKey: String) async throws -> APIUsageResponse {
        let orgID = try await fetchOrganizationID(sessionKey: sessionKey)
        return try await fetchUsageData(sessionKey: sessionKey, orgID: orgID)
    }

    func fetchUsage(oauthToken: String) async throws -> APIUsageResponse {
        guard let url = URL(string: self.oauthUsageURL) else {
            throw APIServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(oauthToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("claude-code/2.1.5", forHTTPHeaderField: "User-Agent")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.httpMethod = "GET"
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIServiceError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            logger.error("OAuth usage request failed with status \(httpResponse.statusCode)")
            throw APIServiceError.httpError(statusCode: httpResponse.statusCode)
        }

        return try self.parseUsageResponse(data)
    }

    private func fetchOrganizationID(sessionKey: String) async throws -> String {
        logger.warning("[DEBUG] Fetching organization ID...")
        guard let url = URL(string: "\(self.baseURL)/organizations") else {
            throw APIServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpMethod = "GET"
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIServiceError.invalidResponse
        }

        logger.warning("[DEBUG] Organizations response status: \(httpResponse.statusCode)")

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "<no body>"
            logger.error("[DEBUG] Organizations request failed. Status: \(httpResponse.statusCode), Body: \(body)")
            throw APIServiceError.httpError(statusCode: httpResponse.statusCode)
        }

        let rawResponse = String(data: data, encoding: .utf8) ?? "<failed to decode>"
        logger.warning("[DEBUG] Organizations raw response: \(rawResponse)")

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            logger.error("[DEBUG] Failed to parse organizations JSON")
            throw APIServiceError.parsingFailed
        }

        // Find organization with "chat" capability (Pro/Max subscription)
        // API-only orgs don't have usage data
        let chatOrg = json.first { org in
            if let capabilities = org["capabilities"] as? [String] {
                return capabilities.contains("chat")
            }
            return false
        }

        guard let selectedOrg = chatOrg ?? json.first,
              let uuid = selectedOrg["uuid"] as? String
        else {
            logger.error("[DEBUG] No valid organization found")
            throw APIServiceError.parsingFailed
        }

        let orgName = selectedOrg["name"] as? String ?? "unknown"
        let capabilities = selectedOrg["capabilities"] as? [String] ?? []
        logger.warning("[DEBUG] Selected organization: \(orgName) (capabilities: \(capabilities))")
        logger.warning("[DEBUG] Organization ID: \(uuid)")
        return uuid
    }

    private func fetchUsageData(sessionKey: String, orgID: String) async throws -> APIUsageResponse {
        logger.warning("[DEBUG] Fetching usage data for org: \(orgID)")
        guard let url = URL(string: "\(self.baseURL)/organizations/\(orgID)/usage") else {
            throw APIServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Referer")
        request.httpMethod = "GET"
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIServiceError.invalidResponse
        }

        logger.warning("[DEBUG] Usage response status: \(httpResponse.statusCode)")

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "<no body>"
            logger.error("[DEBUG] Usage request failed. Status: \(httpResponse.statusCode), Body: \(body)")
            throw APIServiceError.httpError(statusCode: httpResponse.statusCode)
        }

        return try self.parseUsageResponse(data)
    }

    private func parseUsageResponse(_ data: Data) throws -> APIUsageResponse {
        let rawJSON = String(data: data, encoding: .utf8) ?? "<failed to decode>"
        logger.warning("[DEBUG] Raw API response: \(rawJSON)")

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.error("[DEBUG] Failed to parse JSON from response")
            throw APIServiceError.parsingFailed
        }

        let topLevelKeys = Array(json.keys).joined(separator: ", ")
        logger.warning("[DEBUG] Top-level JSON keys: \(topLevelKeys)")

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var sessionPercentage = 0.0
        var sessionResetTime = Date().addingTimeInterval(5 * 3600)
        if let fiveHour = json["five_hour"] as? [String: Any] {
            let fiveHourKeys = Array(fiveHour.keys).joined(separator: ", ")
            logger.warning("[DEBUG] five_hour keys: \(fiveHourKeys)")
            logger.warning("[DEBUG] five_hour.utilization raw value: \(String(describing: fiveHour["utilization"]))")
            sessionPercentage = self.parseUtilization(fiveHour["utilization"])
            logger.warning("[DEBUG] five_hour parsed utilization: \(sessionPercentage)")
            if let resetsAt = fiveHour["resets_at"] as? String,
               let date = formatter.date(from: resetsAt) {
                sessionResetTime = date
            }
        } else {
            logger.warning("[DEBUG] five_hour key MISSING from response")
        }

        var weeklyPercentage = 0.0
        var weeklyResetTime = Date().addingTimeInterval(7 * 24 * 3600)
        if let sevenDay = json["seven_day"] as? [String: Any] {
            let sevenDayKeys = Array(sevenDay.keys).joined(separator: ", ")
            logger.warning("[DEBUG] seven_day keys: \(sevenDayKeys)")
            logger.warning("[DEBUG] seven_day.utilization raw value: \(String(describing: sevenDay["utilization"]))")
            weeklyPercentage = self.parseUtilization(sevenDay["utilization"])
            logger.warning("[DEBUG] seven_day parsed utilization: \(weeklyPercentage)")
            if let resetsAt = sevenDay["resets_at"] as? String,
               let date = formatter.date(from: resetsAt) {
                weeklyResetTime = date
            }
        } else {
            logger.warning("[DEBUG] seven_day key MISSING from response")
        }

        logger.warning("[DEBUG] Final parsed values - session: \(sessionPercentage)%, weekly: \(weeklyPercentage)%")

        return APIUsageResponse(
            fiveHour: UsageWindow(utilization: sessionPercentage, resetsAt: sessionResetTime),
            sevenDay: UsageWindow(utilization: weeklyPercentage, resetsAt: weeklyResetTime)
        )
    }

    private func parseUtilization(_ value: Any?) -> Double {
        guard let value else { return 0 }

        if let intValue = value as? Int {
            return Double(intValue)
        }
        if let doubleValue = value as? Double {
            return doubleValue
        }
        if let stringValue = value as? String,
           let parsed = Double(stringValue.replacingOccurrences(of: "%", with: "")) {
            return parsed
        }
        return 0
    }
}

enum APIServiceError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int)
    case parsingFailed
    case unauthorized

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Invalid API URL"
        case .invalidResponse:
            "Invalid response from server"
        case let .httpError(statusCode):
            "HTTP error: \(statusCode)"
        case .parsingFailed:
            "Failed to parse response"
        case .unauthorized:
            "Unauthorized - session key may be expired"
        }
    }
}

//
//  SessionMetadataManager.swift
//  ClaudeIsland
//
//  Persists custom session metadata (colors, names) to UserDefaults
//

import SwiftUI

@Observable
@MainActor
final class SessionMetadataManager {
    static let shared = SessionMetadataManager()

    private(set) var sessionColors: [String: String] = [:]
    private(set) var sessionNames: [String: String] = [:]

    private let defaults = UserDefaults.standard
    private let colorsKey = "sessionColors"
    private let namesKey = "sessionNames"

    private init() {
        loadFromDefaults()
    }

    func color(for sessionID: String) -> Color? {
        guard let hex = sessionColors[sessionID] else { return nil }
        return Color(hex: hex)
    }

    func name(for sessionID: String) -> String? {
        sessionNames[sessionID]
    }

    func setColor(_ hex: String?, for sessionID: String) {
        if let hex {
            sessionColors[sessionID] = hex
        } else {
            sessionColors.removeValue(forKey: sessionID)
        }
        saveColors()
    }

    func setName(_ name: String?, for sessionID: String) {
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            sessionNames[sessionID] = name
        } else {
            sessionNames.removeValue(forKey: sessionID)
        }
        saveNames()
    }

    func clearMetadata(for sessionID: String) {
        sessionColors.removeValue(forKey: sessionID)
        sessionNames.removeValue(forKey: sessionID)
        saveColors()
        saveNames()
    }

    private func loadFromDefaults() {
        if let colorsData = defaults.data(forKey: colorsKey),
           let colors = try? JSONDecoder().decode([String: String].self, from: colorsData)
        {
            sessionColors = colors
        }

        if let namesData = defaults.data(forKey: namesKey),
           let names = try? JSONDecoder().decode([String: String].self, from: namesData)
        {
            sessionNames = names
        }
    }

    private func saveColors() {
        if let data = try? JSONEncoder().encode(sessionColors) {
            defaults.set(data, forKey: colorsKey)
        }
    }

    private func saveNames() {
        if let data = try? JSONEncoder().encode(sessionNames) {
            defaults.set(data, forKey: namesKey)
        }
    }
}

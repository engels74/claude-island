//
//  ScreenSelector.swift
//  ClaudeIsland
//
//  Manages screen selection state and persistence
//

import AppKit
import Foundation
import Observation

// MARK: - ScreenSelectionMode

/// Strategy for selecting which screen to use
enum ScreenSelectionMode: String, Codable {
    case automatic // Prefer built-in display, fall back to main
    case specificScreen // User selected a specific screen
}

// MARK: - ScreenIdentifier

/// Persistent identifier for a screen
struct ScreenIdentifier: Codable, Equatable, Hashable {
    // MARK: Lifecycle

    /// Create identifier from NSScreen
    init(screen: NSScreen) {
        if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            self.displayID = screenNumber
        } else {
            self.displayID = nil
        }
        self.localizedName = screen.localizedName
    }

    // MARK: Internal

    let displayID: CGDirectDisplayID?
    let localizedName: String

    /// Check if this identifier matches a given screen
    func matches(_ screen: NSScreen) -> Bool {
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return localizedName == screen.localizedName
        }
        // Primary match: displayID (most reliable when connected)
        if let savedID = displayID, savedID == screenNumber {
            return true
        }
        // Fallback: name match (for reconnected displays with new IDs)
        return localizedName == screen.localizedName
    }
}

// MARK: - ScreenSelector

/// Manages screen selection state and persistence
/// Uses @Observable macro for efficient property-level change tracking (macOS 14+)
@Observable
@MainActor
final class ScreenSelector {
    // MARK: Lifecycle

    private init() {
        loadPreferences()
        refreshScreens()
    }

    // MARK: Internal

    static let shared = ScreenSelector()

    // MARK: - Observable State

    private(set) var availableScreens: [NSScreen] = []
    private(set) var selectedScreen: NSScreen?
    var selectionMode: ScreenSelectionMode = .automatic
    var isPickerExpanded = false

    /// Extra height needed when picker is expanded
    var expandedPickerHeight: CGFloat {
        guard isPickerExpanded else { return 0 }
        // +1 for "Automatic" option
        return CGFloat(availableScreens.count + 1) * 40
    }

    // MARK: - Public API

    /// Refresh the available screens list
    func refreshScreens() {
        availableScreens = NSScreen.screens
        selectedScreen = resolveSelectedScreen()
    }

    /// Select a specific screen
    func selectScreen(_ screen: NSScreen) {
        selectionMode = .specificScreen
        savedIdentifier = ScreenIdentifier(screen: screen)
        selectedScreen = screen
        savePreferences()
    }

    /// Reset to automatic selection
    func selectAutomatic() {
        selectionMode = .automatic
        savedIdentifier = nil
        selectedScreen = resolveSelectedScreen()
        savePreferences()
    }

    /// Check if a screen is currently selected
    func isSelected(_ screen: NSScreen) -> Bool {
        guard let selected = selectedScreen else { return false }
        return screenID(of: screen) == screenID(of: selected)
    }

    // MARK: Private

    // MARK: - UserDefaults Keys

    private let modeKey = "screenSelectionMode"
    private let screenIdentifierKey = "selectedScreenIdentifier"

    // MARK: - Private State

    private var savedIdentifier: ScreenIdentifier?

    // MARK: - Private Methods

    private func screenID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    private func resolveSelectedScreen() -> NSScreen? {
        switch selectionMode {
        case .automatic:
            return NSScreen.builtin ?? NSScreen.main

        case .specificScreen:
            // Try to find the saved screen
            if let identifier = savedIdentifier,
               let match = availableScreens.first(where: { identifier.matches($0) }) {
                return match
            }
            // Saved screen not found - fall back to automatic
            return NSScreen.builtin ?? NSScreen.main
        }
    }

    private func loadPreferences() {
        if let modeString = UserDefaults.standard.string(forKey: modeKey),
           let mode = ScreenSelectionMode(rawValue: modeString) {
            selectionMode = mode
        }

        if let data = UserDefaults.standard.data(forKey: screenIdentifierKey),
           let identifier = try? JSONDecoder().decode(ScreenIdentifier.self, from: data) {
            savedIdentifier = identifier
        }
    }

    private func savePreferences() {
        UserDefaults.standard.set(selectionMode.rawValue, forKey: modeKey)

        if let identifier = savedIdentifier,
           let data = try? JSONEncoder().encode(identifier) {
            UserDefaults.standard.set(data, forKey: screenIdentifierKey)
        } else {
            UserDefaults.standard.removeObject(forKey: screenIdentifierKey)
        }
    }
}

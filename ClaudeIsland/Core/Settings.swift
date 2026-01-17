//
//  Settings.swift
//  ClaudeIsland
//
//  App settings manager using UserDefaults
//

import Foundation

// MARK: - SoundSuppression

/// Sound suppression modes for notification sounds
enum SoundSuppression: String, CaseIterable {
    case never = "Never"
    case whenFocused = "When Focused"
    case whenVisible = "When Visible"

    // MARK: Internal

    /// Description for UI display
    var description: String {
        switch self {
        case .never:
            "Sound always plays"
        case .whenFocused:
            "Suppresses audio when Claude Island or the terminal is active"
        case .whenVisible:
            "Suppresses audio when the terminal is visible (≥50% unobscured)"
        }
    }
}

// MARK: - NotificationSound

/// Available notification sounds
enum NotificationSound: String, CaseIterable {
    case none = "None"
    case pop = "Pop"
    case ping = "Ping"
    case tink = "Tink"
    case glass = "Glass"
    case blow = "Blow"
    case bottle = "Bottle"
    case frog = "Frog"
    case funk = "Funk"
    case hero = "Hero"
    case morse = "Morse"
    case purr = "Purr"
    case sosumi = "Sosumi"
    case submarine = "Submarine"
    case basso = "Basso"

    // MARK: Internal

    /// The system sound name to use with NSSound, or nil for no sound
    var soundName: String? {
        self == .none ? nil : rawValue
    }
}

// MARK: - AppSettings

enum AppSettings {
    // MARK: Internal

    // MARK: - Notification Sound

    /// The sound to play when Claude finishes and is ready for input
    static var notificationSound: NotificationSound {
        get {
            guard let rawValue = defaults.string(forKey: Keys.notificationSound),
                  let sound = NotificationSound(rawValue: rawValue)
            else {
                return .pop // Default to Pop
            }
            return sound
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.notificationSound)
        }
    }

    // MARK: - Sound Suppression

    /// When to suppress notification sounds
    static var soundSuppression: SoundSuppression {
        get {
            guard let rawValue = defaults.string(forKey: Keys.soundSuppression),
                  let suppression = SoundSuppression(rawValue: rawValue)
            else {
                return .whenFocused // Default to suppressing when terminal is focused
            }
            return suppression
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.soundSuppression)
        }
    }

    // MARK: Private

    // MARK: - Keys

    private enum Keys {
        static let notificationSound = "notificationSound"
        static let soundSuppression = "soundSuppression"
    }

    private static let defaults = UserDefaults.standard
}

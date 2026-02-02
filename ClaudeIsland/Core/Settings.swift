//
//  Settings.swift
//  ClaudeIsland
//
//  App settings manager using UserDefaults
//

import Foundation
import SwiftUI

// MARK: - SoundTrigger

enum SoundTrigger: String, CaseIterable {
    case inputOnly = "Input Only"
    case permissionOnly = "Permissions Only"
    case both = "Both"

    // MARK: Internal

    var playsForInput: Bool {
        self == .inputOnly || self == .both
    }

    var playsForPermission: Bool {
        self == .permissionOnly || self == .both
    }
}

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

    // MARK: - Sound Trigger

    static var soundTrigger: SoundTrigger {
        get {
            guard let rawValue = defaults.string(forKey: Keys.soundTrigger),
                  let trigger = SoundTrigger(rawValue: rawValue)
            else {
                return .both
            }
            return trigger
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.soundTrigger)
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

    // MARK: - Clawd Color

    /// The color for the Clawd character
    static var clawdColor: Color {
        get {
            guard let hex = defaults.string(forKey: Keys.clawdColor) else {
                return TerminalColors.prompt
            }
            return Color(hex: hex) ?? TerminalColors.prompt
        }
        set {
            defaults.set(newValue.hexString, forKey: Keys.clawdColor)
        }
    }

    // MARK: - Clawd Always Visible

    /// Whether the Clawd character should always be visible
    static var clawdAlwaysVisible: Bool {
        get { defaults.bool(forKey: Keys.clawdAlwaysVisible) }
        set { defaults.set(newValue, forKey: Keys.clawdAlwaysVisible) }
    }

    // MARK: Private

    // MARK: - Keys

    private enum Keys {
        static let notificationSound = "notificationSound"
        static let soundTrigger = "soundTrigger"
        static let soundSuppression = "soundSuppression"
        static let clawdColor = "clawdColor"
        static let clawdAlwaysVisible = "clawdAlwaysVisible"
    }

    private static let defaults = UserDefaults.standard
}

// MARK: - Color+Hex

extension Color {
    // MARK: Lifecycle

    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        guard hexSanitized.count == 6 else { return nil }

        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

        let red = Double((rgb & 0xFF0000) >> 16) / 255.0
        let green = Double((rgb & 0x00FF00) >> 8) / 255.0
        let blue = Double(rgb & 0x0000FF) / 255.0

        self.init(red: red, green: green, blue: blue)
    }

    init(hue: Double, saturation: Double, brightness: Double) {
        self.init(NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1.0))
    }

    // MARK: Internal

    var hexString: String {
        guard let components = NSColor(self).usingColorSpace(.sRGB)?.cgColor.components,
              components.count >= 3
        else {
            return "D97857"
        }

        let red = Int(components[0] * 255)
        let green = Int(components[1] * 255)
        let blue = Int(components[2] * 255)

        return String(format: "%02X%02X%02X", red, green, blue)
    }

    var hsbComponents: (hue: Double, saturation: Double, brightness: Double) {
        let nsColor = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        // Alpha parameter required by NSColor API but unused for HSB conversion
        var alpha: CGFloat = 0
        nsColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return (Double(hue), Double(saturation), Double(brightness))
    }
}

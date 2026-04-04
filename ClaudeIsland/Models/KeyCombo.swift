//
//  KeyCombo.swift
//  ClaudeIsland
//
//  Keyboard shortcut model
//

import AppKit
import Carbon
import Foundation

// MARK: - KeyCombo

struct KeyCombo: Hashable, Codable, Sendable {
    let keyCode: UInt16
    let modifiers: UInt

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: self.modifiers)
    }

    var displayString: String {
        var parts: [String] = []

        let flags = self.modifierFlags
        if flags.contains(.control) { parts.append("\u{2303}") }
        if flags.contains(.option) { parts.append("\u{2325}") }
        if flags.contains(.shift) { parts.append("\u{21E7}") }
        if flags.contains(.command) { parts.append("\u{2318}") }

        if let keyChar = Self.keyCodeToString(self.keyCode) {
            parts.append(keyChar)
        }

        return parts.joined()
    }

    var hasModifier: Bool {
        let flags = self.modifierFlags
        return flags.contains(.command) || flags.contains(.control) || flags.contains(.option) || flags.contains(.shift)
    }

    private static func keyCodeToString(_ keyCode: UInt16) -> String? {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = unsafeBitCast(layoutData, to: CFData.self) as Data
        return data.withUnsafeBytes { rawBuffer -> String? in
            guard let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeyState: UInt32 = 0
            var length: Int = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                ptr,
                keyCode,
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                UInt32(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                4,
                &length,
                &chars
            )
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length).uppercased()
        }
    }
}

// MARK: - HotkeyAction

enum HotkeyAction: Codable, Sendable, Equatable {
    case openLauncher
    case focusSession(sessionID: String)
}

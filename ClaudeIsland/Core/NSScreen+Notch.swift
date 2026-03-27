//
//  NSScreen+Notch.swift
//  ClaudeIsland
//
//  Extensions for NSScreen to detect notch and built-in display
//

import AppKit

extension NSScreen {
    /// Returns the reserved notch exclusion size on this screen.
    /// Width is intentionally conservative to guarantee closed-state modules remain outside the physical notch area.
    var notchSize: CGSize {
        guard safeAreaInsets.top > 0 else {
            // Fallback for non-notch displays (matches typical MacBook notch)
            return CGSize(width: 224, height: 38)
        }

        let notchHeight = safeAreaInsets.top
        return CGSize(
            width: self.reservedNotchExclusionWidth,
            height: notchHeight,
        )
    }

    /// Conservatively reserved center width where closed-state content should never render.
    var reservedNotchExclusionWidth: CGFloat {
        let baseWidth = self.notchExclusionBaseWidth
        return baseWidth + Self.notchSafetyPadding * 2
    }

    /// Base width before safety padding, derived from macOS top auxiliary areas.
    var notchExclusionBaseWidth: CGFloat {
        let leftPadding = auxiliaryTopLeftArea?.width ?? 0
        let rightPadding = auxiliaryTopRightArea?.width ?? 0

        guard leftPadding > 0, rightPadding > 0 else {
            // Fallback if auxiliary areas are unavailable on a notched display.
            return 224
        }

        return max(0, frame.width - leftPadding - rightPadding)
    }

    /// Whether this is the built-in display
    var isBuiltinDisplay: Bool {
        guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return false
        }
        return CGDisplayIsBuiltin(screenNumber) != 0
    }

    /// The built-in display (with notch on newer MacBooks)
    static var builtin: NSScreen? {
        if let builtin = screens.first(where: { $0.isBuiltinDisplay }) {
            return builtin
        }
        return NSScreen.main
    }

    /// Whether this screen has a physical notch (camera housing)
    var hasPhysicalNotch: Bool {
        safeAreaInsets.top > 0
    }

    private static let notchSafetyPadding: CGFloat = 12
}

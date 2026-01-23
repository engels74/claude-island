//
//  AccessibilityPermissionManager.swift
//  ClaudeIsland
//
//  Monitors macOS Accessibility permission status and provides UI integration
//

import AppKit
import ApplicationServices
import os

private let logger = Logger(subsystem: "com.engels74.ClaudeIsland", category: "AccessibilityPermission")

// MARK: - AccessibilityPermissionManager

/// Manages Accessibility permission state for the app.
/// Required for global mouse event monitoring and CGEvent posting.
@Observable
@MainActor
final class AccessibilityPermissionManager {
    // MARK: Lifecycle

    private init() {
        self.checkPermission()
    }

    // MARK: Internal

    static let shared = AccessibilityPermissionManager()

    /// Current accessibility permission state
    private(set) var isAccessibilityEnabled = false

    /// Check the current permission state
    func checkPermission() {
        self.isAccessibilityEnabled = AXIsProcessTrusted()
        logger.debug("Accessibility permission check: \(self.isAccessibilityEnabled)")
    }

    /// Start periodic monitoring until permission is granted
    /// Checks every 2 seconds, stops when permission is granted
    func startPeriodicMonitoring() {
        // Don't start if already monitoring or already enabled
        guard self.checkTimer == nil else { return }

        logger.info("Starting periodic accessibility permission monitoring")

        self.checkTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.checkPermission()

                if self.isAccessibilityEnabled {
                    logger.info("Accessibility permission granted, stopping monitoring")
                    self.stopPeriodicMonitoring()
                }
            }
        }
    }

    /// Stop periodic monitoring
    func stopPeriodicMonitoring() {
        self.checkTimer?.invalidate()
        self.checkTimer = nil
    }

    /// Prompt for accessibility permission using system dialog
    /// This triggers the macOS "App would like to control this computer" dialog
    func promptForPermission() {
        logger.info("Prompting for accessibility permission")

        // AXIsProcessTrustedWithOptions with prompt=true triggers the system dialog
        // Use CFString literal directly to avoid concurrency issues with kAXTrustedCheckOptionPrompt
        let options = ["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        // Start monitoring after prompting so we detect when user grants permission
        self.startPeriodicMonitoring()
    }

    /// Open System Preferences directly to Accessibility settings
    func openAccessibilitySettings() {
        logger.info("Opening Accessibility settings")
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        // Start monitoring after opening settings
        self.startPeriodicMonitoring()
    }

    /// Show an alert explaining why accessibility permission is needed
    /// Returns true if user clicked "Open Settings", false if they clicked "Later"
    @discardableResult
    func showPermissionAlert() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = """
        Claude Island needs Accessibility permission to:

        • Monitor mouse position to show/hide the notch
        • Pass clicks through to apps behind the notch

        Without this permission, the app will have limited functionality.

        If you previously granted permission but it stopped working after an update, you may need to remove and re-add the app in System Settings.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            self.openAccessibilitySettings()
            return true
        }

        return false
    }

    // MARK: Private

    @ObservationIgnored private var checkTimer: Timer?
}

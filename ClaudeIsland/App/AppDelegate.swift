import AppKit
import os
import Sparkle
import SwiftUI

private let logger = Logger(subsystem: "com.engels74.ClaudeIsland", category: "AppDelegate")

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: Lifecycle

    override init() {
        self.userDriver = NotchUserDriver()
        updater = SPUUpdater(
            hostBundle: Bundle.main,
            applicationBundle: Bundle.main,
            userDriver: self.userDriver,
            delegate: nil
        )
        super.init()
        Self.shared = self

        do {
            try updater.start()
        } catch {
            logger.error("Failed to start Sparkle updater: \(error.localizedDescription)")
        }
    }

    // MARK: Internal

    static var shared: AppDelegate?

    let updater: SPUUpdater

    var windowController: NotchWindowController? {
        self.windowManager?.windowController
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !self.ensureSingleInstance() {
            NSApplication.shared.terminate(nil)
            return
        }

        HookInstaller.installIfNeeded()
        NSApplication.shared.setActivationPolicy(.accessory)

        self.windowManager = WindowManager()
        _ = self.windowManager?.setupNotchWindow()

        self.screenObserver = ScreenObserver { [weak self] in
            self?.handleScreenChange()
        }

        if updater.canCheckForUpdates {
            updater.checkForUpdates()
        }

        self.updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            guard let updater = self?.updater, updater.canCheckForUpdates else { return }
            updater.checkForUpdates()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Stop socket server and clean up socket file
        HookSocketServer.shared.stop()

        // Stop interrupt watchers
        InterruptWatcherManager.shared.stopAll()

        self.updateCheckTimer?.invalidate()
        self.screenObserver = nil
    }

    // MARK: Private

    private var windowManager: WindowManager?
    private var screenObserver: ScreenObserver?
    private var updateCheckTimer: Timer?

    private let userDriver: NotchUserDriver

    private func handleScreenChange() {
        _ = self.windowManager?.setupNotchWindow()
    }

    private func ensureSingleInstance() -> Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.engels74.ClaudeIsland"
        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleID
        }

        if runningApps.count > 1 {
            if let existingApp = runningApps.first(where: { $0.processIdentifier != getpid() }) {
                existingApp.activate()
            }
            return false
        }

        return true
    }
}

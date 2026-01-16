//
//  NotchUserDriver.swift
//  ClaudeIsland
//
//  Custom Sparkle user driver for in-notch update UI
//

import Combine
import Foundation
import Sparkle

// MARK: - UpdateState

/// Update state published to UI
enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate
    case found(version: String, releaseNotes: String?)
    case downloading(progress: Double) // 0.0 to 1.0
    case extracting(progress: Double)
    case readyToInstall(version: String)
    case installing
    case error(message: String)

    // MARK: Internal

    var isActive: Bool {
        switch self {
        case .idle,
             .upToDate,
             .error:
            false
        default:
            true
        }
    }
}

// MARK: - UpdateManager

/// Observable update manager that bridges Sparkle to SwiftUI
@MainActor
class UpdateManager: NSObject, ObservableObject {
    // MARK: Lifecycle

    override init() {
        super.init()
    }

    // MARK: Internal

    static let shared = UpdateManager()

    @Published var state: UpdateState = .idle
    @Published var hasUnseenUpdate = false

    // MARK: - Public API

    func checkForUpdates() {
        state = .checking
        if let updater = AppDelegate.shared?.updater {
            updater.checkForUpdates()
        } else {
            state = .error(message: "Updater not initialized")
        }
    }

    func downloadAndInstall() {
        installHandler?(.install)
    }

    func installAndRelaunch() {
        installHandler?(.install)
    }

    func skipUpdate() {
        installHandler?(.skip)
        state = .idle
    }

    func dismissUpdate() {
        installHandler?(.dismiss)
        state = .idle
    }

    func cancelDownload() {
        cancellationHandler?()
        state = .idle
    }

    // MARK: - Internal state updates (called by NotchUserDriver)

    func updateFound(version: String, releaseNotes: String?, installHandler: @escaping (SPUUserUpdateChoice) -> Void) {
        currentVersion = version
        self.installHandler = installHandler
        state = .found(version: version, releaseNotes: releaseNotes)
        // Only show the dot if user hasn't seen it this session
        if !hasSeenUpdateThisSession {
            hasUnseenUpdate = true
        }
    }

    func markUpdateSeen() {
        hasUnseenUpdate = false
        hasSeenUpdateThisSession = true
    }

    func downloadStarted(cancellation: @escaping () -> Void) {
        cancellationHandler = cancellation
        downloadedBytes = 0
        expectedBytes = 0
        state = .downloading(progress: 0)
    }

    func downloadExpectedLength(_ length: UInt64) {
        expectedBytes = Int64(length)
    }

    func downloadReceivedData(_ length: UInt64) {
        downloadedBytes += Int64(length)
        let progress = expectedBytes > 0 ? Double(downloadedBytes) / Double(expectedBytes) : 0
        state = .downloading(progress: min(progress, 1.0))
    }

    func extractionStarted() {
        state = .extracting(progress: 0)
    }

    func extractionProgress(_ progress: Double) {
        state = .extracting(progress: progress)
    }

    func readyToInstall(installHandler: @escaping (SPUUserUpdateChoice) -> Void) {
        self.installHandler = installHandler
        state = .readyToInstall(version: currentVersion)
    }

    func installing() {
        state = .installing
    }

    func installed(relaunched: Bool) {
        state = .idle
    }

    func noUpdateFound() {
        state = .upToDate
        // Reset to idle after a few seconds
        Task {
            try? await Task.sleep(for: .seconds(5))
            if case .upToDate = self.state {
                self.state = .idle
            }
        }
    }

    func updateError(_ message: String) {
        state = .error(message: message)
    }

    func dismiss() {
        // Don't dismiss if we're showing "up to date" - let it display
        if case .upToDate = state {
            return
        }
        state = .idle
        installHandler = nil
        cancellationHandler = nil
    }

    // MARK: Private

    private var hasSeenUpdateThisSession = false

    private var downloadedBytes: Int64 = 0
    private var expectedBytes: Int64 = 0
    private var currentVersion = ""

    // Callbacks from Sparkle
    private var installHandler: ((SPUUserUpdateChoice) -> Void)?
    private var cancellationHandler: (() -> Void)?
}

// MARK: - NotchUserDriver

/// Custom Sparkle user driver that routes all UI to NotchUpdateManager
class NotchUserDriver: NSObject, SPUUserDriver {
    var canCheckForUpdates: Bool { true }

    // MARK: - Update Found

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Auto-approve update checks
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        Task { @MainActor in
            UpdateManager.shared.state = .checking
        }
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let version = appcastItem.displayVersionString
        let releaseNotes = appcastItem.itemDescription

        Task { @MainActor in
            UpdateManager.shared.updateFound(version: version, releaseNotes: releaseNotes, installHandler: reply)
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // Release notes downloaded - we already have them from appcastItem
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        // Ignore release notes failures
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        Task { @MainActor in
            UpdateManager.shared.noUpdateFound()
        }
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        Task { @MainActor in
            UpdateManager.shared.updateError(error.localizedDescription)
        }
        acknowledgement()
    }

    // MARK: - Download Progress

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        Task { @MainActor in
            UpdateManager.shared.downloadStarted(cancellation: cancellation)
        }
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        Task { @MainActor in
            UpdateManager.shared.downloadExpectedLength(expectedContentLength)
        }
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        Task { @MainActor in
            UpdateManager.shared.downloadReceivedData(length)
        }
    }

    func showDownloadDidStartExtractingUpdate() {
        Task { @MainActor in
            UpdateManager.shared.extractionStarted()
        }
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        Task { @MainActor in
            UpdateManager.shared.extractionProgress(progress)
        }
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        Task { @MainActor in
            UpdateManager.shared.readyToInstall(installHandler: reply)
        }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        Task { @MainActor in
            UpdateManager.shared.installing()
        }
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        Task { @MainActor in
            UpdateManager.shared.installed(relaunched: relaunched)
        }
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        Task { @MainActor in
            UpdateManager.shared.dismiss()
        }
    }

    // MARK: - Resume/Focus

    func showUpdateInFocus() {
        // Could expand notch here if desired
    }

    func showResumableUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // Resumable update - treat same as regular update found
        showUpdateFound(with: appcastItem, state: state, reply: reply)
    }

    func showInformationalUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // Informational only - dismiss for now
        reply(.dismiss)
    }
}

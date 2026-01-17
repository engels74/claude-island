//
//  NotchView.swift
//  ClaudeIsland
//
//  The main dynamic island SwiftUI view with accurate notch shape
//

import AppKit
import CoreGraphics
import SwiftUI

/// Corner radius constants
private let cornerRadiusInsets = (
    opened: (top: CGFloat(19), bottom: CGFloat(24)),
    closed: (top: CGFloat(6), bottom: CGFloat(14))
)

// MARK: - NotchView

// swiftlint:disable:next type_body_length
struct NotchView: View {
    // MARK: Lifecycle

    init(viewModel: NotchViewModel) {
        self.viewModel = viewModel
    }

    // MARK: Internal

    /// View model is @Observable, so SwiftUI automatically tracks property access
    var viewModel: NotchViewModel

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .top) {
            // Outer container does NOT receive hits - only the notch content does
            VStack(spacing: 0) {
                self.notchLayout
                    .frame(
                        maxWidth: self.viewModel.status == .opened ? self.notchSize.width : nil,
                        alignment: .top
                    )
                    .padding(
                        .horizontal,
                        self.viewModel.status == .opened
                            ? cornerRadiusInsets.opened.top
                            : cornerRadiusInsets.closed.bottom
                    )
                    .padding([.horizontal, .bottom], self.viewModel.status == .opened ? 12 : 0)
                    .background(.black)
                    .clipShape(self.currentNotchShape)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(.black)
                            .frame(height: 1)
                            .padding(.horizontal, self.topCornerRadius)
                    }
                    .shadow(
                        color: (self.viewModel.status == .opened || self.isHovering) ? .black.opacity(0.7) : .clear,
                        radius: 6
                    )
                    .frame(
                        maxWidth: self.viewModel.status == .opened ? self.notchSize.width : nil,
                        maxHeight: self.viewModel.status == .opened ? self.notchSize.height : nil,
                        alignment: .top
                    )
                    .animation(self.viewModel.status == .opened ? self.openAnimation : self.closeAnimation, value: self.viewModel.status)
                    .animation(self.openAnimation, value: self.notchSize) // Animate container size changes between content types
                    .animation(.smooth, value: self.activityCoordinator.expandingActivity)
                    .animation(.smooth, value: self.hasPendingPermission)
                    .animation(.smooth, value: self.hasWaitingForInput)
                    .animation(.spring(response: 0.3, dampingFraction: 0.5), value: self.isBouncing)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
                            self.isHovering = hovering
                        }
                    }
                    .onTapGesture {
                        if self.viewModel.status != .opened {
                            self.viewModel.notchOpen(reason: .click)
                        }
                    }
            }
        }
        .opacity(self.isVisible ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
        .onAppear {
            self.sessionMonitor.startMonitoring()
            // On non-notched devices, keep visible so users have a target to interact with
            if !self.viewModel.hasPhysicalNotch {
                self.isVisible = true
            }
        }
        .onChange(of: self.viewModel.status) { oldStatus, newStatus in
            self.handleStatusChange(from: oldStatus, to: newStatus)
        }
        .onChange(of: self.sessionMonitor.pendingInstances) { _, sessions in
            self.handlePendingSessionsChange(sessions)
        }
        .onChange(of: self.sessionMonitor.instances) { _, instances in
            self.handleProcessingChange()
            self.handleWaitingForInputChange(instances)
        }
    }

    // MARK: Private

    /// Session monitor is @Observable, so we use @State for ownership
    @State private var sessionMonitor = ClaudeSessionMonitor()
    /// UpdateManager inherits from NSObject for Sparkle integration - intentional exception to @Observable pattern
    @ObservedObject private var updateManager = UpdateManager.shared
    @State private var previousPendingIDs: Set<String> = []
    @State private var previousWaitingForInputIDs: Set<String> = []
    @State private var waitingForInputTimestamps: [String: Date] = [:] // sessionID -> when it entered waitingForInput
    @State private var isVisible = false
    @State private var isHovering = false
    @State private var isBouncing = false
    @State private var hideVisibilityTask: Task<Void, Never>?
    @State private var bounceTask: Task<Void, Never>?
    @State private var checkmarkHideTask: Task<Void, Never>?
    @Namespace private var activityNamespace

    /// Singleton is @Observable, so SwiftUI automatically tracks property access
    private var activityCoordinator = NotchActivityCoordinator.shared

    // Animation springs
    private let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
    private let closeAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)

    /// Prefix indicating context was resumed (not a true "done" state)
    private let contextResumePrefix = "This session is being continued from a previous conversation"

    /// Whether any Claude session is currently processing or compacting
    private var isAnyProcessing: Bool {
        self.sessionMonitor.instances.contains { $0.phase == .processing || $0.phase == .compacting }
    }

    /// Whether any Claude session has a pending permission request
    private var hasPendingPermission: Bool {
        self.sessionMonitor.instances.contains { $0.phase.isWaitingForApproval }
    }

    /// Whether any Claude session is waiting for user input (done/ready state) within the display window
    private var hasWaitingForInput: Bool {
        let now = Date()
        let displayDuration: TimeInterval = 30 // Show checkmark for 30 seconds

        return self.sessionMonitor.instances.contains { session in
            guard session.phase == .waitingForInput else { return false }
            // Only show if within the 30-second display window
            if let enteredAt = waitingForInputTimestamps[session.stableID] {
                return now.timeIntervalSince(enteredAt) < displayDuration
            }
            return false
        }
    }

    // MARK: - Sizing

    private var closedNotchSize: CGSize {
        CGSize(
            width: self.viewModel.deviceNotchRect.width,
            height: self.viewModel.deviceNotchRect.height
        )
    }

    /// Extra width for expanding activities (like Dynamic Island)
    private var expansionWidth: CGFloat {
        // Permission indicator adds width on left side only
        let permissionIndicatorWidth: CGFloat = self.hasPendingPermission ? 18 : 0

        // Expand for processing activity
        if self.activityCoordinator.expandingActivity.show {
            switch self.activityCoordinator.expandingActivity.type {
            case .claude:
                let baseWidth = 2 * max(0, self.closedNotchSize.height - 12) + 20
                return baseWidth + permissionIndicatorWidth
            case .none:
                break
            }
        }

        // Expand for pending permissions (left indicator) or waiting for input (checkmark on right)
        if self.hasPendingPermission {
            return 2 * max(0, self.closedNotchSize.height - 12) + 20 + permissionIndicatorWidth
        }

        // Waiting for input just shows checkmark on right, no extra left indicator
        if self.hasWaitingForInput {
            return 2 * max(0, self.closedNotchSize.height - 12) + 20
        }

        return 0
    }

    private var notchSize: CGSize {
        switch self.viewModel.status {
        case .closed,
             .popping:
            self.closedNotchSize
        case .opened:
            self.viewModel.openedSize
        }
    }

    /// Width of the closed content (notch + any expansion)
    private var closedContentWidth: CGFloat {
        self.closedNotchSize.width + self.expansionWidth
    }

    // MARK: - Corner Radii

    private var topCornerRadius: CGFloat {
        self.viewModel.status == .opened
            ? cornerRadiusInsets.opened.top
            : cornerRadiusInsets.closed.top
    }

    private var bottomCornerRadius: CGFloat {
        self.viewModel.status == .opened
            ? cornerRadiusInsets.opened.bottom
            : cornerRadiusInsets.closed.bottom
    }

    private var currentNotchShape: NotchShape {
        NotchShape(
            topCornerRadius: self.topCornerRadius,
            bottomCornerRadius: self.bottomCornerRadius
        )
    }

    // MARK: - Notch Layout

    private var isProcessing: Bool {
        self.activityCoordinator.expandingActivity.show && self.activityCoordinator.expandingActivity.type == .claude
    }

    /// Whether to show the expanded closed state (processing, pending permission, or waiting for input)
    private var showClosedActivity: Bool {
        self.isProcessing || self.hasPendingPermission || self.hasWaitingForInput
    }

    private var sideWidth: CGFloat {
        max(0, self.closedNotchSize.height - 12) + 10
    }

    @ViewBuilder private var notchLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row - always present, contains crab and spinner that persist across states
            self.headerRow
                .frame(height: max(24, self.closedNotchSize.height))

            // Main content only when opened
            if self.viewModel.status == .opened {
                self.contentView
                    .frame(width: self.notchSize.width - 24) // Fixed width to prevent reflow
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.8, anchor: .top)
                                .combined(with: .opacity)
                                .animation(.smooth(duration: 0.35)),
                            removal: .opacity.animation(.easeOut(duration: 0.15))
                        )
                    )
            }
        }
    }

    // MARK: - Header Row (persists across states)

    @ViewBuilder private var headerRow: some View {
        HStack(spacing: 0) {
            // Left side - crab + optional permission indicator (visible when processing, pending, or waiting for input)
            if self.showClosedActivity {
                HStack(spacing: 4) {
                    ClaudeCrabIcon(size: 14, animateLegs: self.isProcessing)
                        .matchedGeometryEffect(id: "crab", in: self.activityNamespace, isSource: self.showClosedActivity)

                    // Permission indicator only (amber) - waiting for input shows checkmark on right
                    if self.hasPendingPermission {
                        PermissionIndicatorIcon(size: 14, color: Color(red: 0.85, green: 0.47, blue: 0.34))
                            .matchedGeometryEffect(id: "status-indicator", in: self.activityNamespace, isSource: self.showClosedActivity)
                    }
                }
                .frame(width: self.viewModel.status == .opened ? nil : self.sideWidth + (self.hasPendingPermission ? 18 : 0))
                .padding(.leading, self.viewModel.status == .opened ? 8 : 0)
            }

            // Center content
            if self.viewModel.status == .opened {
                // Opened: show header content
                self.openedHeaderContent
            } else if !self.showClosedActivity {
                // Closed without activity: empty space
                Rectangle()
                    .fill(.clear)
                    .frame(width: self.closedNotchSize.width - 20)
            } else {
                // Closed with activity: black spacer (with optional bounce)
                Rectangle()
                    .fill(.black)
                    .frame(width: self.closedNotchSize.width - cornerRadiusInsets.closed.top + (self.isBouncing ? 16 : 0))
            }

            // Right side - spinner when processing/pending, checkmark when waiting for input
            if self.showClosedActivity {
                if self.isProcessing || self.hasPendingPermission {
                    ProcessingSpinner()
                        .matchedGeometryEffect(id: "spinner", in: self.activityNamespace, isSource: self.showClosedActivity)
                        .frame(width: self.viewModel.status == .opened ? 20 : self.sideWidth)
                        .padding(.trailing, self.viewModel.status == .opened ? 0 : 4)
                } else if self.hasWaitingForInput {
                    // Checkmark for waiting-for-input on the right side
                    ReadyForInputIndicatorIcon(size: 14, color: TerminalColors.green)
                        .matchedGeometryEffect(id: "spinner", in: self.activityNamespace, isSource: self.showClosedActivity)
                        .frame(width: self.viewModel.status == .opened ? 20 : self.sideWidth)
                        .padding(.trailing, self.viewModel.status == .opened ? 0 : 4)
                }
            }
        }
        .frame(height: self.closedNotchSize.height)
    }

    // MARK: - Opened Header Content

    @ViewBuilder private var openedHeaderContent: some View {
        HStack(spacing: 12) {
            // Show static crab only if not showing activity in headerRow
            // (headerRow handles crab + indicator when showClosedActivity is true)
            if !self.showClosedActivity {
                ClaudeCrabIcon(size: 14)
                    .matchedGeometryEffect(id: "crab", in: self.activityNamespace, isSource: !self.showClosedActivity)
                    .padding(.leading, 8)
            }

            Spacer()

            // Menu toggle
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    self.viewModel.toggleMenu()
                    if self.viewModel.contentType == .menu {
                        self.updateManager.markUpdateSeen()
                    }
                }
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: self.viewModel.contentType == .menu ? "xmark" : "line.3.horizontal")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.4))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())

                    // Green dot for unseen update
                    if self.updateManager.hasUnseenUpdate && self.viewModel.contentType != .menu {
                        Circle()
                            .fill(TerminalColors.green)
                            .frame(width: 6, height: 6)
                            .offset(x: -2, y: 2)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Content View (Opened State)

    @ViewBuilder private var contentView: some View {
        Group {
            switch self.viewModel.contentType {
            case .instances:
                ClaudeInstancesView(
                    sessionMonitor: self.sessionMonitor,
                    viewModel: self.viewModel
                )
            case .menu:
                NotchMenuView(viewModel: self.viewModel)
            case let .chat(session):
                ChatView(
                    sessionID: session.sessionID,
                    initialSession: session,
                    sessionMonitor: self.sessionMonitor,
                    viewModel: self.viewModel
                )
            }
        }
        .frame(width: self.notchSize.width - 24) // Fixed width to prevent text reflow
        // Removed .id() - was causing view recreation and performance issues
    }

    // MARK: - Event Handlers

    private func handleProcessingChange() {
        if self.isAnyProcessing || self.hasPendingPermission {
            // Show claude activity when processing or waiting for permission
            self.activityCoordinator.showActivity(type: .claude)
            self.isVisible = true
            self.hideVisibilityTask?.cancel()
        } else if self.hasWaitingForInput {
            // Keep visible for waiting-for-input but hide the processing spinner
            self.activityCoordinator.hideActivity()
            self.isVisible = true
            self.hideVisibilityTask?.cancel()
        } else {
            // Hide activity when done
            self.activityCoordinator.hideActivity()

            // Delay hiding the notch until animation completes
            // Don't hide on non-notched devices - users need a visible target
            if self.viewModel.status == .closed && self.viewModel.hasPhysicalNotch {
                self.hideVisibilityTask?.cancel()
                self.hideVisibilityTask = Task {
                    try? await Task.sleep(for: .seconds(0.5))
                    guard !Task.isCancelled else { return }
                    if !self.isAnyProcessing && !self.hasPendingPermission && !self.hasWaitingForInput && self.viewModel.status == .closed {
                        self.isVisible = false
                    }
                }
            }
        }
    }

    private func handleStatusChange(from oldStatus: NotchStatus, to newStatus: NotchStatus) {
        switch newStatus {
        case .opened,
             .popping:
            self.isVisible = true
            self.hideVisibilityTask?.cancel()
            // Clear waiting-for-input timestamps only when manually opened (user acknowledged)
            if self.viewModel.openReason == .click || self.viewModel.openReason == .hover {
                self.waitingForInputTimestamps.removeAll()
            }
        case .closed:
            // Don't hide on non-notched devices - users need a visible target
            guard self.viewModel.hasPhysicalNotch else { return }
            self.hideVisibilityTask?.cancel()
            self.hideVisibilityTask = Task {
                try? await Task.sleep(for: .seconds(0.35))
                guard !Task.isCancelled else { return }
                if self.viewModel.status == .closed && !self.isAnyProcessing && !self.hasPendingPermission && !self.hasWaitingForInput && !self
                    .activityCoordinator
                    .expandingActivity.show {
                    self.isVisible = false
                }
            }
        }
    }

    private func handlePendingSessionsChange(_ sessions: [SessionState]) {
        let currentIDs = Set(sessions.map(\.stableID))
        let newPendingIDs = currentIDs.subtracting(self.previousPendingIDs)

        if !newPendingIDs.isEmpty &&
            self.viewModel.status == .closed &&
            !TerminalVisibilityDetector.isTerminalVisibleOnCurrentSpace() {
            self.viewModel.notchOpen(reason: .notification)
        }

        self.previousPendingIDs = currentIDs
    }

    private func handleWaitingForInputChange(_ instances: [SessionState]) {
        // Get sessions that are now waiting for input
        let waitingForInputSessions = instances.filter { $0.phase == .waitingForInput }
        let currentIDs = Set(waitingForInputSessions.map(\.stableID))
        let newWaitingIDs = currentIDs.subtracting(self.previousWaitingForInputIDs)

        // Track timestamps for newly waiting sessions
        let now = Date()
        for session in waitingForInputSessions where newWaitingIDs.contains(session.stableID) {
            waitingForInputTimestamps[session.stableID] = now
        }

        // Clean up timestamps for sessions no longer waiting
        let staleIDs = Set(waitingForInputTimestamps.keys).subtracting(currentIDs)
        for staleID in staleIDs {
            self.waitingForInputTimestamps.removeValue(forKey: staleID)
        }

        // Bounce the notch when a session newly enters waitingForInput state
        if !newWaitingIDs.isEmpty {
            // Get the sessions that just entered waitingForInput, excluding context resumes
            let newlyWaitingSessions = waitingForInputSessions.filter { session in
                guard newWaitingIDs.contains(session.stableID) else { return false }

                // Don't alert for context resume (ran out of context window)
                if let lastMessage = session.lastMessage,
                   lastMessage.hasPrefix(contextResumePrefix) {
                    return false
                }
                return true
            }

            // Skip all alerts if only context resumes remain
            guard !newlyWaitingSessions.isEmpty else {
                self.previousWaitingForInputIDs = currentIDs
                return
            }

            // Play notification sound if the session is not actively focused
            if let soundName = AppSettings.notificationSound.soundName {
                // Check if we should play sound (async check for tmux pane focus)
                Task {
                    let shouldPlaySound = await shouldPlayNotificationSound(for: newlyWaitingSessions)
                    if shouldPlaySound {
                        await MainActor.run {
                            NSSound(named: soundName)?.play()
                        }
                    }
                }
            }

            // Trigger bounce animation to get user's attention
            self.bounceTask?.cancel()
            self.isBouncing = true
            self.bounceTask = Task {
                // Bounce back after a short delay
                try? await Task.sleep(for: .seconds(0.15))
                guard !Task.isCancelled else { return }
                self.isBouncing = false
            }

            // Schedule hiding the checkmark after 30 seconds
            self.checkmarkHideTask?.cancel()
            self.checkmarkHideTask = Task {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                // Trigger a UI update to re-evaluate hasWaitingForInput
                self.handleProcessingChange()
            }
        }

        self.previousWaitingForInputIDs = currentIDs
    }

    /// Determine if notification sound should play for the given sessions
    /// Returns true if sound should play based on suppression settings
    private func shouldPlayNotificationSound(for sessions: [SessionState]) async -> Bool {
        let suppressionMode = AppSettings.soundSuppression

        // If suppression is disabled, always play sound
        if suppressionMode == .never {
            return true
        }

        // Suppress if Claude Island is active
        if NSApplication.shared.isActive {
            return false
        }

        // Check each session against the suppression mode
        for session in sessions {
            guard let pid = session.pid else {
                // No PID means we can't check focus/visibility, assume should play
                return true
            }

            switch suppressionMode {
            case .never:
                // Already handled above, but included for completeness
                return true

            case .whenFocused:
                // Suppress if the session's terminal is focused
                let isFocused = await TerminalVisibilityDetector.isSessionFocused(sessionPID: pid)
                if !isFocused {
                    return true
                }

            case .whenVisible:
                // Suppress if the session's terminal window is ≥50% visible
                let isVisible = await TerminalVisibilityDetector.isSessionTerminalVisible(sessionPID: pid)
                if !isVisible {
                    return true
                }
            }
        }

        // All sessions are suppressed
        return false
    }
}

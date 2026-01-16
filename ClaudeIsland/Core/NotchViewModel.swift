//
//  NotchViewModel.swift
//  ClaudeIsland
//
//  State management for the dynamic island
//

import AppKit
import Combine
import Observation
import SwiftUI

// MARK: - NotchStatus

enum NotchStatus: Equatable {
    case closed
    case opened
    case popping
}

// MARK: - NotchOpenReason

enum NotchOpenReason {
    case click
    case hover
    case notification
    case boot
    case unknown
}

// MARK: - NotchContentType

enum NotchContentType: Equatable {
    case instances
    case menu
    case chat(SessionState)

    // MARK: Internal

    var id: String {
        switch self {
        case .instances: "instances"
        case .menu: "menu"
        case let .chat(session): "chat-\(session.sessionID)"
        }
    }
}

// MARK: - NotchViewModel

/// State management for the dynamic island notch UI
/// Uses @Observable macro for efficient property-level change tracking (macOS 14+)
@Observable
@MainActor
final class NotchViewModel {
    // MARK: Lifecycle

    // MARK: - Initialization

    init(deviceNotchRect: CGRect, screenRect: CGRect, windowHeight: CGFloat, hasPhysicalNotch: Bool) {
        self.geometry = NotchGeometry(
            deviceNotchRect: deviceNotchRect,
            screenRect: screenRect,
            windowHeight: windowHeight
        )
        self.hasPhysicalNotch = hasPhysicalNotch
        setupEventHandlers()
        observeSelectors()
    }

    // MARK: Internal

    // MARK: - Observable State

    var status: NotchStatus = .closed
    var openReason: NotchOpenReason = .unknown
    var contentType: NotchContentType = .instances
    var isHovering = false

    // MARK: - Geometry

    let geometry: NotchGeometry
    let spacing: CGFloat = 12
    let hasPhysicalNotch: Bool

    /// Tracks selector expansion state changes to trigger view updates
    /// (With @Observable, views reading openedSize will observe this and re-compute when selectors change)
    private(set) var selectorUpdateToken: UInt = 0

    var deviceNotchRect: CGRect { geometry.deviceNotchRect }
    var screenRect: CGRect { geometry.screenRect }
    var windowHeight: CGFloat { geometry.windowHeight }

    /// Dynamic opened size based on content type
    /// Note: References selectorUpdateToken to ensure views re-compute when pickers expand/collapse
    var openedSize: CGSize {
        // Touch token to establish observation dependency
        _ = selectorUpdateToken

        switch contentType {
        case .chat:
            // Large size for chat view
            CGSize(
                width: min(screenRect.width * 0.5, 600),
                height: 580
            )
        case .menu:
            // Compact size for settings menu
            CGSize(
                width: min(screenRect.width * 0.4, 480),
                height: 420 + screenSelector.expandedPickerHeight + soundSelector.expandedPickerHeight
            )
        case .instances:
            CGSize(
                width: min(screenRect.width * 0.4, 480),
                height: 320
            )
        }
    }

    // MARK: - Animation

    var animation: Animation {
        .easeOut(duration: 0.25)
    }

    func notchOpen(reason: NotchOpenReason = .unknown) {
        openReason = reason
        status = .opened

        // Don't restore chat on notification - show instances list instead
        if reason == .notification {
            currentChatSession = nil
            return
        }

        // Restore chat session if we had one open before
        if let chatSession = currentChatSession {
            // Avoid unnecessary updates if already showing this chat
            if case let .chat(current) = contentType, current.sessionID == chatSession.sessionID {
                return
            }
            contentType = .chat(chatSession)
        }
    }

    func notchClose() {
        // Save chat session before closing if in chat mode
        if case let .chat(session) = contentType {
            currentChatSession = session
        }
        status = .closed
        contentType = .instances
    }

    func notchPop() {
        guard status == .closed else { return }
        status = .popping
    }

    func notchUnpop() {
        guard status == .popping else { return }
        status = .closed
    }

    func toggleMenu() {
        contentType = contentType == .menu ? .instances : .menu
    }

    func showChat(for session: SessionState) {
        // Avoid unnecessary updates if already showing this chat
        if case let .chat(current) = contentType, current.sessionID == session.sessionID {
            return
        }
        contentType = .chat(session)
    }

    /// Go back to instances list and clear saved chat state
    func exitChat() {
        currentChatSession = nil
        contentType = .instances
    }

    /// Perform boot animation: expand briefly then collapse
    func performBootAnimation() {
        notchOpen(reason: .boot)
        bootAnimationTask?.cancel()
        bootAnimationTask = Task {
            try? await Task.sleep(for: .seconds(1.0))
            guard !Task.isCancelled, openReason == .boot else { return }
            notchClose()
        }
    }

    // MARK: Private

    // MARK: - Dependencies

    private let screenSelector = ScreenSelector.shared
    private let soundSelector = SoundSelector.shared

    @ObservationIgnored private var cancellables = Set<AnyCancellable>()
    private let events = EventMonitors.shared

    /// Task for hover delay before opening notch
    @ObservationIgnored private var hoverTask: Task<Void, Never>?
    /// Task for boot animation auto-close
    @ObservationIgnored private var bootAnimationTask: Task<Void, Never>?
    /// Task for reposting mouse clicks to windows behind us
    @ObservationIgnored private var repostClickTask: Task<Void, Never>?

    /// The chat session we're viewing (persists across close/open)
    private var currentChatSession: SessionState?

    /// Tracks whether observation loop is active
    @ObservationIgnored private var isObservingSelectors = false

    /// Whether we're in chat mode (sticky behavior)
    private var isInChatMode: Bool {
        if case .chat = contentType { return true }
        return false
    }

    private func observeSelectors() {
        // Use withObservationTracking to observe @Observable properties across objects
        startSelectorObservation()
    }

    private func startSelectorObservation() {
        guard !isObservingSelectors else { return }
        isObservingSelectors = true
        observeSelectorChanges()
    }

    private func observeSelectorChanges() {
        withObservationTracking {
            // Access the properties we want to observe
            _ = screenSelector.isPickerExpanded
            _ = soundSelector.isPickerExpanded
        } onChange: { [weak self] in
            // Dispatch to main actor since onChange may be called from any context
            Task { @MainActor [weak self] in
                self?.selectorUpdateToken &+= 1
                // Re-register for next change
                self?.observeSelectorChanges()
            }
        }
    }

    // MARK: - Event Handling

    private func setupEventHandlers() {
        events.mouseLocation
            .throttle(for: .milliseconds(50), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] location in
                self?.handleMouseMove(location)
            }
            .store(in: &cancellables)

        events.mouseDown
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleMouseDown()
            }
            .store(in: &cancellables)
    }

    private func handleMouseMove(_ location: CGPoint) {
        let inNotch = geometry.isPointInNotch(location)
        let inOpened = status == .opened && geometry.isPointInOpenedPanel(location, size: openedSize)

        let newHovering = inNotch || inOpened

        // Only update if changed to prevent unnecessary re-renders
        guard newHovering != isHovering else { return }

        isHovering = newHovering

        // Cancel any pending hover task
        hoverTask?.cancel()
        hoverTask = nil

        // Start hover timer to auto-expand after 1 second
        if isHovering && (status == .closed || status == .popping) {
            hoverTask = Task {
                try? await Task.sleep(for: .seconds(1.0))
                guard !Task.isCancelled, isHovering else { return }
                notchOpen(reason: .hover)
            }
        }
    }

    private func handleMouseDown() {
        let location = NSEvent.mouseLocation

        switch status {
        case .opened:
            if geometry.isPointOutsidePanel(location, size: openedSize) {
                notchClose()
                // Re-post the click so it reaches the window/app behind us
                repostClickAt(location)
            } else if geometry.notchScreenRect.contains(location) {
                // Clicking notch while opened - only close if NOT in chat mode
                if !isInChatMode {
                    notchClose()
                }
            }
        case .closed,
             .popping:
            if geometry.isPointInNotch(location) {
                notchOpen(reason: .click)
            }
        }
    }

    /// Re-posts a mouse click at the given screen location so it reaches windows behind us
    private func repostClickAt(_ location: CGPoint) {
        // Cancel any pending repost task
        repostClickTask?.cancel()
        // Small delay to let the window's ignoresMouseEvents update
        repostClickTask = Task {
            try? await Task.sleep(for: .seconds(0.05))
            guard !Task.isCancelled else { return }

            // Convert to CGEvent coordinate system (screen coordinates with Y from top-left)
            guard let screen = NSScreen.main else { return }
            let screenHeight = screen.frame.height
            let cgPoint = CGPoint(x: location.x, y: screenHeight - location.y)

            // Create and post mouse down event
            if let mouseDown = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDown,
                mouseCursorPosition: cgPoint,
                mouseButton: .left
            ) {
                mouseDown.post(tap: .cghidEventTap)
            }

            // Create and post mouse up event
            if let mouseUp = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseUp,
                mouseCursorPosition: cgPoint,
                mouseButton: .left
            ) {
                mouseUp.post(tap: .cghidEventTap)
            }
        }
    }
}

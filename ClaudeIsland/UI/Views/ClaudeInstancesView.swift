//
//  ClaudeInstancesView.swift
//  ClaudeIsland
//
//  Minimal instances list matching Dynamic Island aesthetic
//

import AppKit
import SwiftUI

// MARK: - ClaudeInstancesView

struct ClaudeInstancesView: View {
    // MARK: Internal

    /// Session monitor is @Observable, so SwiftUI automatically tracks property access
    var sessionMonitor: ClaudeSessionMonitor

    /// View model is @Observable, so SwiftUI automatically tracks property access
    var viewModel: NotchViewModel

    var body: some View {
        if self.sessionMonitor.instances.isEmpty {
            self.emptyState
        } else {
            self.instancesList
        }
    }

    // MARK: Private

    @State private var showOverflowFor: String?

    // MARK: - Instances List

    /// Priority: active (approval/processing/compacting) > waitingForInput > idle
    /// Secondary sort: by last user message date (stable - doesn't change when agent responds)
    /// Note: approval requests stay in their date-based position to avoid layout shift
    private var sortedInstances: [SessionState] {
        self.sessionMonitor.instances.sorted { lhs, rhs in
            let priorityLhs = self.phasePriority(lhs.phase)
            let priorityRhs = self.phasePriority(rhs.phase)
            if priorityLhs != priorityRhs {
                return priorityLhs < priorityRhs
            }
            // Sort by last user message date (more recent first)
            // Fall back to lastActivity if no user messages yet
            let dateLhs = lhs.lastUserMessageDate ?? lhs.lastActivity
            let dateRhs = rhs.lastUserMessageDate ?? rhs.lastActivity
            return dateLhs > dateRhs
        }
    }

    private var visibleActions: [SessionActionType] {
        Array(AppSettings.sessionActionOrder.prefix(3))
    }

    private var overflowActions: [SessionActionType] {
        let allActions = AppSettings.sessionActionOrder
        if allActions.count > 3 {
            return Array(allActions.dropFirst(3))
        }
        return []
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            NewSessionRow { self.showLauncher() }
                .padding(.horizontal, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var instancesList: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button {
                    self.showLauncher()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.4))
                        .frame(width: 20, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.white.opacity(0.08)),
                        )
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
                .padding(.top, 4)
            }

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 2) {
                    ForEach(self.sortedInstances) { session in
                        InstanceRow(
                            session: session,
                            onFocus: { self.focusSession(session) },
                            onChat: { self.openChat(session) },
                            onArchive: { self.archiveSession(session) },
                            onApprove: { self.approveSession(session) },
                            onReject: { self.rejectSession(session) },
                            onOverflow: { self.showOverflowFor = session.sessionID },
                            onCancel: { self.cancelLaunch(session) },
                            onRetry: { self.retryLaunch(session) },
                            onDismiss: { self.dismissLaunch(session) },
                            visibleActions: self.visibleActions,
                        )
                        .id(session.stableID)
                        .overlay(alignment: .topTrailing) {
                            if self.showOverflowFor == session.sessionID {
                                SessionActionOverflowMenu(
                                    session: session,
                                    actions: self.overflowActions,
                                ) { self.showOverflowFor = nil }
                                    .offset(y: 36)
                                    .zIndex(100)
                            }
                        }
                    }

                    NewSessionRow { self.showLauncher() }
                }
                .padding(.vertical, 4)
            }
            .scrollBounceBehavior(.basedOnSize)
            .onTapGesture {
                if self.showOverflowFor != nil {
                    self.showOverflowFor = nil
                }
            }
        }
    }

    /// Lower number = higher priority
    /// Approval requests share priority with processing to maintain stable ordering
    private func phasePriority(_ phase: SessionPhase) -> Int {
        switch phase {
        case .waitingForApproval,
             .processing,
             .compacting: 0
        case .waitingForInput: 1
        case .launching: 0
        case .idle,
             .ended: 3
        }
    }

    private func focusSession(_ session: SessionState) {
        Task(name: "focus-terminal") {
            if let pid = session.pid {
                let success = await TerminalFocuser.shared.focusTerminal(forClaudePID: pid)
                if success { return }
            }
            _ = await TerminalFocuser.shared.focusTerminal(forWorkingDirectory: session.cwd)
        }
    }

    private func openChat(_ session: SessionState) {
        self.viewModel.showChat(for: session)
    }

    private func approveSession(_ session: SessionState) {
        self.sessionMonitor.approvePermission(sessionID: session.sessionID)
    }

    private func rejectSession(_ session: SessionState) {
        self.sessionMonitor.denyPermission(sessionID: session.sessionID, reason: nil)
    }

    private func archiveSession(_ session: SessionState) {
        self.sessionMonitor.archiveSession(sessionID: session.sessionID)
    }

    private func cancelLaunch(_ session: SessionState) {
        guard let tmuxName = session.tmuxSessionName else { return }
        Task(name: "cancel-launch") {
            await TmuxSessionCreator.shared.cancelLaunch(sessionName: tmuxName)
            await SessionStore.shared.process(.sessionEnded(sessionID: session.sessionID))
        }
    }

    private func retryLaunch(_ session: SessionState) {
        Task(name: "retry-launch") {
            if let tmuxName = session.tmuxSessionName {
                await TmuxSessionCreator.shared.cancelLaunch(sessionName: tmuxName)
            }
            await SessionStore.shared.process(.sessionEnded(sessionID: session.sessionID))
            SessionLauncherPanel.shared.show()
        }
    }

    private func dismissLaunch(_ session: SessionState) {
        Task(name: "dismiss-launch") {
            await SessionStore.shared.process(.sessionEnded(sessionID: session.sessionID))
        }
    }

    private func showLauncher() {
        SessionLauncherPanel.shared.show()
    }
}

// MARK: - InlineApprovalButtons

/// Compact inline approval buttons with staggered animation
struct InlineApprovalButtons: View {
    // MARK: Internal

    let onChat: () -> Void
    let onApprove: () -> Void
    let onReject: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            // Chat button
            IconButton(icon: "bubble.left") {
                self.onChat()
            }
            .opacity(self.showChatButton ? 1 : 0)
            .scaleEffect(self.showChatButton ? 1 : 0.8)

            Button {
                self.onReject()
            } label: {
                Text("Deny")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(self.showDenyButton ? 1 : 0)
            .scaleEffect(self.showDenyButton ? 1 : 0.8)

            Button {
                self.onApprove()
            } label: {
                Text("Allow")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.9))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(self.showAllowButton ? 1 : 0)
            .scaleEffect(self.showAllowButton ? 1 : 0.8)
        }
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.0)) {
                self.showChatButton = true
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.05)) {
                self.showDenyButton = true
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.1)) {
                self.showAllowButton = true
            }
        }
    }

    // MARK: Private

    @State private var showChatButton = false
    @State private var showDenyButton = false
    @State private var showAllowButton = false
}

// MARK: - IconButton

struct IconButton: View {
    // MARK: Internal

    let icon: String
    let action: () -> Void

    var body: some View {
        Button {
            self.action()
        } label: {
            Image(systemName: self.icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(self.isHovered ? .white.opacity(0.8) : .white.opacity(0.4))
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(self.isHovered ? Color.white.opacity(0.1) : Color.clear),
                )
        }
        .buttonStyle(.plain)
        .onHover { self.isHovered = $0 }
    }

    // MARK: Private

    @State private var isHovered = false
}

// MARK: - CompactTerminalButton

struct CompactTerminalButton: View {
    let isEnabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button {
            if self.isEnabled {
                self.onTap()
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "terminal")
                    .font(.system(size: 8, weight: .medium))
                Text("Go to Terminal")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(self.isEnabled ? .white.opacity(0.9) : .white.opacity(0.3))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(self.isEnabled ? Color.white.opacity(0.15) : Color.white.opacity(0.05))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - TerminalButton

struct TerminalButton: View {
    let isEnabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button {
            if self.isEnabled {
                self.onTap()
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "terminal")
                    .font(.system(size: 9, weight: .medium))
                Text("Terminal")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(self.isEnabled ? .black : .white.opacity(0.4))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(self.isEnabled ? Color.white.opacity(0.95) : Color.white.opacity(0.1))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Right Click Modifier

extension View {
    func onRightClick(perform action: @escaping () -> Void) -> some View {
        overlay {
            RightClickDetector(action: action)
        }
    }
}

// MARK: - RightClickDetector

struct RightClickDetector: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context _: Context) -> RightClickNSView {
        RightClickNSView(action: self.action)
    }

    func updateNSView(_ nsView: RightClickNSView, context _: Context) {
        nsView.action = self.action
    }
}

// MARK: - RightClickNSView

final class RightClickNSView: NSView {
    // MARK: Lifecycle

    init(action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: Internal

    var action: () -> Void

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, self.monitor == nil else { return }

        self.monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self, event.window == self.window else { return event }
            let locationInView = convert(event.locationInWindow, from: nil)

            if bounds.contains(locationInView) {
                self.action()
                return nil
            }
            return event
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    // MARK: Private

    private var monitor: Any?
}

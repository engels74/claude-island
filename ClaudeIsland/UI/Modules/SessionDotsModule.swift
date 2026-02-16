//
//  SessionDotsModule.swift
//  ClaudeIsland
//
//  Session state dots notch module
//

import SwiftUI

struct SessionDotsModule: NotchModule {
    nonisolated let id = "sessionDots"
    let displayName = "Session Dots"
    let defaultSide: ModuleSide = .right
    let defaultOrder = 3

    var sessions: [SessionState] = []

    func isVisible(
        isProcessing: Bool,
        hasPendingPermission: Bool,
        hasWaitingForInput: Bool,
        needsAccessibilityWarning: Bool,
    ) -> Bool {
        self.sessions.count { $0.phase != .ended } >= 1
    }

    func preferredWidth() -> CGFloat {
        let activeSessions = self.sessions.filter { $0.phase != .ended }
        return SessionStateDots.expectedWidth(for: activeSessions.count)
    }

    // swiftlint:disable function_parameter_count
    func makeBody(
        isProcessing: Bool,
        hasPendingPermission: Bool,
        hasWaitingForInput: Bool,
        clawdColor: Color,
        namespace: Namespace.ID,
        isSourceNamespace: Bool,
    ) -> AnyView {
        let activeSessions = self.sessions.filter { $0.phase != .ended }
        return AnyView(
            SessionStateDots(sessions: activeSessions),
        )
    }
    // swiftlint:enable function_parameter_count
}

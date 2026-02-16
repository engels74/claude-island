//
//  TokenRingsModule.swift
//  ClaudeIsland
//
//  Token usage rings notch module
//

import SwiftUI

struct TokenRingsModule: NotchModule {
    nonisolated let id = "tokenRings"
    let displayName = "Token Rings"
    let defaultSide: ModuleSide = .right
    let defaultOrder = 2

    func isVisible(
        isProcessing: Bool,
        hasPendingPermission: Bool,
        hasWaitingForInput: Bool,
        needsAccessibilityWarning: Bool,
    ) -> Bool {
        AppSettings.tokenTrackingMode != .disabled && AppSettings.tokenShowRingsMinimized
    }

    func preferredWidth() -> CGFloat {
        let display = AppSettings.tokenMinimizedRingDisplay
        let ringCount = (display.showSession ? 1 : 0) + (display.showWeekly ? 1 : 0)
        guard ringCount > 0 else { return 0 }
        let ringSize: CGFloat = 16
        return CGFloat(ringCount) * ringSize + CGFloat(ringCount - 1) * 4
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
        let display = AppSettings.tokenMinimizedRingDisplay
        let manager = TokenTrackingManager.shared
        return AnyView(
            TokenRingsOverlay(
                sessionPercentage: manager.sessionPercentage,
                weeklyPercentage: manager.weeklyPercentage,
                showSession: display.showSession,
                showWeekly: display.showWeekly,
                size: 16,
                strokeWidth: 2,
                showResetTime: false,
            )
            .matchedGeometryEffect(id: "token-rings", in: namespace, isSource: isSourceNamespace),
        )
    }
    // swiftlint:enable function_parameter_count
}

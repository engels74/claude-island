//
//  TimerModule.swift
//  ClaudeIsland
//
//  Timer display notch module
//

import SwiftUI

struct TimerModule: NotchModule {
    nonisolated let id = "timer"
    let displayName = "Session Reset Time"
    let defaultSide: ModuleSide = .right
    let defaultOrder = 4

    func isVisible(
        isProcessing: Bool,
        hasPendingPermission: Bool,
        hasWaitingForInput: Bool,
        needsAccessibilityWarning: Bool,
    ) -> Bool {
        AppSettings.tokenTrackingMode != .disabled
            && AppSettings.tokenShowResetTime
            && TokenTrackingManager.shared.sessionResetTime != nil
    }

    func preferredWidth() -> CGFloat {
        35
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
        guard let resetTime = TokenTrackingManager.shared.sessionResetTime else {
            return AnyView(EmptyView())
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return AnyView(
            Text(formatter.string(from: resetTime))
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.white.opacity(0.6)),
        )
    }
    // swiftlint:enable function_parameter_count
}

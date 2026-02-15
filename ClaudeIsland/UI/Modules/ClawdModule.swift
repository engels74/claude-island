//
//  ClawdModule.swift
//  ClaudeIsland
//
//  Clawd crab mascot notch module
//

import SwiftUI

struct ClawdModule: NotchModule {
    nonisolated let id = "clawd"
    let displayName = "Clawd"
    let defaultSide: ModuleSide = .left
    let defaultOrder = 0

    func isVisible(
        isProcessing: Bool,
        hasPendingPermission: Bool,
        hasWaitingForInput: Bool,
        needsAccessibilityWarning: Bool,
    ) -> Bool {
        true
    }

    func preferredWidth() -> CGFloat {
        14 * (66.0 / 52.0)
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
        AnyView(
            ClaudeCrabIcon(size: 14, color: clawdColor, animateLegs: isProcessing)
                .matchedGeometryEffect(id: "crab", in: namespace, isSource: isSourceNamespace),
        )
    }
    // swiftlint:enable function_parameter_count
}

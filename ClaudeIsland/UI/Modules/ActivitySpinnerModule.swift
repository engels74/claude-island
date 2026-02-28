//
//  ActivitySpinnerModule.swift
//  ClaudeIsland
//
//  Processing spinner notch module
//

import SwiftUI

struct ActivitySpinnerModule: NotchModule {
    nonisolated let id = "activitySpinner"
    let displayName = "Spinner"
    let defaultSide: ModuleSide = .right
    let defaultOrder = 0

    func isVisible(
        isProcessing: Bool,
        hasPendingPermission: Bool,
        hasWaitingForInput: Bool,
        needsAccessibilityWarning: Bool,
    ) -> Bool {
        isProcessing || hasPendingPermission
    }

    func preferredWidth() -> CGFloat {
        12
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
            ProcessingSpinner()
                .matchedGeometryEffect(id: "spinner", in: namespace, isSource: isSourceNamespace),
        )
    }
    // swiftlint:enable function_parameter_count
}

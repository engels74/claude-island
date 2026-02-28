//
//  ReadyCheckmarkModule.swift
//  ClaudeIsland
//
//  Ready-for-input checkmark notch module
//

import SwiftUI

struct ReadyCheckmarkModule: NotchModule {
    nonisolated let id = "readyCheckmark"
    let displayName = "Checkmark"
    let defaultSide: ModuleSide = .right
    let defaultOrder = 1

    func isVisible(
        isProcessing: Bool,
        hasPendingPermission: Bool,
        hasWaitingForInput: Bool,
        needsAccessibilityWarning: Bool,
    ) -> Bool {
        hasWaitingForInput && !isProcessing && !hasPendingPermission
    }

    func preferredWidth() -> CGFloat {
        14
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
            ReadyForInputIndicatorIcon(size: 14, color: TerminalColors.green)
                .matchedGeometryEffect(id: "spinner", in: namespace, isSource: isSourceNamespace),
        )
    }
    // swiftlint:enable function_parameter_count
}

//
//  AccessibilityWarningModule.swift
//  ClaudeIsland
//
//  Accessibility warning notch module
//

import SwiftUI

struct AccessibilityWarningModule: NotchModule {
    nonisolated let id = "accessibilityWarning"
    let displayName = "Accessibility"
    let defaultSide: ModuleSide = .left
    let defaultOrder = 2

    func isVisible(
        isProcessing: Bool,
        hasPendingPermission: Bool,
        hasWaitingForInput: Bool,
        needsAccessibilityWarning: Bool,
    ) -> Bool {
        needsAccessibilityWarning
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
            Button {
                AccessibilityPermissionManager.shared.handleAppActivation()
            } label: {
                AccessibilityWarningIcon(size: 14, color: TerminalColors.amber)
            }
            .buttonStyle(.plain),
        )
    }
    // swiftlint:enable function_parameter_count
}

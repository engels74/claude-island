//
//  PermissionIndicatorModule.swift
//  ClaudeIsland
//
//  Permission indicator notch module
//

import SwiftUI

struct PermissionIndicatorModule: NotchModule {
    nonisolated let id = "permissionIndicator"
    let displayName = "Permission"
    let defaultSide: ModuleSide = .left
    let defaultOrder = 1

    func isVisible(
        isProcessing: Bool,
        hasPendingPermission: Bool,
        hasWaitingForInput: Bool,
        needsAccessibilityWarning: Bool,
    ) -> Bool {
        hasPendingPermission
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
            PermissionIndicatorIcon(size: 14, color: clawdColor)
                .matchedGeometryEffect(id: "status-indicator", in: namespace, isSource: isSourceNamespace),
        )
    }
    // swiftlint:enable function_parameter_count
}

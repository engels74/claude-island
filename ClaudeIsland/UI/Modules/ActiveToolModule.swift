//
//  ActiveToolModule.swift
//  ClaudeIsland
//
//  Active tool name notch module
//

import SwiftUI

struct ActiveToolModule: NotchModule {
    // MARK: Internal

    nonisolated let id = "activeTool"
    let displayName = "Active Tool"
    let defaultSide: ModuleSide = .right
    let defaultOrder = 5
    let showInExpandedHeader = false

    var sessions: [SessionState] = []

    func isVisible(
        isProcessing: Bool,
        hasPendingPermission: Bool,
        hasWaitingForInput: Bool,
        needsAccessibilityWarning: Bool,
    ) -> Bool {
        self.activeToolName != nil
    }

    func preferredWidth() -> CGFloat {
        guard self.activeToolName != nil else { return 0 }
        return 50
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
        guard let toolName = activeToolName else {
            return AnyView(EmptyView())
        }
        return AnyView(
            Text(toolName)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.6))
                .lineLimit(1),
        )
    }

    // swiftlint:enable function_parameter_count

    // MARK: Private

    private var activeToolName: String? {
        let primary = self.sessions
            .filter { $0.phase != .ended }
            .max { $0.lastActivity < $1.lastActivity }
        guard let primary else { return nil }
        return primary.toolTracker.inProgress.values
            .max { $0.startTime < $1.startTime }?
            .name
    }
}

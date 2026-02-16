//
//  NotchModule.swift
//  ClaudeIsland
//
//  Protocol defining a self-contained notch module
//

import SwiftUI

// MARK: - ModuleSide

enum ModuleSide: String, Codable, CaseIterable, Sendable {
    case left
    case right
    case hidden
}

// MARK: - NotchModule

@MainActor
protocol NotchModule: Identifiable where ID == String {
    nonisolated var id: String { get }
    var displayName: String { get }
    var defaultSide: ModuleSide { get }
    var defaultOrder: Int { get }
    var showInExpandedHeader: Bool { get }

    func isVisible(
        isProcessing: Bool,
        hasPendingPermission: Bool,
        hasWaitingForInput: Bool,
        needsAccessibilityWarning: Bool,
    ) -> Bool

    func preferredWidth() -> CGFloat

    // swiftlint:disable function_parameter_count
    @ViewBuilder
    func makeBody(
        isProcessing: Bool,
        hasPendingPermission: Bool,
        hasWaitingForInput: Bool,
        clawdColor: Color,
        namespace: Namespace.ID,
        isSourceNamespace: Bool,
    ) -> AnyView
    // swiftlint:enable function_parameter_count
}

extension NotchModule {
    var showInExpandedHeader: Bool {
        true
    }
}

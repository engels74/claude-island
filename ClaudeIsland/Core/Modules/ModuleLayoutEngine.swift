//
//  ModuleLayoutEngine.swift
//  ClaudeIsland
//
//  Computes notch layout from module config and session state
//

import SwiftUI

// MARK: - ModuleLayout

struct ModuleLayout: Equatable {
    static let empty = Self(
        leftModules: [],
        rightModules: [],
        leftWidth: 0,
        rightWidth: 0,
        totalExpansionWidth: 0,
        hasAnyVisibleModule: false,
    )

    let leftModules: [AnyNotchModule]
    let rightModules: [AnyNotchModule]
    let leftWidth: CGFloat
    let rightWidth: CGFloat
    let totalExpansionWidth: CGFloat
    let hasAnyVisibleModule: Bool

    var symmetricSideWidth: CGFloat {
        max(self.leftWidth, self.rightWidth)
    }
}

// MARK: - AnyNotchModule

struct AnyNotchModule: Identifiable, Equatable {
    let id: String
    let width: CGFloat
}

// MARK: - ModuleLayoutEngine

final class ModuleLayoutEngine {
    // MARK: Lifecycle

    init(registry: ModuleRegistry) {
        self.registry = registry
        var config = AppSettings.moduleLayoutConfig
            ?? ModuleLayoutConfig.defaultConfig(from: registry.modules)
        let registeredIDs = Set(registry.modules.map(\.id))
        config.placements.removeAll { !registeredIDs.contains($0.id) }
        let knownIDs = Set(config.placements.map(\.id))
        for module in registry.modules where !knownIDs.contains(module.id) {
            config.placements.append(
                ModulePlacement(id: module.id, side: module.defaultSide, order: module.defaultOrder),
            )
        }
        self.config = config
        AppSettings.moduleLayoutConfig = config
    }

    // MARK: Internal

    static let interModuleSpacing: CGFloat = 8
    static let sideInset: CGFloat = 0
    static let outerEdgeInset: CGFloat = 6
    static let shapeEdgeMargin: CGFloat = 8

    let registry: ModuleRegistry

    var config: ModuleLayoutConfig {
        didSet {
            AppSettings.moduleLayoutConfig = self.config
        }
    }

    func computeLayout(
        notchSize: CGSize,
        isProcessing: Bool,
        hasPendingPermission: Bool,
        hasWaitingForInput: Bool,
        needsAccessibilityWarning: Bool,
    ) -> ModuleLayout {
        let leftPlacements = self.config.modulesForSide(.left)
        let rightPlacements = self.config.modulesForSide(.right)

        let leftModules = self.resolveModules(
            placements: leftPlacements,
            isProcessing: isProcessing,
            hasPendingPermission: hasPendingPermission,
            hasWaitingForInput: hasWaitingForInput,
            needsAccessibilityWarning: needsAccessibilityWarning,
        )

        let rightModules = self.resolveModules(
            placements: rightPlacements,
            isProcessing: isProcessing,
            hasPendingPermission: hasPendingPermission,
            hasWaitingForInput: hasWaitingForInput,
            needsAccessibilityWarning: needsAccessibilityWarning,
        )

        let leftWidth = self.computeSideWidth(leftModules)
        let rightWidth = self.computeSideWidth(rightModules)

        let hasAny = !leftModules.isEmpty || !rightModules.isEmpty
        let maxSide = max(leftWidth, rightWidth)
        let totalExpansion = hasAny ? maxSide * 2 : 0

        return ModuleLayout(
            leftModules: leftModules,
            rightModules: rightModules,
            leftWidth: leftWidth,
            rightWidth: rightWidth,
            totalExpansionWidth: totalExpansion,
            hasAnyVisibleModule: hasAny,
        )
    }

    func resetToDefaults() {
        self.config = ModuleLayoutConfig.defaultConfig(from: self.registry.modules)
    }

    // MARK: Private

    private func resolveModules(
        placements: [ModulePlacement],
        isProcessing: Bool,
        hasPendingPermission: Bool,
        hasWaitingForInput: Bool,
        needsAccessibilityWarning: Bool,
    ) -> [AnyNotchModule] {
        placements.compactMap { placement in
            guard let module = registry.module(for: placement.id) else { return nil }
            guard module.isVisible(
                isProcessing: isProcessing,
                hasPendingPermission: hasPendingPermission,
                hasWaitingForInput: hasWaitingForInput,
                needsAccessibilityWarning: needsAccessibilityWarning,
            )
            else { return nil }

            return AnyNotchModule(
                id: module.id,
                width: module.preferredWidth(),
            )
        }
    }

    private func computeSideWidth(_ modules: [AnyNotchModule]) -> CGFloat {
        guard !modules.isEmpty else { return 0 }
        let modulesWidth = modules.reduce(0) { $0 + $1.width }
        let spacingWidth = CGFloat(modules.count - 1) * Self.interModuleSpacing
        return modulesWidth + spacingWidth + Self.sideInset + Self.outerEdgeInset
    }
}

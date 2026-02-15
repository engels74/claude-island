//
//  ModuleLayoutConfig.swift
//  ClaudeIsland
//
//  User-configurable layout configuration for notch modules
//

import Foundation

// MARK: - ModulePlacement

struct ModulePlacement: Codable, Identifiable, Sendable, Equatable {
    var id: String
    var side: ModuleSide
    var order: Int
}

// MARK: - ModuleLayoutConfig

struct ModuleLayoutConfig: Codable, Sendable, Equatable {
    var placements: [ModulePlacement]

    static func defaultConfig(from modules: [any NotchModule]) -> Self {
        Self(
            placements: modules.map { module in
                ModulePlacement(
                    id: module.id,
                    side: module.defaultSide,
                    order: module.defaultOrder,
                )
            },
        )
    }

    func placement(for moduleID: String) -> ModulePlacement? {
        self.placements.first { $0.id == moduleID }
    }

    func modulesForSide(_ side: ModuleSide) -> [ModulePlacement] {
        self.placements
            .filter { $0.side == side }
            .sorted { $0.order < $1.order }
    }
}

//
//  ModuleRegistry.swift
//  ClaudeIsland
//
//  Central registry of all available notch modules
//

import SwiftUI

@Observable
final class ModuleRegistry {
    // MARK: Lifecycle

    init() {
        self.registerDefaults()
    }

    // MARK: Internal

    static let shared = ModuleRegistry()

    private(set) var modules: [any NotchModule] = []

    var allModuleIDs: [String] {
        self.modules.map(\.id)
    }

    func module(for id: String) -> (any NotchModule)? {
        self.modules.first { $0.id == id }
    }

    func updateSessions(_ sessions: [SessionState]) {
        for index in self.modules.indices {
            if var dots = modules[index] as? SessionDotsModule {
                dots.sessions = sessions
                self.modules[index] = dots
            }
        }
    }

    // MARK: Private

    private func registerDefaults() {
        self.modules = [
            ClawdModule(),
            PermissionIndicatorModule(),
            AccessibilityWarningModule(),
            ActivitySpinnerModule(),
            ReadyCheckmarkModule(),
            TokenRingsModule(),
            SessionDotsModule(),
            TimerModule(),
        ]
    }
}

//
//  ToolStatusColors.swift
//  ClaudeIsland
//
//  Shared status color palette for tool call views
//

import SwiftUI

enum ToolStatusColors {
    static let running = Color.white
    static let waitingForApproval = Color(red: 0.824, green: 0.6, blue: 0.133)
    static let success = Color(red: 0.247, green: 0.725, blue: 0.314)
    static let error = Color(red: 0.973, green: 0.318, blue: 0.286)

    static func color(for status: ToolStatus) -> Color {
        switch status {
        case .running: self.running
        case .waitingForApproval: self.waitingForApproval
        case .success: self.success
        case .error, .interrupted: self.error
        }
    }
}

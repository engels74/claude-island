//
//  SessionPhase.swift
//  ClaudeIsland
//
//  Explicit state machine for Claude session lifecycle.
//  All state transitions are validated before being applied.
//

import Foundation

// MARK: - PermissionContext

/// Permission context for tools waiting for approval
struct PermissionContext: Sendable {
    let toolUseID: String
    let toolName: String
    let toolInput: [String: AnyCodable]?
    let receivedAt: Date

    /// Format tool input for display
    var formattedInput: String? {
        guard let input = toolInput else { return nil }
        var parts: [String] = []
        for (key, value) in input {
            let valueStr: String = switch value.value {
            case let str as String:
                str.count > 100 ? String(str.prefix(100)) + "..." : str
            case let num as Int:
                String(num)
            case let num as Double:
                String(num)
            case let bool as Bool:
                bool ? "true" : "false"
            default:
                "..."
            }
            parts.append("\(key): \(valueStr)")
        }
        return parts.joined(separator: "\n")
    }
}

// MARK: Equatable

extension PermissionContext: Equatable {
    nonisolated static func == (lhs: PermissionContext, rhs: PermissionContext) -> Bool {
        // Compare by identity fields only (AnyCodable doesn't conform to Equatable)
        lhs.toolUseID == rhs.toolUseID &&
            lhs.toolName == rhs.toolName &&
            lhs.receivedAt == rhs.receivedAt
    }
}

// MARK: - SessionPhase

/// Explicit session phases - the state machine
enum SessionPhase: Sendable {
    /// Session is idle, waiting for user input or new activity
    case idle

    /// Claude is actively processing (running tools, generating response)
    case processing

    /// Claude has finished and is waiting for user input
    case waitingForInput

    /// A tool is waiting for user permission approval
    case waitingForApproval(PermissionContext)

    /// Context is being compacted (auto or manual)
    case compacting

    /// Session has ended
    case ended

    // MARK: Internal

    /// Whether this phase indicates the session needs user attention
    var needsAttention: Bool {
        switch self {
        case .waitingForApproval,
             .waitingForInput:
            true
        default:
            false
        }
    }

    /// Whether this phase indicates active processing
    var isActive: Bool {
        switch self {
        case .processing,
             .compacting:
            true
        default:
            false
        }
    }

    /// Whether this is a waitingForApproval phase
    var isWaitingForApproval: Bool {
        if case .waitingForApproval = self {
            return true
        }
        return false
    }

    /// Extract tool name if waiting for approval
    var approvalToolName: String? {
        if case let .waitingForApproval(ctx) = self {
            return ctx.toolName
        }
        return nil
    }

    // MARK: - State Machine Transitions

    /// Check if a transition to the target phase is valid
    nonisolated func canTransition(to next: SessionPhase) -> Bool {
        switch (self, next) {
        // Terminal state - no transitions out
        case (.ended, _):
            false
        // Any state can transition to ended
        case (_, .ended):
            true
        // Idle transitions
        case (.idle, .processing):
            true
        case (.idle, .waitingForApproval):
            true // Direct permission request on idle session
        case (.idle, .compacting):
            true
        // Processing transitions
        case (.processing, .waitingForInput):
            true
        case (.processing, .waitingForApproval):
            true
        case (.processing, .compacting):
            true
        case (.processing, .idle):
            true // Interrupt or quick completion
        // WaitingForInput transitions
        case (.waitingForInput, .processing):
            true
        case (.waitingForInput, .idle):
            true // Can become idle
        case (.waitingForInput, .compacting):
            true
        // WaitingForApproval transitions
        case (.waitingForApproval, .processing):
            true // Approved - tool will run
        case (.waitingForApproval, .idle):
            true // Denied or cancelled
        case (.waitingForApproval, .waitingForInput):
            true // Denied and Claude stopped
        case (.waitingForApproval, .waitingForApproval):
            true // Another tool needs approval (multiple pending permissions)
        // Compacting transitions
        case (.compacting, .processing):
            true
        case (.compacting, .idle):
            true
        case (.compacting, .waitingForInput):
            true
        // Allow staying in same state (no-op transitions)
        default:
            self == next
        }
    }

    /// Attempt to transition to a new phase, returns the new phase if valid
    nonisolated func transition(to next: SessionPhase) -> SessionPhase? {
        canTransition(to: next) ? next : nil
    }
}

// MARK: Equatable

extension SessionPhase: Equatable {
    nonisolated static func == (lhs: SessionPhase, rhs: SessionPhase) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): true
        case (.processing, .processing): true
        case (.waitingForInput, .waitingForInput): true
        case let (.waitingForApproval(ctx1), .waitingForApproval(ctx2)):
            ctx1 == ctx2
        case (.compacting, .compacting): true
        case (.ended, .ended): true
        default: false
        }
    }
}

// MARK: CustomStringConvertible

extension SessionPhase: CustomStringConvertible {
    nonisolated var description: String {
        switch self {
        case .idle:
            "idle"
        case .processing:
            "processing"
        case .waitingForInput:
            "waitingForInput"
        case let .waitingForApproval(ctx):
            "waitingForApproval(\(ctx.toolName))"
        case .compacting:
            "compacting"
        case .ended:
            "ended"
        }
    }
}

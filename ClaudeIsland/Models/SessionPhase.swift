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
/// Note: Uses serialized JSON string for toolInput to ensure true Sendable safety
/// (AnyCodable contains `Any` which can hold mutable reference types)
struct PermissionContext: Sendable {
    // MARK: Lifecycle

    /// Initialize with raw tool input dictionary (serializes to JSON)
    init(toolUseID: String, toolName: String, toolInput: [String: AnyCodable]?, receivedAt: Date) {
        self.toolUseID = toolUseID
        self.toolName = toolName
        self.receivedAt = receivedAt

        // Serialize tool input to JSON string for Sendable safety
        if let input = toolInput,
           let data = try? JSONEncoder().encode(input),
           let jsonString = String(data: data, encoding: .utf8) {
            self.toolInputJSON = jsonString
        } else {
            self.toolInputJSON = nil
        }
    }

    // MARK: Internal

    let toolUseID: String
    let toolName: String
    /// Tool input serialized as JSON string for Sendable safety
    let toolInputJSON: String?
    let receivedAt: Date

    /// Format tool input for display with smart prioritization
    /// - Bash: Shows `command` parameter directly
    /// - Read/Write/Edit: Shows filename only (lastPathComponent)
    /// - Other tools: First non-empty string value as fallback
    var formattedInput: String? {
        guard let input = toolInput else { return nil }

        // Priority keys for specific tools
        let priorityKeys: [String: String] = [
            "Bash": "command",
            "Read": "file_path",
            "Write": "file_path",
            "Edit": "file_path",
        ]

        // Check if tool has a priority key
        if let key = priorityKeys[toolName],
           let value = input[key] as? String,
           !value.isEmpty {
            // For file operations, show only filename
            if ["Read", "Write", "Edit"].contains(self.toolName) {
                return (value as NSString).lastPathComponent
            }
            return value.count > 100 ? String(value.prefix(100)) + "..." : value
        }

        // Fallback: first non-empty string value (skip "description" key)
        for (key, value) in input {
            if key == "description" { continue }
            if let str = value as? String, !str.isEmpty {
                return str.count > 100 ? String(str.prefix(100)) + "..." : str
            }
        }

        return nil
    }

    // MARK: Private

    /// Decode tool input from JSON when needed
    private var toolInput: [String: Any]? {
        guard let json = toolInputJSON,
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return dict
    }
}

// MARK: Equatable

extension PermissionContext: Equatable {
    nonisolated static func == (lhs: PermissionContext, rhs: PermissionContext) -> Bool {
        // Compare by identity fields and serialized input
        lhs.toolUseID == rhs.toolUseID &&
            lhs.toolName == rhs.toolName &&
            lhs.toolInputJSON == rhs.toolInputJSON &&
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
    nonisolated func canTransition(to next: Self) -> Bool {
        // Terminal state - no transitions out
        if case .ended = self { return false }
        // Any state can transition to ended
        if case .ended = next { return true }
        // Allow staying in same state (no-op transitions)
        if self == next { return true }

        return Self.allowedTransitions(from: self).contains { $0.matches(next) }
    }

    /// Attempt to transition to a new phase, returns the new phase if valid
    nonisolated func transition(to next: Self) -> Self? {
        self.canTransition(to: next) ? next : nil
    }

    // MARK: Private

    /// Simplified phase key for transition lookup (strips associated values)
    private enum PhaseKey: Hashable {
        case idle
        case processing
        case waitingForInput
        case waitingForApproval
        case compacting
        case ended

        // MARK: Internal

        func matches(_ phase: SessionPhase) -> Bool {
            switch (self, phase) {
            case (.idle, .idle),
                 (.processing, .processing),
                 (.waitingForInput, .waitingForInput),
                 (.waitingForApproval, .waitingForApproval),
                 (.compacting, .compacting),
                 (.ended, .ended):
                true
            default:
                false
            }
        }
    }

    /// Valid transitions from each phase
    private static func allowedTransitions(from phase: Self) -> [PhaseKey] {
        switch phase {
        case .idle:
            [.processing, .waitingForApproval, .compacting]
        case .processing:
            [.waitingForInput, .waitingForApproval, .compacting, .idle]
        case .waitingForInput:
            [.processing, .idle, .compacting]
        case .waitingForApproval:
            [.processing, .idle, .waitingForInput, .waitingForApproval]
        case .compacting:
            [.processing, .idle, .waitingForInput]
        case .ended:
            []
        }
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

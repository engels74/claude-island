//
//  ChatHistoryManager.swift
//  ClaudeIsland
//

import Combine
import Foundation

// MARK: - ChatHistoryManager

@MainActor
class ChatHistoryManager: ObservableObject {
    // MARK: Lifecycle

    private init() {
        SessionStore.shared.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.updateFromSessions(sessions)
            }
            .store(in: &cancellables)
    }

    // MARK: Internal

    static let shared = ChatHistoryManager()

    @Published private(set) var histories: [String: [ChatHistoryItem]] = [:]
    @Published private(set) var agentDescriptions: [String: [String: String]] = [:]

    // MARK: - Public API

    func history(for sessionID: String) -> [ChatHistoryItem] {
        histories[sessionID] ?? []
    }

    func isLoaded(sessionID: String) -> Bool {
        loadedSessions.contains(sessionID)
    }

    func loadFromFile(sessionID: String, cwd: String) async {
        guard !loadedSessions.contains(sessionID) else { return }
        loadedSessions.insert(sessionID)
        await SessionStore.shared.process(.loadHistory(sessionID: sessionID, cwd: cwd))
    }

    func syncFromFile(sessionID: String, cwd: String) async {
        let messages = await ConversationParser.shared.parseFullConversation(
            sessionID: sessionID,
            cwd: cwd
        )
        let completedTools = await ConversationParser.shared.completedToolIDs(for: sessionID)
        let toolResults = await ConversationParser.shared.toolResults(for: sessionID)
        let structuredResults = await ConversationParser.shared.structuredResults(for: sessionID)

        let payload = FileUpdatePayload(
            sessionID: sessionID,
            cwd: cwd,
            messages: messages,
            isIncremental: false, // Full sync
            completedToolIDs: completedTools,
            toolResults: toolResults,
            structuredResults: structuredResults
        )

        await SessionStore.shared.process(.fileUpdated(payload))
    }

    func clearHistory(for sessionID: String) {
        loadedSessions.remove(sessionID)
        histories.removeValue(forKey: sessionID)
        Task {
            await SessionStore.shared.process(.sessionEnded(sessionID: sessionID))
        }
    }

    // MARK: Private

    private var loadedSessions: Set<String> = []
    private var cancellables = Set<AnyCancellable>()

    // MARK: - State Updates

    private func updateFromSessions(_ sessions: [SessionState]) {
        var newHistories: [String: [ChatHistoryItem]] = [:]
        var newAgentDescriptions: [String: [String: String]] = [:]
        for session in sessions {
            let filteredItems = filterOutSubagentTools(session.chatItems)
            newHistories[session.sessionID] = filteredItems
            newAgentDescriptions[session.sessionID] = session.subagentState.agentDescriptions
            loadedSessions.insert(session.sessionID)
        }
        histories = newHistories
        agentDescriptions = newAgentDescriptions
    }

    private func filterOutSubagentTools(_ items: [ChatHistoryItem]) -> [ChatHistoryItem] {
        var subagentToolIDs = Set<String>()
        for item in items {
            if case let .toolCall(tool) = item.type, tool.name == "Task" {
                for subagentTool in tool.subagentTools {
                    subagentToolIDs.insert(subagentTool.id)
                }
            }
        }

        return items.filter { !subagentToolIDs.contains($0.id) }
    }
}

// MARK: - ChatHistoryItem

struct ChatHistoryItem: Identifiable, Equatable, Sendable {
    let id: String
    let type: ChatHistoryItemType
    let timestamp: Date

    static func == (lhs: ChatHistoryItem, rhs: ChatHistoryItem) -> Bool {
        lhs.id == rhs.id && lhs.type == rhs.type
    }
}

// MARK: - ChatHistoryItemType

enum ChatHistoryItemType: Equatable, Sendable {
    case user(String)
    case assistant(String)
    case toolCall(ToolCallItem)
    case thinking(String)
    case interrupted
}

// MARK: - ToolCallItem

struct ToolCallItem: Equatable, Sendable {
    let name: String
    let input: [String: String]
    var status: ToolStatus
    var result: String?
    var structuredResult: ToolResultData?

    /// For Task tools: nested subagent tool calls
    var subagentTools: [SubagentToolCall]

    /// Preview text for the tool (input-based)
    var inputPreview: String {
        if let filePath = input["file_path"] ?? input["path"] {
            return URL(fileURLWithPath: filePath).lastPathComponent
        }
        if let command = input["command"] {
            let firstLine = command.components(separatedBy: "\n").first ?? command
            return String(firstLine.prefix(60))
        }
        if let pattern = input["pattern"] {
            return pattern
        }
        if let query = input["query"] {
            return query
        }
        if let url = input["url"] {
            return url
        }
        if let agentID = input["agentId"] {
            let blocking = input["block"] == "true"
            return blocking ? "Waiting..." : "Checking \(agentID.prefix(8))..."
        }
        return input.values.first.map { String($0.prefix(60)) } ?? ""
    }

    /// Status display text for the tool
    var statusDisplay: ToolStatusDisplay {
        if status == .running {
            return ToolStatusDisplay.running(for: name, input: input)
        }
        if status == .waitingForApproval {
            return ToolStatusDisplay(text: "Waiting for approval...", isRunning: true)
        }
        if status == .interrupted {
            return ToolStatusDisplay(text: "Interrupted", isRunning: false)
        }
        return ToolStatusDisplay.completed(for: name, result: structuredResult)
    }

    /// Custom Equatable implementation to handle structuredResult
    static func == (lhs: ToolCallItem, rhs: ToolCallItem) -> Bool {
        lhs.name == rhs.name &&
            lhs.input == rhs.input &&
            lhs.status == rhs.status &&
            lhs.result == rhs.result &&
            lhs.structuredResult == rhs.structuredResult &&
            lhs.subagentTools == rhs.subagentTools
    }
}

// MARK: - ToolStatus

enum ToolStatus: Sendable, CustomStringConvertible {
    case running
    case waitingForApproval
    case success
    case error
    case interrupted

    // MARK: Internal

    nonisolated var description: String {
        switch self {
        case .running: "running"
        case .waitingForApproval: "waitingForApproval"
        case .success: "success"
        case .error: "error"
        case .interrupted: "interrupted"
        }
    }
}

// MARK: Equatable

/// Explicit nonisolated Equatable conformance to avoid actor isolation issues
extension ToolStatus: Equatable {
    nonisolated static func == (lhs: ToolStatus, rhs: ToolStatus) -> Bool {
        switch (lhs, rhs) {
        case (.running, .running): true
        case (.waitingForApproval, .waitingForApproval): true
        case (.success, .success): true
        case (.error, .error): true
        case (.interrupted, .interrupted): true
        default: false
        }
    }
}

// MARK: - SubagentToolCall

/// Represents a tool call made by a subagent (Task tool)
struct SubagentToolCall: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let input: [String: String]
    var status: ToolStatus
    let timestamp: Date

    /// Short description for display
    var displayText: String {
        switch name {
        case "Read":
            if let path = input["file_path"] {
                return URL(fileURLWithPath: path).lastPathComponent
            }
            return "Reading..."
        case "Grep":
            if let pattern = input["pattern"] {
                return "grep: \(pattern)"
            }
            return "Searching..."
        case "Glob":
            if let pattern = input["pattern"] {
                return "glob: \(pattern)"
            }
            return "Finding files..."
        case "Bash":
            if let desc = input["description"] {
                return desc
            }
            if let cmd = input["command"] {
                let firstLine = cmd.components(separatedBy: "\n").first ?? cmd
                return String(firstLine.prefix(40))
            }
            return "Running command..."
        case "Edit":
            if let path = input["file_path"] {
                return "Edit: \(URL(fileURLWithPath: path).lastPathComponent)"
            }
            return "Editing..."
        case "Write":
            if let path = input["file_path"] {
                return "Write: \(URL(fileURLWithPath: path).lastPathComponent)"
            }
            return "Writing..."
        case "WebFetch":
            if let url = input["url"] {
                return "Fetching: \(url.prefix(30))..."
            }
            return "Fetching..."
        case "WebSearch":
            if let query = input["query"] {
                return "Search: \(query.prefix(30))"
            }
            return "Searching web..."
        default:
            return name
        }
    }
}

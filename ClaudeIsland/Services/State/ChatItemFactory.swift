//
//  ChatItemFactory.swift
//  ClaudeIsland
//
//  Factory for creating ChatHistoryItem instances from message blocks.
//  Extracted from SessionStore for type body length compliance.
//

import Foundation

// MARK: - ChatItemFactory

enum ChatItemFactory {
    // MARK: Internal

    /// Create a chat history item from a message block
    /// Returns nil if the item already exists or should be skipped
    static func createItem(
        from block: MessageBlock,
        message: ChatMessage,
        blockIndex: Int,
        existingIDs: Set<String>,
        completedTools: Set<String>,
        toolResults: [String: ConversationParser.ToolResult],
        structuredResults: [String: ToolResultData],
        toolTracker: inout ToolTracker
    ) -> ChatHistoryItem? {
        switch block {
        case let .text(text):
            createTextItem(
                text: text,
                message: message,
                blockIndex: blockIndex,
                existingIDs: existingIDs
            )

        case let .toolUse(tool):
            createToolUseItem(
                tool: tool,
                message: message,
                completedTools: completedTools,
                toolResults: toolResults,
                structuredResults: structuredResults,
                toolTracker: &toolTracker
            )

        case let .thinking(text):
            createThinkingItem(
                text: text,
                message: message,
                blockIndex: blockIndex,
                existingIDs: existingIDs
            )

        case .interrupted:
            createInterruptedItem(
                message: message,
                blockIndex: blockIndex,
                existingIDs: existingIDs
            )
        }
    }

    // MARK: Private

    // MARK: - Private Helpers

    private static func createTextItem(
        text: String,
        message: ChatMessage,
        blockIndex: Int,
        existingIDs: Set<String>
    ) -> ChatHistoryItem? {
        let itemID = "\(message.id)-text-\(blockIndex)"
        guard !existingIDs.contains(itemID) else { return nil }

        if message.role == .user {
            return ChatHistoryItem(id: itemID, type: .user(text), timestamp: message.timestamp)
        } else {
            return ChatHistoryItem(id: itemID, type: .assistant(text), timestamp: message.timestamp)
        }
    }

    private static func createToolUseItem(
        tool: ToolUse,
        message: ChatMessage,
        completedTools: Set<String>,
        toolResults: [String: ConversationParser.ToolResult],
        structuredResults: [String: ToolResultData],
        toolTracker: inout ToolTracker
    ) -> ChatHistoryItem? {
        guard toolTracker.markSeen(tool.id) else { return nil }

        let isCompleted = completedTools.contains(tool.id)
        let status: ToolStatus = isCompleted ? .success : .running

        // Extract result text for completed tools
        var resultText: String?
        if isCompleted, let parserResult = toolResults[tool.id] {
            if let stdout = parserResult.stdout, !stdout.isEmpty {
                resultText = stdout
            } else if let stderr = parserResult.stderr, !stderr.isEmpty {
                resultText = stderr
            } else if let content = parserResult.content, !content.isEmpty {
                resultText = content
            }
        }

        return ChatHistoryItem(
            id: tool.id,
            type: .toolCall(ToolCallItem(
                name: tool.name,
                input: tool.input,
                status: status,
                result: resultText,
                structuredResult: structuredResults[tool.id],
                subagentTools: []
            )),
            timestamp: message.timestamp
        )
    }

    private static func createThinkingItem(
        text: String,
        message: ChatMessage,
        blockIndex: Int,
        existingIDs: Set<String>
    ) -> ChatHistoryItem? {
        let itemID = "\(message.id)-thinking-\(blockIndex)"
        guard !existingIDs.contains(itemID) else { return nil }
        return ChatHistoryItem(id: itemID, type: .thinking(text), timestamp: message.timestamp)
    }

    private static func createInterruptedItem(
        message: ChatMessage,
        blockIndex: Int,
        existingIDs: Set<String>
    ) -> ChatHistoryItem? {
        let itemID = "\(message.id)-interrupted-\(blockIndex)"
        guard !existingIDs.contains(itemID) else { return nil }
        return ChatHistoryItem(id: itemID, type: .interrupted, timestamp: message.timestamp)
    }
}

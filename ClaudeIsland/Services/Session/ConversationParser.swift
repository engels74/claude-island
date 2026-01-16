//
//  ConversationParser.swift
//  ClaudeIsland
//
//  Parses Claude JSONL conversation files to extract summary and last message
//  Optimized for incremental parsing - only reads new lines since last sync
//

import Foundation
import os.log

// MARK: - ConversationInfo

struct ConversationInfo: Equatable, Sendable {
    let summary: String?
    let lastMessage: String?
    let lastMessageRole: String? // "user", "assistant", or "tool"
    let lastToolName: String? // Tool name if lastMessageRole is "tool"
    let firstUserMessage: String? // Fallback title when no summary
    let lastUserMessageDate: Date? // Timestamp of last user message (for stable sorting)
}

// MARK: - ConversationParser

// swiftlint:disable type_body_length function_body_length cyclomatic_complexity
actor ConversationParser {
    // MARK: Internal

    /// Parsed tool result data
    struct ToolResult: Sendable {
        // MARK: Lifecycle

        init(content: String?, stdout: String?, stderr: String?, isError: Bool) {
            self.content = content
            self.stdout = stdout
            self.stderr = stderr
            self.isError = isError
            // Detect if this was an interrupt or rejection (various formats)
            self.isInterrupted = isError && (
                content?.contains("Interrupted by user") == true ||
                    content?.contains("interrupted by user") == true ||
                    content?.contains("user doesn't want to proceed") == true
            )
        }

        // MARK: Internal

        let content: String?
        let stdout: String?
        let stderr: String?
        let isError: Bool
        let isInterrupted: Bool
    }

    /// Result of incremental parsing
    struct IncrementalParseResult {
        let newMessages: [ChatMessage]
        let allMessages: [ChatMessage]
        let completedToolIDs: Set<String>
        let toolResults: [String: ToolResult]
        let structuredResults: [String: ToolResultData]
        let clearDetected: Bool
    }

    /// Maximum file size (10 MB) before switching to incremental parsing
    /// Files larger than this will use streaming to avoid memory pressure
    static let maxFullLoadFileSize = 10_000_000

    static let shared = ConversationParser()

    /// Logger for conversation parser (nonisolated static for cross-context access)
    nonisolated static let logger = Logger(subsystem: "com.engels74.ClaudeIsland", category: "Parser")

    /// Parse a JSONL file to extract conversation info
    /// Uses caching based on file modification time
    ///
    /// Note: This method loads the entire file into memory for files under 10 MB.
    /// For larger files or incremental updates during active sessions, use `parseIncremental`
    /// instead which uses FileHandle for streaming.
    /// Full file loading is acceptable for smaller files because:
    /// 1. This is called infrequently (only when cache is stale)
    /// 2. The algorithm requires both forward and backward iteration
    /// 3. For very long conversations, the summary is typically updated, invalidating old data
    func parse(sessionID: String, cwd: String) -> ConversationInfo {
        let projectDir = cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        let sessionFile = NSHomeDirectory() + "/.claude/projects/" + projectDir + "/" + sessionID + ".jsonl"

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sessionFile),
              let attrs = try? fileManager.attributesOfItem(atPath: sessionFile),
              let modDate = attrs[.modificationDate] as? Date
        else {
            return ConversationInfo(
                summary: nil,
                lastMessage: nil,
                lastMessageRole: nil,
                lastToolName: nil,
                firstUserMessage: nil,
                lastUserMessageDate: nil
            )
        }

        if let cached = cache[sessionFile], cached.modificationDate == modDate {
            return cached.info
        }

        // Check file size to avoid memory pressure for very large conversation files
        if let fileSize = attrs[.size] as? Int, fileSize > Self.maxFullLoadFileSize {
            Self.logger.info("File size \(fileSize) exceeds max (\(Self.maxFullLoadFileSize)), using tail-based parsing")
            // For large files, read only the last portion to get recent info
            let info = parseLargeFile(path: sessionFile)
            cache[sessionFile] = CachedInfo(modificationDate: modDate, info: info)
            return info
        }

        guard let data = fileManager.contents(atPath: sessionFile),
              let content = String(data: data, encoding: .utf8)
        else {
            return ConversationInfo(
                summary: nil,
                lastMessage: nil,
                lastMessageRole: nil,
                lastToolName: nil,
                firstUserMessage: nil,
                lastUserMessageDate: nil
            )
        }

        let info = parseContent(content)
        cache[sessionFile] = CachedInfo(modificationDate: modDate, info: info)

        return info
    }

    // MARK: - Full Conversation Parsing

    /// Parse full conversation history for chat view (returns ALL messages - use sparingly)
    func parseFullConversation(sessionID: String, cwd: String) -> [ChatMessage] {
        let sessionFile = Self.sessionFilePath(sessionID: sessionID, cwd: cwd)

        guard FileManager.default.fileExists(atPath: sessionFile) else {
            return []
        }

        var state = incrementalState[sessionID] ?? IncrementalParseState()
        _ = parseNewLines(filePath: sessionFile, state: &state)
        incrementalState[sessionID] = state

        return state.messages
    }

    /// Parse only NEW messages since last call (efficient incremental updates)
    func parseIncremental(sessionID: String, cwd: String) -> IncrementalParseResult {
        let sessionFile = Self.sessionFilePath(sessionID: sessionID, cwd: cwd)

        guard FileManager.default.fileExists(atPath: sessionFile) else {
            return IncrementalParseResult(
                newMessages: [],
                allMessages: [],
                completedToolIDs: [],
                toolResults: [:],
                structuredResults: [:],
                clearDetected: false
            )
        }

        var state = incrementalState[sessionID] ?? IncrementalParseState()
        let newMessages = parseNewLines(filePath: sessionFile, state: &state)
        let clearDetected = state.clearPending
        if clearDetected {
            state.clearPending = false
        }
        incrementalState[sessionID] = state

        return IncrementalParseResult(
            newMessages: newMessages,
            allMessages: state.messages,
            completedToolIDs: state.completedToolIDs,
            toolResults: state.toolResults,
            structuredResults: state.structuredResults,
            clearDetected: clearDetected
        )
    }

    /// Get set of completed tool IDs for a session
    func completedToolIDs(for sessionID: String) -> Set<String> {
        incrementalState[sessionID]?.completedToolIDs ?? []
    }

    /// Get tool results for a session
    func toolResults(for sessionID: String) -> [String: ToolResult] {
        incrementalState[sessionID]?.toolResults ?? [:]
    }

    /// Get structured tool results for a session
    func structuredResults(for sessionID: String) -> [String: ToolResultData] {
        incrementalState[sessionID]?.structuredResults ?? [:]
    }

    /// Reset incremental state for a session (call when reloading)
    func resetState(for sessionID: String) {
        incrementalState.removeValue(forKey: sessionID)
    }

    /// Check if a /clear command was detected during the last parse
    /// Returns true once and consumes the pending flag
    func checkAndConsumeClearDetected(for sessionID: String) -> Bool {
        guard var state = incrementalState[sessionID], state.clearPending else {
            return false
        }
        state.clearPending = false
        incrementalState[sessionID] = state
        return true
    }

    // MARK: Private

    private struct CachedInfo {
        let modificationDate: Date
        let info: ConversationInfo
    }

    /// State for incremental JSONL parsing
    private struct IncrementalParseState {
        var lastFileOffset: UInt64 = 0
        var messages: [ChatMessage] = []
        var seenToolIDs: Set<String> = []
        var toolIDToName: [String: String] = [:] // Map tool_use_id to tool name
        var completedToolIDs: Set<String> = [] // Tools that have received results
        var toolResults: [String: ToolResult] = [:] // Tool results keyed by tool_use_id
        var structuredResults: [String: ToolResultData] = [:] // Structured results keyed by tool_use_id
        var lastClearOffset: UInt64 = 0 // Offset of last /clear command (0 = none or at start)
        var clearPending = false // True if a /clear was just detected
    }

    /// Tool input key mapping for display formatting
    private static let toolInputKeys: [String: String] = [
        "Read": "file_path",
        "Write": "file_path",
        "Edit": "file_path",
        "Bash": "command",
        "Grep": "pattern",
        "Glob": "pattern",
        "Task": "description",
        "WebFetch": "url",
        "WebSearch": "query",
    ]

    /// Cache of parsed conversation info, keyed by session file path
    private var cache: [String: CachedInfo] = [:]

    private var incrementalState: [String: IncrementalParseState] = [:]

    /// Format tool input for display in instance list
    private static func formatToolInput(_ input: [String: Any]?, toolName: String) -> String {
        guard let input else { return "" }

        if let key = toolInputKeys[toolName], let value = input[key] as? String {
            return ["Read", "Write", "Edit"].contains(toolName) ?
                (value as NSString).lastPathComponent : value
        }

        return input.values.compactMap { $0 as? String }.first { !$0.isEmpty } ?? ""
    }

    /// Truncate message for display
    private static func truncateMessage(_ message: String?, maxLength: Int = 80) -> String? {
        guard let msg = message else { return nil }
        let cleaned = msg.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        if cleaned.count > maxLength {
            return String(cleaned.prefix(maxLength - 3)) + "..."
        }
        return cleaned
    }

    /// Build session file path
    private static func sessionFilePath(sessionID: String, cwd: String) -> String {
        let projectDir = cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        return NSHomeDirectory() + "/.claude/projects/" + projectDir + "/" + sessionID + ".jsonl"
    }

    /// Parse a large file by reading only the last portion
    /// Used when file exceeds maxFullLoadFileSize to avoid memory pressure
    private func parseLargeFile(path: String) -> ConversationInfo {
        guard let fileHandle = FileHandle(forReadingAtPath: path) else {
            return ConversationInfo(
                summary: nil,
                lastMessage: nil,
                lastMessageRole: nil,
                lastToolName: nil,
                firstUserMessage: nil,
                lastUserMessageDate: nil
            )
        }
        defer { try? fileHandle.close() }

        do {
            let fileSize = try fileHandle.seekToEnd()
            // Read the last 2 MB to find recent messages and summary
            let readSize: UInt64 = min(2_000_000, fileSize)
            let startOffset = fileSize - readSize

            try fileHandle.seek(toOffset: startOffset)
            guard let data = try fileHandle.readToEnd(),
                  let content = String(data: data, encoding: .utf8)
            else {
                return ConversationInfo(
                    summary: nil,
                    lastMessage: nil,
                    lastMessageRole: nil,
                    lastToolName: nil,
                    firstUserMessage: nil,
                    lastUserMessageDate: nil
                )
            }

            // Skip partial first line if we didn't start at beginning
            var trimmedContent = content
            if startOffset > 0, let firstNewline = content.firstIndex(of: "\n") {
                trimmedContent = String(content[content.index(after: firstNewline)...])
            }

            return parseContent(trimmedContent)
        } catch {
            return ConversationInfo(
                summary: nil,
                lastMessage: nil,
                lastMessageRole: nil,
                lastToolName: nil,
                firstUserMessage: nil,
                lastUserMessageDate: nil
            )
        }
    }

    /// Parse JSONL content
    private func parseContent(_ content: String) -> ConversationInfo {
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }

        var summary: String?
        var lastMessage: String?
        var lastMessageRole: String?
        var lastToolName: String?
        var firstUserMessage: String?
        var lastUserMessageDate: Date?

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else {
                continue
            }

            let type = json["type"] as? String
            let isMeta = json["isMeta"] as? Bool ?? false

            if type == "user" && !isMeta {
                if let message = json["message"] as? [String: Any],
                   let msgContent = message["content"] as? String {
                    if !msgContent.hasPrefix("<command-name>") && !msgContent.hasPrefix("<local-command") && !msgContent.hasPrefix("Caveat:") {
                        firstUserMessage = Self.truncateMessage(msgContent, maxLength: 50)
                        break
                    }
                }
            }
        }

        var foundLastUserMessage = false
        for line in lines.reversed() {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else {
                continue
            }

            let type = json["type"] as? String

            if lastMessage == nil {
                if type == "user" || type == "assistant" {
                    let isMeta = json["isMeta"] as? Bool ?? false
                    if !isMeta, let message = json["message"] as? [String: Any] {
                        if let msgContent = message["content"] as? String {
                            if !msgContent.hasPrefix("<command-name>") && !msgContent.hasPrefix("<local-command") && !msgContent
                                .hasPrefix("Caveat:") {
                                lastMessage = msgContent
                                lastMessageRole = type
                            }
                        } else if let contentArray = message["content"] as? [[String: Any]] {
                            for block in contentArray.reversed() {
                                let blockType = block["type"] as? String
                                if blockType == "tool_use" {
                                    let toolName = block["name"] as? String ?? "Tool"
                                    let toolInput = Self.formatToolInput(block["input"] as? [String: Any], toolName: toolName)
                                    lastMessage = toolInput
                                    lastMessageRole = "tool"
                                    lastToolName = toolName
                                    break
                                } else if blockType == "text", let text = block["text"] as? String {
                                    if !text.hasPrefix("[Request interrupted by user") {
                                        lastMessage = text
                                        lastMessageRole = type
                                        break
                                    }
                                }
                            }
                        }
                    }
                }
            }

            if !foundLastUserMessage && type == "user" {
                let isMeta = json["isMeta"] as? Bool ?? false
                if !isMeta, let message = json["message"] as? [String: Any] {
                    if let msgContent = message["content"] as? String {
                        if !msgContent.hasPrefix("<command-name>") && !msgContent.hasPrefix("<local-command") && !msgContent.hasPrefix("Caveat:") {
                            if let timestampStr = json["timestamp"] as? String {
                                lastUserMessageDate = formatter.date(from: timestampStr)
                            }
                            foundLastUserMessage = true
                        }
                    }
                }
            }

            if summary == nil, type == "summary", let summaryText = json["summary"] as? String {
                summary = summaryText
            }

            if summary != nil && lastMessage != nil && foundLastUserMessage {
                break
            }
        }

        return ConversationInfo(
            summary: summary,
            lastMessage: Self.truncateMessage(lastMessage, maxLength: 80),
            lastMessageRole: lastMessageRole,
            lastToolName: lastToolName,
            firstUserMessage: firstUserMessage,
            lastUserMessageDate: lastUserMessageDate
        )
    }

    /// Parse only new lines since last read (incremental)
    private func parseNewLines(filePath: String, state: inout IncrementalParseState) -> [ChatMessage] {
        guard let fileHandle = FileHandle(forReadingAtPath: filePath) else {
            return []
        }
        defer { try? fileHandle.close() }

        let fileSize: UInt64
        do {
            fileSize = try fileHandle.seekToEnd()
        } catch {
            return []
        }

        if fileSize < state.lastFileOffset {
            state = IncrementalParseState()
        }

        if fileSize == state.lastFileOffset {
            return state.messages
        }

        do {
            try fileHandle.seek(toOffset: state.lastFileOffset)
        } catch {
            return state.messages
        }

        guard let newData = try? fileHandle.readToEnd(),
              let newContent = String(data: newData, encoding: .utf8)
        else {
            return state.messages
        }

        state.clearPending = false
        let isIncrementalRead = state.lastFileOffset > 0
        let lines = newContent.components(separatedBy: "\n")
        var newMessages: [ChatMessage] = []

        for line in lines where !line.isEmpty {
            if line.contains("<command-name>/clear</command-name>") {
                state.messages = []
                state.seenToolIDs = []
                state.toolIDToName = [:]
                state.completedToolIDs = []
                state.toolResults = [:]
                state.structuredResults = [:]

                if isIncrementalRead {
                    state.clearPending = true
                    state.lastClearOffset = state.lastFileOffset
                    Self.logger.debug("/clear detected (new), will notify UI")
                }
                continue
            }

            if line.contains("\"tool_result\"") {
                if let lineData = line.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                   let messageDict = json["message"] as? [String: Any],
                   let contentArray = messageDict["content"] as? [[String: Any]] {
                    let toolUseResult = json["toolUseResult"] as? [String: Any]
                    let topLevelToolName = json["toolName"] as? String
                    let stdout = toolUseResult?["stdout"] as? String
                    let stderr = toolUseResult?["stderr"] as? String

                    for block in contentArray {
                        if block["type"] as? String == "tool_result",
                           let toolUseID = block["tool_use_id"] as? String {
                            state.completedToolIDs.insert(toolUseID)

                            let content = block["content"] as? String
                            let isError = block["is_error"] as? Bool ?? false
                            state.toolResults[toolUseID] = ToolResult(
                                content: content,
                                stdout: stdout,
                                stderr: stderr,
                                isError: isError
                            )

                            let toolName = topLevelToolName ?? state.toolIDToName[toolUseID]

                            if let toolUseResult,
                               let name = toolName {
                                let structured = ToolResultParser.parseStructuredResult(
                                    toolName: name,
                                    toolUseResult: toolUseResult,
                                    isError: isError
                                )
                                state.structuredResults[toolUseID] = structured
                            }
                        }
                    }
                }
            } else if line.contains("\"type\":\"user\"") || line.contains("\"type\":\"assistant\"") {
                if let lineData = line.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                   let message = parseMessageLine(json, seenToolIDs: &state.seenToolIDs, toolIDToName: &state.toolIDToName) {
                    newMessages.append(message)
                    state.messages.append(message)
                }
            }
        }

        state.lastFileOffset = fileSize
        return newMessages
    }

    private func parseMessageLine(_ json: [String: Any], seenToolIDs: inout Set<String>, toolIDToName: inout [String: String]) -> ChatMessage? {
        guard let type = json["type"] as? String,
              let uuid = json["uuid"] as? String
        else {
            return nil
        }

        guard type == "user" || type == "assistant" else {
            return nil
        }

        if json["isMeta"] as? Bool == true {
            return nil
        }

        guard let messageDict = json["message"] as? [String: Any] else {
            return nil
        }

        let timestamp: Date
        if let timestampStr = json["timestamp"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            timestamp = formatter.date(from: timestampStr) ?? Date()
        } else {
            timestamp = Date()
        }

        var blocks: [MessageBlock] = []

        if let content = messageDict["content"] as? String {
            if content.hasPrefix("<command-name>") || content.hasPrefix("<local-command") || content.hasPrefix("Caveat:") {
                return nil
            }
            if content.hasPrefix("[Request interrupted by user") {
                blocks.append(.interrupted)
            } else {
                blocks.append(.text(content))
            }
        } else if let contentArray = messageDict["content"] as? [[String: Any]] {
            for block in contentArray {
                if let blockType = block["type"] as? String {
                    switch blockType {
                    case "text":
                        if let text = block["text"] as? String {
                            if text.hasPrefix("[Request interrupted by user") {
                                blocks.append(.interrupted)
                            } else {
                                blocks.append(.text(text))
                            }
                        }
                    case "tool_use":
                        if let toolID = block["id"] as? String {
                            if seenToolIDs.contains(toolID) {
                                continue
                            }
                            seenToolIDs.insert(toolID)
                            if let toolName = block["name"] as? String {
                                toolIDToName[toolID] = toolName
                            }
                        }
                        if let toolBlock = parseToolUse(block) {
                            blocks.append(.toolUse(toolBlock))
                        }
                    case "thinking":
                        if let thinking = block["thinking"] as? String {
                            blocks.append(.thinking(thinking))
                        }
                    default:
                        break
                    }
                }
            }
        }

        guard !blocks.isEmpty else { return nil }

        let role: ChatRole = type == "user" ? .user : .assistant

        return ChatMessage(
            id: uuid,
            role: role,
            timestamp: timestamp,
            content: blocks
        )
    }

    private func parseToolUse(_ block: [String: Any]) -> ToolUseBlock? {
        guard let id = block["id"] as? String,
              let name = block["name"] as? String
        else {
            return nil
        }

        var input: [String: String] = [:]
        if let inputDict = block["input"] as? [String: Any] {
            for (key, value) in inputDict {
                if let strValue = value as? String {
                    input[key] = strValue
                } else if let intValue = value as? Int {
                    input[key] = String(intValue)
                } else if let boolValue = value as? Bool {
                    input[key] = boolValue ? "true" : "false"
                }
            }
        }

        return ToolUseBlock(id: id, name: name, input: input)
    }
}

// swiftlint:enable type_body_length function_body_length cyclomatic_complexity

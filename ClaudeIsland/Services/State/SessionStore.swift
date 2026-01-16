//
//  SessionStore.swift
//  ClaudeIsland
//
//  Central state manager for all Claude sessions.
//  Single source of truth - all state mutations flow through process().
//

import Combine
import Foundation
import Mixpanel
import os.log

// Central state manager for all Claude sessions
// Uses Swift actor for thread-safe state mutations
// swiftlint:disable:next type_body_length
actor SessionStore {
    // MARK: Lifecycle

    // MARK: - Initialization

    private init() {}

    // MARK: Internal

    static let shared = SessionStore()

    /// Logger for session store (nonisolated static for cross-context access)
    nonisolated static let logger = Logger(subsystem: "com.claudeisland", category: "Session")

    // MARK: - State

    /// All sessions keyed by sessionID (internal for extension access)
    var sessions: [String: SessionState] = [:]

    /// Public publisher for UI subscription
    nonisolated var sessionsPublisher: AnyPublisher<[SessionState], Never> {
        sessionsSubject.eraseToAnyPublisher()
    }

    // MARK: - Event Processing

    /// Process any session event - the ONLY way to mutate state
    func process(_ event: SessionEvent) async { // swiftlint:disable:this cyclomatic_complexity
        Self.logger.debug("Processing: \(String(describing: event), privacy: .public)")

        switch event {
        case let .hookReceived(hookEvent):
            await processHookEvent(hookEvent)

        case let .permissionApproved(sessionID, toolUseID):
            await processPermissionApproved(sessionID: sessionID, toolUseID: toolUseID)

        case let .permissionDenied(sessionID, toolUseID, reason):
            await processPermissionDenied(sessionID: sessionID, toolUseID: toolUseID, reason: reason)

        case let .permissionSocketFailed(sessionID, toolUseID):
            await processSocketFailure(sessionID: sessionID, toolUseID: toolUseID)

        case let .fileUpdated(payload):
            await processFileUpdate(payload)

        case let .interruptDetected(sessionID):
            await processInterrupt(sessionID: sessionID)

        case let .clearDetected(sessionID):
            await processClearDetected(sessionID: sessionID)

        case let .sessionEnded(sessionID):
            await processSessionEnd(sessionID: sessionID)

        case let .loadHistory(sessionID, cwd):
            await loadHistoryFromFile(sessionID: sessionID, cwd: cwd)

        case let .historyLoaded(payload):
            await processHistoryLoaded(payload)

        case let .toolCompleted(sessionID, toolUseID, result):
            await processToolCompleted(sessionID: sessionID, toolUseID: toolUseID, result: result)

        // MARK: - Subagent Events

        case let .subagentStarted(sessionID, taskToolID):
            handleSubagentStarted(sessionID: sessionID, taskToolID: taskToolID)

        case let .subagentToolExecuted(sessionID, tool):
            handleSubagentToolExecuted(sessionID: sessionID, tool: tool)

        case let .subagentToolCompleted(sessionID, toolID, status):
            handleSubagentToolCompleted(sessionID: sessionID, toolID: toolID, status: status)

        case let .subagentStopped(sessionID, taskToolID):
            handleSubagentStopped(sessionID: sessionID, taskToolID: taskToolID)

        case .agentFileUpdated:
            // No longer used - subagent tools are populated from JSONL completion
            break
        }

        publishState()
    }

    // MARK: - Queries

    /// Get a specific session
    func session(for sessionID: String) -> SessionState? {
        sessions[sessionID]
    }

    /// Check if there's an active permission for a session
    func hasActivePermission(sessionID: String) -> Bool {
        guard let session = sessions[sessionID] else { return false }
        if case .waitingForApproval = session.phase {
            return true
        }
        return false
    }

    /// Get all current sessions
    func allSessions() -> [SessionState] {
        Array(sessions.values)
    }

    // MARK: Private

    /// Pending file syncs (debounced)
    private var pendingSyncs: [String: Task<Void, Never>] = [:]

    /// Sync debounce interval (100ms)
    private let syncDebounceNs: UInt64 = 100_000_000

    // MARK: - Published State (for UI)

    /// Publisher for session state changes (nonisolated for Combine subscription from any context)
    private nonisolated(unsafe) let sessionsSubject = CurrentValueSubject<[SessionState], Never>([])

    // MARK: - Hook Event Processing

    private func processHookEvent(_ event: HookEvent) async {
        let sessionID = event.sessionID
        let isNewSession = sessions[sessionID] == nil
        var session = sessions[sessionID] ?? createSession(from: event)

        // Track new session in Mixpanel
        if isNewSession {
            Mixpanel.mainInstance().track(event: "Session Started")
        }

        session.pid = event.pid
        if let pid = event.pid {
            let tree = ProcessTreeBuilder.shared.buildTree()
            session.isInTmux = ProcessTreeBuilder.shared.isInTmux(pid: pid, tree: tree)
        }
        if let tty = event.tty {
            session.tty = tty.replacingOccurrences(of: "/dev/", with: "")
        }
        session.lastActivity = Date()

        if event.status == "ended" {
            sessions.removeValue(forKey: sessionID)
            cancelPendingSync(sessionID: sessionID)
            return
        }

        let newPhase = event.determinePhase()

        if session.phase.canTransition(to: newPhase) {
            session.phase = newPhase
        } else {
            Self.logger
                .debug(
                    "Invalid transition: \(String(describing: session.phase), privacy: .public) -> \(String(describing: newPhase), privacy: .public), ignoring"
                )
        }

        if event.event == "PermissionRequest", let toolUseID = event.toolUseID {
            Self.logger.debug("Setting tool \(toolUseID.prefix(12), privacy: .public) status to waitingForApproval")
            updateToolStatus(in: &session, toolID: toolUseID, status: .waitingForApproval)
        }

        processToolTracking(event: event, session: &session)
        trackSubagent(event: event, session: &session)

        if event.event == "Stop" {
            session.subagentState = SubagentState()
        }

        sessions[sessionID] = session
        publishState()

        if event.shouldSyncFile {
            scheduleFileSync(sessionID: sessionID, cwd: event.cwd)
        }
    }

    private func createSession(from event: HookEvent) -> SessionState {
        SessionState(
            sessionID: event.sessionID,
            cwd: event.cwd,
            projectName: URL(fileURLWithPath: event.cwd).lastPathComponent,
            pid: event.pid,
            tty: event.tty?.replacingOccurrences(of: "/dev/", with: ""),
            isInTmux: false, // Will be updated
            phase: .idle
        )
    }

    private func processToolTracking(event: HookEvent, session: inout SessionState) {
        switch event.event {
        case "PreToolUse":
            if let toolUseID = event.toolUseID, let toolName = event.tool {
                session.toolTracker.startTool(id: toolUseID, name: toolName)

                // Skip creating top-level placeholder for subagent tools
                // They'll appear under their parent Task instead
                let isSubagentTool = session.subagentState.hasActiveSubagent && toolName != "Task"
                if isSubagentTool {
                    return
                }

                let toolExists = session.chatItems.contains { $0.id == toolUseID }
                if !toolExists {
                    var input: [String: String] = [:]
                    if let hookInput = event.toolInput {
                        for (key, value) in hookInput {
                            if let str = value.value as? String {
                                input[key] = str
                            } else if let num = value.value as? Int {
                                input[key] = String(num)
                            } else if let bool = value.value as? Bool {
                                input[key] = bool ? "true" : "false"
                            }
                        }
                    }

                    let placeholderItem = ChatHistoryItem(
                        id: toolUseID,
                        type: .toolCall(ToolCallItem(
                            name: toolName,
                            input: input,
                            status: .running,
                            result: nil,
                            structuredResult: nil,
                            subagentTools: []
                        )),
                        timestamp: Date()
                    )
                    session.chatItems.append(placeholderItem)
                    Self.logger.debug("Created placeholder tool entry for \(toolUseID.prefix(16), privacy: .public)")
                }
            }

        case "PostToolUse":
            if let toolUseID = event.toolUseID {
                session.toolTracker.completeTool(id: toolUseID, success: true)
                // Update chatItem status - tool completed (possibly approved via terminal)
                // Only update if still waiting for approval or running
                for i in 0 ..< session.chatItems.count {
                    if session.chatItems[i].id == toolUseID,
                       case var .toolCall(tool) = session.chatItems[i].type,
                       tool.status == .waitingForApproval || tool.status == .running {
                        tool.status = .success
                        session.chatItems[i] = ChatHistoryItem(
                            id: toolUseID,
                            type: .toolCall(tool),
                            timestamp: session.chatItems[i].timestamp
                        )
                        break
                    }
                }
            }

        default:
            break
        }
    }

    /// Parse ISO8601 timestamp string
    private func parseTimestamp(_ timestampStr: String?) -> Date? {
        guard let str = timestampStr else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: str)
    }

    // MARK: - Permission Processing

    private func processPermissionApproved(sessionID: String, toolUseID: String) async {
        guard var session = sessions[sessionID] else { return }

        // Update tool status in chat history first
        updateToolStatus(in: &session, toolID: toolUseID, status: .running)

        // Check if there are other tools still waiting for approval
        if let nextPending = findNextPendingTool(in: session, excluding: toolUseID) {
            // Another tool is waiting - stay in waitingForApproval with that tool's context
            let newPhase = SessionPhase.waitingForApproval(PermissionContext(
                toolUseID: nextPending.id,
                toolName: nextPending.name,
                toolInput: nil, // We don't have the input stored in chatItems
                receivedAt: nextPending.timestamp
            ))
            if session.phase.canTransition(to: newPhase) {
                session.phase = newPhase
                Self.logger.debug("Switched to next pending tool: \(nextPending.id.prefix(12), privacy: .public)")
            }
        } else {
            // No more pending tools - transition to processing
            if case let .waitingForApproval(ctx) = session.phase, ctx.toolUseID == toolUseID {
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            } else if case .waitingForApproval = session.phase {
                // The approved tool wasn't the one in phase context, but no others pending
                // This can happen if tools were approved out of order
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            }
        }

        sessions[sessionID] = session
    }

    // MARK: - Tool Completion Processing

    /// Process a tool completion event (from JSONL detection)
    /// This is the authoritative handler for tool completions - ensures consistent state updates
    private func processToolCompleted(sessionID: String, toolUseID: String, result: ToolCompletionResult) async {
        guard var session = sessions[sessionID] else { return }

        // Check if this tool is already completed (avoid duplicate processing)
        if let existingItem = session.chatItems.first(where: { $0.id == toolUseID }),
           case let .toolCall(tool) = existingItem.type,
           tool.status == .success || tool.status == .error || tool.status == .interrupted {
            // Already completed, skip
            return
        }

        // Update the tool status
        for i in 0 ..< session.chatItems.count {
            if session.chatItems[i].id == toolUseID,
               case var .toolCall(tool) = session.chatItems[i].type {
                tool.status = result.status
                tool.result = result.result
                tool.structuredResult = result.structuredResult
                session.chatItems[i] = ChatHistoryItem(
                    id: toolUseID,
                    type: .toolCall(tool),
                    timestamp: session.chatItems[i].timestamp
                )
                Self.logger
                    .debug(
                        "Tool \(toolUseID.prefix(12), privacy: .public) completed with status: \(String(describing: result.status), privacy: .public)"
                    )
                break
            }
        }

        // Update session phase if needed
        // If the completed tool was the one in the phase context, switch to next pending or processing
        if case let .waitingForApproval(ctx) = session.phase, ctx.toolUseID == toolUseID {
            if let nextPending = findNextPendingTool(in: session, excluding: toolUseID) {
                let newPhase = SessionPhase.waitingForApproval(PermissionContext(
                    toolUseID: nextPending.id,
                    toolName: nextPending.name,
                    toolInput: nil,
                    receivedAt: nextPending.timestamp
                ))
                session.phase = newPhase
                Self.logger.debug("Switched to next pending tool after completion: \(nextPending.id.prefix(12), privacy: .public)")
            } else {
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            }
        }

        sessions[sessionID] = session
    }

    /// Find the next tool waiting for approval (excluding a specific tool ID)
    private func findNextPendingTool(in session: SessionState, excluding toolID: String) -> (id: String, name: String, timestamp: Date)? {
        for item in session.chatItems {
            if item.id == toolID { continue }
            if case let .toolCall(tool) = item.type, tool.status == .waitingForApproval {
                return (id: item.id, name: tool.name, timestamp: item.timestamp)
            }
        }
        return nil
    }

    private func processPermissionDenied(sessionID: String, toolUseID: String, reason: String?) async {
        guard var session = sessions[sessionID] else { return }

        // Update tool status in chat history first
        updateToolStatus(in: &session, toolID: toolUseID, status: .error)

        // Check if there are other tools still waiting for approval
        if let nextPending = findNextPendingTool(in: session, excluding: toolUseID) {
            // Another tool is waiting - stay in waitingForApproval with that tool's context
            let newPhase = SessionPhase.waitingForApproval(PermissionContext(
                toolUseID: nextPending.id,
                toolName: nextPending.name,
                toolInput: nil,
                receivedAt: nextPending.timestamp
            ))
            if session.phase.canTransition(to: newPhase) {
                session.phase = newPhase
                Self.logger.debug("Switched to next pending tool after denial: \(nextPending.id.prefix(12), privacy: .public)")
            }
        } else {
            // No more pending tools - transition to processing (Claude will handle denial)
            if case let .waitingForApproval(ctx) = session.phase, ctx.toolUseID == toolUseID {
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            } else if case .waitingForApproval = session.phase {
                // The denied tool wasn't the one in phase context, but no others pending
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            }
        }

        sessions[sessionID] = session
    }

    private func processSocketFailure(sessionID: String, toolUseID: String) async {
        guard var session = sessions[sessionID] else { return }

        // Mark the failed tool's status as error
        updateToolStatus(in: &session, toolID: toolUseID, status: .error)

        // Check if there are other tools still waiting for approval
        if let nextPending = findNextPendingTool(in: session, excluding: toolUseID) {
            // Another tool is waiting - switch to that tool's context
            let newPhase = SessionPhase.waitingForApproval(PermissionContext(
                toolUseID: nextPending.id,
                toolName: nextPending.name,
                toolInput: nil,
                receivedAt: nextPending.timestamp
            ))
            if session.phase.canTransition(to: newPhase) {
                session.phase = newPhase
                Self.logger.debug("Switched to next pending tool after socket failure: \(nextPending.id.prefix(12), privacy: .public)")
            }
        } else {
            // No more pending tools - clear permission state
            if case let .waitingForApproval(ctx) = session.phase, ctx.toolUseID == toolUseID {
                session.phase = .idle
            } else if case .waitingForApproval = session.phase {
                // The failed tool wasn't in phase context, but no others pending
                session.phase = .idle
            }
        }

        sessions[sessionID] = session
    }

    // MARK: - File Update Processing

    private func processFileUpdate(_ payload: FileUpdatePayload) async {
        guard var session = sessions[payload.sessionID] else { return }

        // Update conversationInfo from JSONL (summary, lastMessage, etc.)
        let conversationInfo = await ConversationParser.shared.parse(
            sessionID: payload.sessionID,
            cwd: session.cwd
        )
        session.conversationInfo = conversationInfo

        // Handle /clear reconciliation - remove items that no longer exist in parser state
        if session.needsClearReconciliation {
            // Build set of valid IDs from the payload messages
            var validIDs = Set<String>()
            for message in payload.messages {
                for (blockIndex, block) in message.content.enumerated() {
                    switch block {
                    case let .toolUse(tool):
                        validIDs.insert(tool.id)
                    case .text,
                         .thinking,
                         .interrupted:
                        let itemID = "\(message.id)-\(block.typePrefix)-\(blockIndex)"
                        validIDs.insert(itemID)
                    }
                }
            }

            // Filter chatItems to only keep valid items OR items that are very recent
            // (within last 2 seconds - these are hook-created placeholders for post-clear tools)
            let cutoffTime = Date().addingTimeInterval(-2)
            let previousCount = session.chatItems.count
            session.chatItems = session.chatItems.filter { item in
                validIDs.contains(item.id) || item.timestamp > cutoffTime
            }

            // Also reset tool tracker
            session.toolTracker = ToolTracker()
            session.subagentState = SubagentState()

            session.needsClearReconciliation = false
            Self.logger.debug("Clear reconciliation: kept \(session.chatItems.count) of \(previousCount) items")
        }

        processMessages(
            from: payload,
            into: &session
        )

        if !payload.isIncremental {
            session.chatItems.sort { $0.timestamp < $1.timestamp }
        }

        session.toolTracker.lastSyncTime = Date()

        await populateSubagentToolsFromAgentFiles(
            session: &session,
            cwd: payload.cwd,
            structuredResults: payload.structuredResults
        )

        sessions[payload.sessionID] = session

        await emitToolCompletionEvents(
            sessionID: payload.sessionID,
            session: session,
            completedToolIDs: payload.completedToolIDs,
            toolResults: payload.toolResults,
            structuredResults: payload.structuredResults
        )
    }

    /// Process messages from payload into session chat items
    private func processMessages(
        from payload: FileUpdatePayload,
        into session: inout SessionState
    ) {
        var context = ItemCreationContext(
            existingIDs: Set(session.chatItems.map(\.id)),
            completedTools: payload.completedToolIDs,
            toolResults: payload.toolResults,
            structuredResults: payload.structuredResults,
            toolTracker: session.toolTracker
        )

        for message in payload.messages {
            for (blockIndex, block) in message.content.enumerated() {
                if case let .toolUse(tool) = block {
                    if let idx = session.chatItems.firstIndex(where: { $0.id == tool.id }) {
                        if case let .toolCall(existingTool) = session.chatItems[idx].type {
                            session.chatItems[idx] = ChatHistoryItem(
                                id: tool.id,
                                type: .toolCall(ToolCallItem(
                                    name: tool.name,
                                    input: tool.input,
                                    status: existingTool.status,
                                    result: existingTool.result,
                                    structuredResult: existingTool.structuredResult,
                                    subagentTools: existingTool.subagentTools
                                )),
                                timestamp: message.timestamp
                            )
                        }
                        continue
                    }
                }

                if let item = ChatItemFactory.createItem(
                    from: block,
                    message: message,
                    blockIndex: blockIndex,
                    context: &context
                ) {
                    session.chatItems.append(item)
                }
            }
        }

        session.toolTracker = context.toolTracker
    }

    /// Populate subagent tools for Task tools using their agent JSONL files
    private func populateSubagentToolsFromAgentFiles(
        session: inout SessionState,
        cwd: String,
        structuredResults: [String: ToolResultData]
    ) async {
        for i in 0 ..< session.chatItems.count {
            guard case var .toolCall(tool) = session.chatItems[i].type,
                  tool.name == "Task",
                  let structuredResult = structuredResults[session.chatItems[i].id],
                  case let .task(taskResult) = structuredResult,
                  !taskResult.agentID.isEmpty
            else { continue }

            let taskToolID = session.chatItems[i].id

            // Store agentID → description mapping for AgentOutputTool display
            if let description = session.subagentState.activeTasks[taskToolID]?.description {
                session.subagentState.agentDescriptions[taskResult.agentID] = description
            } else if let description = tool.input["description"] {
                session.subagentState.agentDescriptions[taskResult.agentID] = description
            }

            let subagentToolInfos = await ConversationParser.shared.parseSubagentTools(
                agentID: taskResult.agentID,
                cwd: cwd
            )

            guard !subagentToolInfos.isEmpty else { continue }

            tool.subagentTools = subagentToolInfos.map { info in
                SubagentToolCall(
                    id: info.id,
                    name: info.name,
                    input: info.input,
                    status: info.isCompleted ? .success : .running,
                    timestamp: parseTimestamp(info.timestamp) ?? Date()
                )
            }

            session.chatItems[i] = ChatHistoryItem(
                id: taskToolID,
                type: .toolCall(tool),
                timestamp: session.chatItems[i].timestamp
            )

            Self.logger
                .debug(
                    "Populated \(subagentToolInfos.count) subagent tools for Task \(taskToolID.prefix(12), privacy: .public) from agent \(taskResult.agentID.prefix(8), privacy: .public)"
                )
        }
    }

    /// Emit toolCompleted events for tools that have results in JSONL but aren't marked complete yet
    private func emitToolCompletionEvents(
        sessionID: String,
        session: SessionState,
        completedToolIDs: Set<String>,
        toolResults: [String: ConversationParser.ToolResult],
        structuredResults: [String: ToolResultData]
    ) async {
        for item in session.chatItems {
            guard case let .toolCall(tool) = item.type else { continue }

            // Only emit for tools that are running or waiting but have results in JSONL
            guard tool.status == .running || tool.status == .waitingForApproval else { continue }
            guard completedToolIDs.contains(item.id) else { continue }

            let result = ToolCompletionResult.from(
                parserResult: toolResults[item.id],
                structuredResult: structuredResults[item.id]
            )

            // Process the completion event (this will update state and phase consistently)
            await process(.toolCompleted(sessionID: sessionID, toolUseID: item.id, result: result))
        }
    }

    private func updateToolStatus(in session: inout SessionState, toolID: String, status: ToolStatus) {
        var found = false
        for i in 0 ..< session.chatItems.count {
            if session.chatItems[i].id == toolID,
               case var .toolCall(tool) = session.chatItems[i].type {
                tool.status = status
                session.chatItems[i] = ChatHistoryItem(
                    id: toolID,
                    type: .toolCall(tool),
                    timestamp: session.chatItems[i].timestamp
                )
                found = true
                break
            }
        }
        if !found {
            let count = session.chatItems.count
            Self.logger.warning("Tool \(toolID.prefix(16), privacy: .public) not found in chatItems (count: \(count))")
        }
    }

    // MARK: - Interrupt Processing

    private func processInterrupt(sessionID: String) async {
        guard var session = sessions[sessionID] else { return }

        // Clear subagent state
        session.subagentState = SubagentState()

        // Mark running tools as interrupted
        for i in 0 ..< session.chatItems.count {
            if case var .toolCall(tool) = session.chatItems[i].type,
               tool.status == .running {
                tool.status = .interrupted
                session.chatItems[i] = ChatHistoryItem(
                    id: session.chatItems[i].id,
                    type: .toolCall(tool),
                    timestamp: session.chatItems[i].timestamp
                )
            }
        }

        // Transition to idle
        if session.phase.canTransition(to: .idle) {
            session.phase = .idle
        }

        sessions[sessionID] = session
    }

    // MARK: - Clear Processing

    private func processClearDetected(sessionID: String) async {
        guard var session = sessions[sessionID] else { return }

        Self.logger.info("Processing /clear for session \(sessionID.prefix(8), privacy: .public)")

        // Mark that a clear happened - the next fileUpdated will reconcile
        // by removing items that no longer exist in the parser's state
        session.needsClearReconciliation = true
        sessions[sessionID] = session

        Self.logger.info("/clear processed for session \(sessionID.prefix(8), privacy: .public) - marked for reconciliation")
    }

    // MARK: - Session End Processing

    private func processSessionEnd(sessionID: String) async {
        sessions.removeValue(forKey: sessionID)
        cancelPendingSync(sessionID: sessionID)
    }

    // MARK: - History Loading

    private func loadHistoryFromFile(sessionID: String, cwd: String) async {
        // Parse file asynchronously
        let messages = await ConversationParser.shared.parseFullConversation(
            sessionID: sessionID,
            cwd: cwd
        )
        let completedTools = await ConversationParser.shared.completedToolIDs(for: sessionID)
        let toolResults = await ConversationParser.shared.toolResults(for: sessionID)
        let structuredResults = await ConversationParser.shared.structuredResults(for: sessionID)

        // Also parse conversationInfo (summary, lastMessage, etc.)
        let conversationInfo = await ConversationParser.shared.parse(
            sessionID: sessionID,
            cwd: cwd
        )

        // Process loaded history
        await process(.historyLoaded(HistoryLoadedPayload(
            sessionID: sessionID,
            messages: messages,
            completedTools: completedTools,
            toolResults: toolResults,
            structuredResults: structuredResults,
            conversationInfo: conversationInfo
        )))
    }

    private func processHistoryLoaded(_ payload: HistoryLoadedPayload) async {
        guard var session = sessions[payload.sessionID] else { return }

        // Update conversationInfo (summary, lastMessage, etc.)
        session.conversationInfo = payload.conversationInfo

        // Convert messages to chat items
        var context = ItemCreationContext(
            existingIDs: Set(session.chatItems.map(\.id)),
            completedTools: payload.completedTools,
            toolResults: payload.toolResults,
            structuredResults: payload.structuredResults,
            toolTracker: session.toolTracker
        )

        for message in payload.messages {
            for (blockIndex, block) in message.content.enumerated() {
                if let item = ChatItemFactory.createItem(
                    from: block,
                    message: message,
                    blockIndex: blockIndex,
                    context: &context
                ) {
                    session.chatItems.append(item)
                }
            }
        }

        session.toolTracker = context.toolTracker

        // Sort by timestamp
        session.chatItems.sort { $0.timestamp < $1.timestamp }

        sessions[payload.sessionID] = session
    }

    // MARK: - File Sync Scheduling

    private func scheduleFileSync(sessionID: String, cwd: String) {
        // Cancel existing sync
        cancelPendingSync(sessionID: sessionID)

        // Schedule new debounced sync
        pendingSyncs[sessionID] = Task { [weak self, syncDebounceNs] in
            try? await Task.sleep(nanoseconds: syncDebounceNs)
            guard !Task.isCancelled else { return }

            // Parse incrementally - only get NEW messages since last call
            let result = await ConversationParser.shared.parseIncremental(
                sessionID: sessionID,
                cwd: cwd
            )

            if result.clearDetected {
                await self?.process(.clearDetected(sessionID: sessionID))
            }

            guard !result.newMessages.isEmpty || result.clearDetected else {
                return
            }

            let payload = FileUpdatePayload(
                sessionID: sessionID,
                cwd: cwd,
                messages: result.newMessages,
                isIncremental: !result.clearDetected,
                completedToolIDs: result.completedToolIDs,
                toolResults: result.toolResults,
                structuredResults: result.structuredResults
            )

            await self?.process(.fileUpdated(payload))
        }
    }

    private func cancelPendingSync(sessionID: String) {
        pendingSyncs[sessionID]?.cancel()
        pendingSyncs.removeValue(forKey: sessionID)
    }

    // MARK: - State Publishing

    private func publishState() {
        let sortedSessions = Array(sessions.values).sorted { $0.projectName < $1.projectName }
        sessionsSubject.send(sortedSessions)
    }
}

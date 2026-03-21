//
//  SessionStore+Subagents.swift
//  ClaudeIsland
//
//  Subagent event handlers for SessionStore.
//  Extracted for type body length compliance.
//

import Foundation
import os

// MARK: - Subagent Event Handlers

extension SessionStore {
    /// Handle subagent started event
    func handleSubagentStarted(sessionID: String, taskToolID: String) {
        guard var session = sessions[sessionID] else { return }
        session.subagentState.startTask(taskToolID: taskToolID)
        sessions[sessionID] = session
    }

    /// Handle subagent tool executed event
    func handleSubagentToolExecuted(sessionID: String, tool: SubagentToolCall) {
        guard var session = sessions[sessionID] else { return }
        session.subagentState.addSubagentTool(tool)
        sessions[sessionID] = session
    }

    /// Handle subagent tool completed event
    func handleSubagentToolCompleted(sessionID: String, toolID: String, status: ToolStatus) {
        guard var session = sessions[sessionID] else { return }
        session.subagentState.updateSubagentToolStatus(toolID: toolID, status: status)
        sessions[sessionID] = session
    }

    /// Handle subagent stopped event
    func handleSubagentStopped(sessionID: String, taskToolID: String) {
        guard var session = sessions[sessionID] else { return }
        session.subagentState.stopTask(taskToolID: taskToolID)
        sessions[sessionID] = session
    }
}

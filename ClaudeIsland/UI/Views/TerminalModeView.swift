//
//  TerminalModeView.swift
//  ClaudeIsland
//
//  Terminal mode: dense inline tool rendering with full content visible
//

import SwiftUI

struct TerminalModeView: View {
    // MARK: Internal

    let item: ChatHistoryItem
    let sessionID: String
    let onApprove: (() -> Void)?
    let onDeny: (() -> Void)?

    var body: some View {
        switch self.item.type {
        case let .user(text):
            self.userMessage(text)
        case let .assistant(text):
            self.assistantMessage(text)
        case let .toolCall(tool):
            ToolCallInlineView(
                tool: tool,
                sessionID: self.sessionID,
                onApprove: self.onApprove,
                onDeny: self.onDeny,
            )
        case let .thinking(text):
            ThinkingBlockView(text: text)
        case .interrupted:
            self.interruptedMessage
        }
    }

    // MARK: Private

    private let labelBlue = Color(red: 0.345, green: 0.651, blue: 1.0)
    private let labelPurple = Color(red: 0.702, green: 0.557, blue: 0.941)

    private var interruptedMessage: some View {
        Text("Interrupted")
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(Color(red: 0.973, green: 0.318, blue: 0.286))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func userMessage(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("You")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(self.labelBlue)

            MarkdownText(text, color: .white.opacity(0.9), fontSize: 11)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func assistantMessage(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Claude")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(self.labelPurple)

            MarkdownText(text, color: .white.opacity(0.9), fontSize: 11)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

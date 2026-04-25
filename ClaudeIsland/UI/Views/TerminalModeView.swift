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
                onApprove: self.onApprove,
                onDeny: self.onDeny,
            )
        case let .thinking(text):
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ThinkingBlockView(text: text)
            }
        case .interrupted:
            self.interruptedMessage
        }
    }

    // MARK: Private

    private let labelBlue = Color(red: 0.345, green: 0.651, blue: 1.0)
    private let labelPurple = Color(red: 0.702, green: 0.557, blue: 0.941)
    private let errorRed = Color(red: 0.973, green: 0.318, blue: 0.286)

    private var interruptedMessage: some View {
        Text("Interrupted")
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(self.errorRed)
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
                .foregroundColor(Self.isErrorMessage(text) ? self.errorRed : self.labelPurple)

            MarkdownText(
                text,
                color: Self.isErrorMessage(text) ? self.errorRed.opacity(0.9) : .white.opacity(0.9),
                fontSize: 11,
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func isErrorMessage(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("error:") || lowered.contains("api error")
            || lowered.hasPrefix("error") || lowered.contains("failed:")
            || lowered.contains("exception:") || lowered.contains("fatal:")
    }
}

//
//  ToolCallInlineView.swift
//  ClaudeIsland
//
//  Terminal mode inline tool call with status dot, name, content
//

import SwiftUI

// MARK: - ToolCallInlineView

struct ToolCallInlineView: View {
    // MARK: Internal

    let tool: ToolCallItem
    let onApprove: (() -> Void)?
    let onDeny: (() -> Void)?

    var body: some View {
        let isApproval = self.tool.status == .waitingForApproval

        VStack(alignment: .leading, spacing: 4) {
            // Status line
            self.statusLine

            // Approval buttons
            if isApproval, let onApprove, let onDeny {
                HStack(spacing: 8) {
                    Button {
                        onApprove()
                    } label: {
                        Text("Allow")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Color(red: 0.051, green: 0.067, blue: 0.09))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(0.9))
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)

                    Button {
                        onDeny()
                    } label: {
                        Text("Deny")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white.opacity(0.5))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, 12)
            }

            // Content block
            if self.shouldShowContent {
                self.contentBlock
                    .padding(.leading, 12)
            }
        }
        .padding(isApproval ? 8 : 0)
        .padding(.leading, isApproval ? 2 : 0)
        .background(
            isApproval
                ? RoundedRectangle(cornerRadius: 6)
                .fill(Color(red: 0.824, green: 0.6, blue: 0.133).opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(red: 0.824, green: 0.6, blue: 0.133).opacity(0.15), lineWidth: 1),
                )
                : nil,
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Private

    @State private var pulseOpacity = 0.6

    private var statusColor: Color {
        switch self.tool.status {
        case .running: .white
        case .waitingForApproval: Color(red: 0.824, green: 0.6, blue: 0.133)
        case .success: Color(red: 0.247, green: 0.725, blue: 0.314)
        case .error,
             .interrupted: Color(red: 0.973, green: 0.318, blue: 0.286)
        }
    }

    private var isAnimating: Bool {
        self.tool.status == .running || self.tool.status == .waitingForApproval
    }

    private var toolDisplayName: String {
        MCPToolFormatter.formatToolName(self.tool.name)
    }

    private var inputPreview: String {
        self.tool.inputPreview
    }

    private var rightStatusText: String? {
        switch self.tool.status {
        case .running:
            return "Running..."
        case .waitingForApproval:
            return "Waiting for approval"
        default:
            let display = self.tool.statusDisplay
            return display.text.isEmpty ? nil : display.text
        }
    }

    private var shouldShowContent: Bool {
        // Edit always shows diff
        if self.tool.name == "Edit" {
            return true
        }
        // Task shows subagent tools list
        if self.tool.name == "Task" && !self.tool.subagentTools.isEmpty {
            return true
        }
        // Running tools don't show content yet (except Edit)
        if self.tool.status == .running || self.tool.status == .waitingForApproval {
            return false
        }
        // Tools with no result
        let hasResult = self.tool.result != nil || self.tool.structuredResult != nil
        if !hasResult {
            return false
        }
        // Bash with empty output
        if self.tool.name == "Bash" || self.tool.name == "bash" {
            if let result = self.tool.result, result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return false
            }
        }
        return true
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(self.statusColor.opacity(self.isAnimating ? self.pulseOpacity : 0.6))
                .frame(width: 6, height: 6)
                .shadow(color: self.isAnimating ? self.statusColor.opacity(0.5) : .clear, radius: 3)
                .id(self.tool.status)
                .onAppear {
                    if self.isAnimating {
                        withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                            self.pulseOpacity = 0.15
                        }
                    }
                }

            Text(self.toolDisplayName)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(self.tool.status == .error ? Color(red: 0.973, green: 0.318, blue: 0.286) : .white.opacity(0.45))

            Text("\u{00B7}")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.25))

            Text(self.inputPreview)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Color(red: 0.345, green: 0.651, blue: 1.0))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            if let statusText = self.rightStatusText {
                Text(statusText)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(self.tool.status == .error ? Color(red: 0.973, green: 0.318, blue: 0.286).opacity(0.8) : .white.opacity(0.3))
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder private var contentBlock: some View {
        let isError = self.tool.status == .error

        if self.tool.name == "Task" && !self.tool.subagentTools.isEmpty {
            SubagentToolsList(tools: self.tool.subagentTools)
                .padding(.top, 2)
        } else if self.tool.name == "Edit" && self.tool.status == .running {
            EditInputDiffView(input: self.tool.input)
                .padding(.top, 4)
        } else {
            let lineCount = self.estimateLineCount()
            let needsCap = lineCount > 8

            Group {
                if needsCap {
                    CollapsibleContentView(lineCount: lineCount) {
                        self.resultContent
                    }
                } else {
                    self.resultContent
                }
            }
            .padding(.top, 4)
            .padding(isError ? 4 : 0)
            .background(
                isError
                    ? RoundedRectangle(cornerRadius: 4)
                    .fill(Color(red: 0.973, green: 0.318, blue: 0.286).opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color(red: 0.973, green: 0.318, blue: 0.286).opacity(0.1), lineWidth: 1),
                    )
                    : nil,
            )
        }
    }

    private var resultContent: some View {
        ToolResultContent(tool: self.tool)
    }

    private func estimateLineCount() -> Int {
        if let result = self.tool.result {
            return result.components(separatedBy: "\n").count
        }
        return 0
    }
}

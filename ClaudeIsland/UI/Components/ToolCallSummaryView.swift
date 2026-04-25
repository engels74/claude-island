//
//  ToolCallSummaryView.swift
//  ClaudeIsland
//
//  Chat mode compact one-line tool summary
//

import SwiftUI

struct ToolCallSummaryView: View {
    // MARK: Internal

    let tool: ToolCallItem

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(ToolStatusColors.color(for: self.tool.status).opacity(self.isAnimating ? self.pulseOpacity : 0.6))
                .frame(width: 5, height: 5)
                .id(self.tool.status)
                .onAppear {
                    if self.isAnimating {
                        withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                            self.pulseOpacity = 0.15
                        }
                    }
                }

            Text(self.summaryText)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.35))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    // MARK: Private

    @State private var pulseOpacity = 0.6

    private var isAnimating: Bool {
        self.tool.status == .running || self.tool.status == .waitingForApproval
    }

    private var summaryText: String {
        if self.tool.status == .running {
            return ToolStatusDisplay.running(for: self.tool.name, input: self.tool.input).text
        }
        if self.tool.status == .waitingForApproval {
            return "Waiting for approval"
        }
        if self.tool.status == .interrupted {
            return "Interrupted"
        }
        let completed = ToolStatusDisplay.completed(for: self.tool.name, result: self.tool.structuredResult).text
        if completed == "Completed" && !self.tool.inputPreview.isEmpty {
            let name = MCPToolFormatter.formatToolName(self.tool.name)
            return "\(name): \(self.tool.inputPreview)"
        }
        return completed
    }
}

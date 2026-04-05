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
                .fill(self.statusColor.opacity(0.6))
                .frame(width: 5, height: 5)

            Text(self.summaryText)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.35))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    // MARK: Private

    private var statusColor: Color {
        switch self.tool.status {
        case .running: .white
        case .waitingForApproval: Color(red: 0.824, green: 0.6, blue: 0.133)
        case .success: Color(red: 0.247, green: 0.725, blue: 0.314)
        case .error,
             .interrupted: Color(red: 0.973, green: 0.318, blue: 0.286)
        }
    }

    private var summaryText: String {
        if self.tool.status == .running {
            return ToolStatusDisplay.running(for: self.tool.name, input: self.tool.input).text
        }
        if self.tool.status == .waitingForApproval {
            return "Waiting for approval"
        }
        return ToolStatusDisplay.completed(for: self.tool.name, result: self.tool.structuredResult).text
    }
}

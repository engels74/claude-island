//
//  ChatModeView.swift
//  ClaudeIsland
//
//  Chat mode: iMessage-style bubbles with compact tool summaries
//

import SwiftUI

// MARK: - ChatModeView

struct ChatModeView: View {
    // MARK: Internal

    let item: ChatHistoryItem
    let sessionID: String

    var body: some View {
        switch self.item.type {
        case let .user(text):
            self.userBubble(text)
        case let .assistant(text):
            self.assistantBubble {
                MarkdownText(
                    text,
                    color: ChatMessageHelpers.isErrorMessage(text) ? self.errorRed.opacity(0.9) : .white.opacity(0.9),
                    fontSize: 13,
                    useSystemFont: true,
                )
            }
        case let .toolCall(tool):
            self.assistantBubble {
                VStack(alignment: .leading, spacing: 0) {
                    Rectangle()
                        .fill(Color.white.opacity(0.06))
                        .frame(height: 1)
                        .padding(.bottom, 6)

                    ToolCallSummaryView(tool: tool)
                }
            }
        case let .thinking(text):
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.assistantBubble {
                    ThinkingBlockView(text: text)
                }
            }
        case .interrupted:
            self.assistantBubble {
                Text("Interrupted")
                    .font(.system(size: 13))
                    .foregroundColor(Color(red: 0.973, green: 0.318, blue: 0.286))
            }
        }
    }

    // MARK: Private

    private let bubbleBlue = Color(red: 0.145, green: 0.388, blue: 0.922)
    private let avatarPurple = Color(red: 0.486, green: 0.227, blue: 0.929)
    private let errorRed = Color(red: 0.973, green: 0.318, blue: 0.286)

    private func userBubble(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 60)

            MarkdownText(text, color: .white, fontSize: 13, useSystemFont: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    BubbleShape(isUser: true)
                        .fill(self.bubbleBlue),
                )
        }
    }

    private func assistantBubble(@ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("C")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(self.avatarPurple))

            content()
                .frame(maxWidth: 600, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    BubbleShape(isUser: false)
                        .fill(Color.white.opacity(0.04)),
                )

            Spacer(minLength: 40)
        }
    }
}

// MARK: - BubbleShape

private struct BubbleShape: Shape {
    let isUser: Bool

    func path(in rect: CGRect) -> Path {
        if self.isUser {
            Path(
                roundedRect: rect,
                cornerRadii: RectangleCornerRadii(
                    topLeading: 16,
                    bottomLeading: 16,
                    bottomTrailing: 4,
                    topTrailing: 16,
                ),
            )
        } else {
            Path(
                roundedRect: rect,
                cornerRadii: RectangleCornerRadii(
                    topLeading: 4,
                    bottomLeading: 16,
                    bottomTrailing: 16,
                    topTrailing: 16,
                ),
            )
        }
    }
}

//
//  ThinkingBlockView.swift
//  ClaudeIsland
//
//  Collapsed thinking block with expand toggle
//

import SwiftUI

struct ThinkingBlockView: View {
    // MARK: Internal

    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    self.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(.white.opacity(0.2))
                        .rotationEffect(.degrees(self.isExpanded ? 90 : 0))

                    Text("Thinking...")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.25))
                        .italic()

                    Spacer()
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if self.isExpanded {
                Text(self.text)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.3))
                    .italic()
                    .lineSpacing(2)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                    .padding(.leading, 15)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color.white.opacity(0.03))
        .cornerRadius(4)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Private

    @State private var isExpanded = false
}

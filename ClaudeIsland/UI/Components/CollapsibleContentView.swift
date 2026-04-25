//
//  CollapsibleContentView.swift
//  ClaudeIsland
//
//  Height-capped content with gradient fade and expand link
//

import SwiftUI

struct CollapsibleContentView<Content: View>: View {
    // MARK: Lifecycle

    init(
        lineCount: Int? = nil,
        expandLabel: String? = nil,
        backgroundColor: Color = Color(red: 0.086, green: 0.106, blue: 0.133),
        maxHeight: CGFloat = 120,
        @ViewBuilder content: () -> Content,
    ) {
        self.lineCount = lineCount
        self.expandLabel = expandLabel
        self.backgroundColor = backgroundColor
        self.maxHeight = maxHeight
        self.content = content()
    }

    // MARK: Internal

    var body: some View {
        if self.isExpanded {
            self.content
        } else {
            ZStack(alignment: .bottom) {
                self.content
                    .frame(maxHeight: self.maxHeight, alignment: .top)
                    .clipped()

                LinearGradient(
                    colors: [self.backgroundColor.opacity(0), self.backgroundColor],
                    startPoint: .top,
                    endPoint: .bottom,
                )
                .frame(height: 40)

                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        self.isExpanded = true
                    }
                } label: {
                    Text(self.resolvedLabel)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Color(red: 0.345, green: 0.651, blue: 1.0))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(self.backgroundColor)
                        .cornerRadius(3)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(Color(red: 0.345, green: 0.651, blue: 1.0).opacity(0.2), lineWidth: 1),
                        )
                }
                .buttonStyle(.plain)
                .padding(.bottom, 4)
            }
        }
    }

    // MARK: Private

    @State private var isExpanded = false

    private let lineCount: Int?
    private let expandLabel: String?
    private let backgroundColor: Color
    private let maxHeight: CGFloat
    private let content: Content

    private var resolvedLabel: String {
        if let expandLabel {
            return expandLabel
        }
        if let lineCount {
            return "Show all \(lineCount) lines"
        }
        return "Show full output"
    }
}

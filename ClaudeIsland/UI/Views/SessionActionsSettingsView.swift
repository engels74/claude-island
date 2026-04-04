//
//  SessionActionsSettingsView.swift
//  ClaudeIsland
//
//  Customizable session action order settings
//

import SwiftUI

// MARK: - SessionActionsSettingsView

struct SessionActionsSettingsView: View {
    // MARK: Internal

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    self.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "hand.tap")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(self.isHovered || self.isExpanded ? 1.0 : 0.7))
                        .frame(width: 16)

                    Text("Session Actions")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(self.isHovered || self.isExpanded ? 1.0 : 0.7))

                    Spacer()

                    Image(systemName: self.isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.4))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(self.isHovered || self.isExpanded ? Color.white.opacity(0.08) : Color.clear),
                )
            }
            .buttonStyle(.plain)
            .onHover { self.isHovered = $0 }

            if self.isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Top 3 are visible buttons, rest in overflow menu")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.3))
                        .padding(.leading, 4)
                        .padding(.bottom, 4)

                    ForEach(Array(self.actionOrder.enumerated()), id: \.element) { index, action in
                        HStack(spacing: 8) {
                            Image(systemName: self.iconForAction(action))
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.5))
                                .frame(width: 14)

                            Text(self.labelForAction(action))
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.8))

                            Spacer()

                            Text(index < 3 ? "Visible" : "Overflow")
                                .font(.system(size: 10))
                                .foregroundColor(index < 3 ? .green.opacity(0.6) : .white.opacity(0.3))

                            VStack(spacing: 2) {
                                if index > 0 {
                                    Button {
                                        self.moveUp(index)
                                    } label: {
                                        Image(systemName: "chevron.up")
                                            .font(.system(size: 8))
                                            .foregroundColor(.white.opacity(0.4))
                                    }
                                    .buttonStyle(.plain)
                                }
                                if index < self.actionOrder.count - 1 {
                                    Button {
                                        self.moveDown(index)
                                    } label: {
                                        Image(systemName: "chevron.down")
                                            .font(.system(size: 8))
                                            .foregroundColor(.white.opacity(0.4))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(index < 3 ? Color.white.opacity(0.04) : Color.clear),
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: Private

    @State private var isExpanded = false
    @State private var isHovered = false
    @State private var actionOrder: [SessionActionType] = AppSettings.sessionActionOrder

    private func moveUp(_ index: Int) {
        guard index > 0 else { return }
        self.actionOrder.swapAt(index, index - 1)
        AppSettings.sessionActionOrder = self.actionOrder
    }

    private func moveDown(_ index: Int) {
        guard index < self.actionOrder.count - 1 else { return }
        self.actionOrder.swapAt(index, index + 1)
        AppSettings.sessionActionOrder = self.actionOrder
    }

    private func iconForAction(_ action: SessionActionType) -> String {
        switch action {
        case .chat: "bubble.left"
        case .focus: "terminal"
        case .archive: "archivebox"
        case .copyAttach: "doc.on.clipboard"
        case .delete: "trash"
        case .pinProject: "star"
        case .assignShortcut: "keyboard"
        }
    }

    private func labelForAction(_ action: SessionActionType) -> String {
        switch action {
        case .chat: "Chat"
        case .focus: "Focus"
        case .archive: "Archive"
        case .copyAttach: "Copy Attach"
        case .delete: "Delete"
        case .pinProject: "Pin Project"
        case .assignShortcut: "Assign Shortcut"
        }
    }
}

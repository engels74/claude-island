//
//  InstanceRow.swift
//  ClaudeIsland
//
//  A single session row in the instances list.
//

import AppKit
import SwiftUI

// MARK: - InstanceRow

struct InstanceRow: View {
    // MARK: Internal

    let session: SessionState
    let onFocus: () -> Void
    let onChat: () -> Void
    let onArchive: () -> Void
    let onApprove: () -> Void
    let onReject: () -> Void
    var onOverflow: (() -> Void)?
    var onCancel: (() -> Void)?
    var onRetry: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onDelete: (() -> Void)?
    var onAssignShortcut: (() -> Void)?
    var visibleActions: [SessionActionType] = [.chat, .focus, .archive]

    var body: some View {
        VStack(spacing: 0) {
            self.mainRow

            if self.isEditing {
                SessionLabelEditor(sessionID: self.session.sessionID)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: self.isEditing)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(self.isHovered ? Color.white.opacity(0.06) : Color.clear),
        )
        .onHover { self.isHovered = $0 }
        .onRightClick {
            withAnimation {
                if !self.isEditing {
                    self.editingName = self.displayTitle
                }
                self.isEditing.toggle()
            }
        }
        .onChange(of: self.isEditing) { _, newValue in
            if !newValue {
                self.saveName()
            }
        }
    }

    // MARK: Private

    @State private var isHovered = false
    @State private var isEditing = false
    @State private var editingName = ""
    @FocusState private var isTitleFocused: Bool

    private let metadataManager = SessionMetadataManager.shared
    private let claudeOrange = Color(red: 0.85, green: 0.47, blue: 0.34)
    private let spinnerSymbols = ["·", "✢", "✳", "∗", "✻", "✽"]

    private var displayTitle: String {
        self.metadataManager.name(for: self.session.sessionID) ?? self.session.displayTitle
    }

    private var isWaitingForApproval: Bool {
        self.session.phase.isWaitingForApproval
    }

    private var isInteractiveTool: Bool {
        guard let toolName = self.session.pendingToolName else { return false }
        return toolName == "AskUserQuestion"
    }

    private var phaseStatusText: String {
        switch self.session.phase {
        case .processing: "Processing..."
        case .compacting: "Compacting..."
        case .waitingForInput: "Ready"
        case .waitingForApproval: "Waiting for approval"
        case .idle: "Idle"
        case .ended: "Ended"
        }
    }

    private var mainRow: some View {
        HStack(spacing: 0) {
            if let color = self.metadataManager.color(for: self.session.sessionID) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color)
                    .frame(width: 3)
                    .padding(.vertical, 4)
            }

            HStack(alignment: .center, spacing: 10) {
                self.stateIndicator
                    .frame(width: 14)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if self.isEditing {
                            TextField("Session name", text: self.$editingName)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white)
                                .focused(self.$isTitleFocused)
                                .onSubmit {
                                    withAnimation { self.isEditing = false }
                                }
                                .onAppear { self.isTitleFocused = true }
                        } else {
                            Text(self.displayTitle)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white)
                                .lineLimit(1)
                        }

                        if let usage = self.session.usage {
                            Text(usage.formattedTotal)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(.white.opacity(0.4))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.white.opacity(0.08))
                                .clipShape(Capsule())
                        }
                    }

                    InstanceRowSubtitle(
                        session: self.session,
                        isWaitingForApproval: self.isWaitingForApproval,
                        isInteractiveTool: self.isInteractiveTool,
                        phaseStatusText: self.phaseStatusText,
                    )
                }

                Spacer(minLength: 0)

                self.actionButtons
            }
            .padding(.leading, self.metadataManager.color(for: self.session.sessionID) != nil ? 4 : 8)
            .padding(.trailing, 14)
            .padding(.vertical, 10)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !self.isEditing { self.onChat() }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: self.isWaitingForApproval)
    }

    @ViewBuilder private var actionButtons: some View {
        if self.isWaitingForApproval && self.isInteractiveTool {
            HStack(spacing: 8) {
                IconButton(icon: "bubble.left") { self.onChat() }
                    .accessibilityLabel("Open chat")
                if self.session.pid != nil {
                    TerminalButton(isEnabled: true) { self.onFocus() }
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        } else if self.isWaitingForApproval {
            InlineApprovalButtons(
                onChat: self.onChat,
                onApprove: self.onApprove,
                onReject: self.onReject,
            )
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        } else {
            HStack(spacing: 8) {
                ForEach(self.visibleActions, id: \.self) { action in
                    self.visibleActionButton(action)
                }
                IconButton(icon: "ellipsis") { self.onOverflow?() }
                    .accessibilityLabel("More actions")
            }
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }

    @ViewBuilder private var stateIndicator: some View {
        switch self.session.phase {
        case .processing,
             .compacting:
            TimelineView(.periodic(from: .now, by: 0.15)) { context in
                let phase = Int(context.date.timeIntervalSinceReferenceDate / 0.15) % self.spinnerSymbols.count
                Text(self.spinnerSymbols[phase])
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(self.claudeOrange)
            }
        case .waitingForApproval:
            TimelineView(.periodic(from: .now, by: 0.15)) { context in
                let phase = Int(context.date.timeIntervalSinceReferenceDate / 0.15) % self.spinnerSymbols.count
                Text(self.spinnerSymbols[phase])
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(TerminalColors.amber)
            }
        case .waitingForInput:
            Circle()
                .fill(TerminalColors.green)
                .frame(width: 6, height: 6)
        case .idle,
             .ended:
            Circle()
                .fill(Color.white.opacity(0.2))
                .frame(width: 6, height: 6)
        }
    }

    @ViewBuilder
    private func visibleActionButton(_ action: SessionActionType) -> some View {
        switch action {
        case .chat:
            IconButton(icon: "bubble.left") { self.onChat() }
                .accessibilityLabel("Open chat")
        case .focus:
            if self.session.pid != nil {
                IconButton(icon: "terminal") { self.onFocus() }
                    .accessibilityLabel("Focus terminal")
            }
        case .archive:
            if self.session.phase == .idle || self.session.phase == .waitingForInput {
                IconButton(icon: "archivebox") { self.onArchive() }
                    .accessibilityLabel("Archive session")
            }
        case .copyAttach:
            EmptyView()
        case .delete:
            if self.session.isInTmux {
                IconButton(icon: "trash") { self.onDelete?() }
                    .accessibilityLabel("Delete session")
            }
        case .pinProject:
            IconButton(icon: "star") {
                ProjectStore.shared.addPinned(path: self.session.cwd)
            }
            .accessibilityLabel("Pin project")
        case .assignShortcut:
            IconButton(icon: "keyboard") { self.onAssignShortcut?() }
                .accessibilityLabel("Assign shortcut")
        }
    }

    private func saveName() {
        let trimmed = self.editingName.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == self.session.displayTitle {
            self.metadataManager.setName(nil, for: self.session.sessionID)
        } else {
            self.metadataManager.setName(trimmed, for: self.session.sessionID)
        }
    }
}

// MARK: - InstanceRowSubtitle

private struct InstanceRowSubtitle: View {
    // MARK: Internal

    let session: SessionState
    let isWaitingForApproval: Bool
    let isInteractiveTool: Bool
    let phaseStatusText: String

    var body: some View {
        if self.isWaitingForApproval, let toolName = self.session.pendingToolName {
            HStack(spacing: 4) {
                Text(MCPToolFormatter.formatToolName(toolName))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(TerminalColors.amber.opacity(0.9))
                if self.isInteractiveTool {
                    Text("Needs your input")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(1)
                } else if let input = self.session.pendingToolInput {
                    Text(input)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }
        } else if let role = self.session.lastMessageRole {
            self.roleSubtitle(role: role)
        } else if let lastMsg = self.session.lastMessage {
            Text(lastMsg)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.4))
                .lineLimit(1)
        } else {
            Text(self.phaseStatusText)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.4))
        }
    }

    // MARK: Private

    @ViewBuilder
    private func roleSubtitle(role: String) -> some View {
        switch role {
        case "tool":
            HStack(spacing: 4) {
                if let toolName = self.session.lastToolName {
                    Text(MCPToolFormatter.formatToolName(toolName))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.5))
                }
                if let input = self.session.lastMessage {
                    Text(input)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                        .lineLimit(1)
                }
            }
        case "user":
            HStack(spacing: 4) {
                Text("You:")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
                if let msg = self.session.lastMessage {
                    Text(msg)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                        .lineLimit(1)
                }
            }
        default:
            if let msg = self.session.lastMessage {
                Text(msg)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
                    .lineLimit(1)
            }
        }
    }
}

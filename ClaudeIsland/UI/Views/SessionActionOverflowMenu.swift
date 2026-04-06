//
//  SessionActionOverflowMenu.swift
//  ClaudeIsland
//
//  Overlay dropdown for session row overflow actions
//

import AppKit
import SwiftUI

// MARK: - SessionActionOverflowMenu

struct SessionActionOverflowMenu: View {
    // MARK: Internal

    let session: SessionState
    let actions: [SessionActionType]
    let onChat: () -> Void
    let onFocus: () -> Void
    let onArchive: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(self.actions, id: \.self) { action in
                if self.isActionAvailable(action) {
                    self.actionRow(action)
                }
            }
        }
        .padding(6)
        .frame(minWidth: 180)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.9))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.5),
                ),
        )
        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
    }

    // MARK: Private

    @State private var confirmingDelete = false
    @State private var showCopied = false

    private var copyAttachRow: some View {
        OverflowMenuButton(
            icon: self.showCopied ? "checkmark" : "doc.on.clipboard",
            label: self.showCopied ? "Copied!" : "Copy Attach",
        ) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(self.session.sessionID, forType: .string)
            self.showCopied = true
            Task(name: "copy-feedback") {
                try? await Task.sleep(for: .seconds(1.5))
                self.showCopied = false
                self.onDismiss()
            }
        }
    }

    private var deleteRow: some View {
        Group {
            if self.confirmingDelete {
                HStack(spacing: 6) {
                    Text("Delete session?")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.6))

                    Spacer()

                    Button("Delete") {
                        Task(name: "delete-session") {
                            await SessionStore.shared.process(.sessionEnded(sessionID: self.session.sessionID))
                        }
                        self.onDismiss()
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.red)
                    .buttonStyle(.plain)
                    .accessibilityLabel("Confirm delete session")

                    Button("Cancel") {
                        self.confirmingDelete = false
                    }
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cancel delete")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            } else {
                OverflowMenuButton(icon: "trash", label: "Delete", isDestructive: true) {
                    self.confirmingDelete = true
                }
            }
        }
    }

    @ViewBuilder
    private func actionRow(_ action: SessionActionType) -> some View {
        switch action {
        case .chat:
            self.menuButton(icon: "bubble.left", label: "Chat") {
                self.onChat()
                self.onDismiss()
            }
        case .focus:
            self.menuButton(icon: "terminal", label: "Focus Terminal") {
                self.onFocus()
                self.onDismiss()
            }
        case .archive:
            self.menuButton(icon: "archivebox", label: "Archive") {
                self.onArchive()
                self.onDismiss()
            }
        case .copyAttach:
            self.copyAttachRow
        case .delete:
            self.deleteRow
        case .pinProject:
            self.menuButton(icon: "star", label: "Pin Project") {
                ProjectStore.shared.addPinned(path: self.session.cwd)
                self.onDismiss()
            }
        case .assignShortcut:
            self.menuButton(icon: "keyboard", label: "Assign Shortcut") { self.onDismiss() }
        }
    }

    private func menuButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        OverflowMenuButton(icon: icon, label: label, action: action)
    }

    private func isActionAvailable(_ action: SessionActionType) -> Bool {
        switch action {
        case .chat: true
        case .focus: self.session.pid != nil
        case .archive: self.session.phase == .idle || self.session.phase == .waitingForInput
        case .copyAttach: self.session.isInTmux
        case .delete: self.session.isInTmux
        case .pinProject: true
        case .assignShortcut: true
        }
    }
}

// MARK: - OverflowMenuButton

private struct OverflowMenuButton: View {
    // MARK: Internal

    let icon: String
    let label: String
    var isDestructive = false
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            HStack(spacing: 8) {
                Image(systemName: self.icon)
                    .font(.system(size: 11))
                    .foregroundColor(self.isDestructive ? .red.opacity(0.8) : .white.opacity(0.6))
                    .frame(width: 14)

                Text(self.label)
                    .font(.system(size: 12))
                    .foregroundColor(self.isDestructive ? .red.opacity(0.8) : .white.opacity(0.8))

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(self.isHovered ? Color.white.opacity(0.08) : Color.clear),
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(self.label)
        .onHover { self.isHovered = $0 }
    }

    // MARK: Private

    @State private var isHovered = false
}

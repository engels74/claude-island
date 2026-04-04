//
//  ShortcutsSettingsView.swift
//  ClaudeIsland
//
//  Shortcuts settings section for NotchMenuView
//

import SwiftUI

// MARK: - ShortcutsSettingsView

struct ShortcutsSettingsView: View {
    // MARK: Internal

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    self.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(self.isHovered || self.isExpanded ? 1.0 : 0.7))
                        .frame(width: 16)

                    Text("Shortcuts")
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
                VStack(alignment: .leading, spacing: 12) {
                    if AccessibilityPermissionManager.shared.shouldShowPermissionWarning {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 10))
                                .foregroundColor(TerminalColors.amber)
                            Text("Accessibility permission required for shortcuts")
                                .font(.system(size: 11))
                                .foregroundColor(TerminalColors.amber.opacity(0.8))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    }
                    self.globalSection
                    self.sessionsSection
                }
                .padding(.leading, 12)
                .padding(.trailing, 12)
                .padding(.vertical, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .onAppear { HotkeyManager.shared.verifyTapHealth() }
            }
        }
    }

    // MARK: Private

    @State private var isExpanded = false
    @State private var isHovered = false
    @State private var globalCombo: KeyCombo? = AppSettings.globalShortcut

    private var hotkeyManager = HotkeyManager.shared

    // MARK: - Global Section

    private var globalSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Global")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.4))
                .padding(.leading, 4)

            HStack {
                Text("New Session")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.7))

                Spacer()

                KeyRecorderView(combo: self.$globalCombo) { newCombo in
                    if let newCombo {
                        self.hotkeyManager.register(combo: newCombo, action: .openLauncher)
                    } else if let old = AppSettings.globalShortcut {
                        self.hotkeyManager.unregister(combo: old)
                    }
                }
            }
            .padding(.horizontal, 8)

            Text("Opens the session launcher from anywhere")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.3))
                .padding(.leading, 8)
        }
    }

    // MARK: - Sessions Section

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sessions")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.4))
                .padding(.leading, 4)

            let sessionBindings = self.hotkeyManager.allBindings().filter {
                if case .focusSession = $0.action { return true }
                return false
            }

            if sessionBindings.isEmpty {
                Text("No session shortcuts assigned")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.3))
                    .padding(.leading, 8)
                    .padding(.vertical, 4)

                Text("Use the ... menu on a session row to assign shortcuts")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.25))
                    .padding(.leading, 8)
            } else {
                ForEach(sessionBindings, id: \.combo) { binding in
                    if case let .focusSession(sessionID) = binding.action {
                        SessionShortcutRow(
                            sessionID: sessionID,
                            combo: binding.combo,
                            hotkeyManager: self.hotkeyManager,
                        )
                    }
                }
            }
        }
    }
}

// MARK: - SessionShortcutRow

private struct SessionShortcutRow: View {
    // MARK: Internal

    let sessionID: String
    var combo: KeyCombo
    var hotkeyManager: HotkeyManager

    var body: some View {
        HStack {
            Text(self.sessionID.prefix(8) + "...")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.7))
                .lineLimit(1)

            Spacer()

            KeyRecorderView(combo: self.$currentCombo) { newCombo in
                self.hotkeyManager.unregister(combo: self.combo)
                if let newCombo {
                    self.hotkeyManager.register(combo: newCombo, action: .focusSession(sessionID: self.sessionID))
                }
            }
        }
        .padding(.horizontal, 8)
        .onAppear {
            self.currentCombo = self.combo
        }
    }

    // MARK: Private

    @State private var currentCombo: KeyCombo?
}

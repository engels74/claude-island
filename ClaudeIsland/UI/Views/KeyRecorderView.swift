//
//  KeyRecorderView.swift
//  ClaudeIsland
//
//  Reusable keyboard shortcut recorder
//

import AppKit
import SwiftUI

// MARK: - KeyRecorderView

struct KeyRecorderView: View {
    // MARK: Internal

    @Binding var combo: KeyCombo?

    var onChanged: ((KeyCombo?) -> Void)?

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 4) {
                Button {
                    self.isRecording.toggle()
                } label: {
                    HStack(spacing: 4) {
                        if self.isRecording {
                            Text("Press keys...")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.6))
                        } else if let combo {
                            Text(combo.displayString)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white.opacity(0.8))
                        } else {
                            Text("Record...")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.3))
                        }
                    }
                    .frame(minWidth: 80)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(0.08))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(
                                        self.isRecording
                                            ? Color.blue.opacity(0.6)
                                            : (self.showReserved ? Color.red.opacity(0.6) : Color.clear),
                                        lineWidth: 1.5,
                                    ),
                            ),
                    )
                }
                .buttonStyle(.plain)

                if self.combo != nil {
                    Button {
                        self.combo = nil
                        self.onChanged?(nil)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
            }

            if let conflictMessage {
                Text(conflictMessage)
                    .font(.system(size: 10))
                    .foregroundColor(.orange.opacity(0.8))
            }
        }
        .onChange(of: self.isRecording) { _, newValue in
            if newValue {
                self.installMonitor()
            } else {
                self.removeMonitor()
            }
        }
        .onDisappear {
            self.removeMonitor()
        }
    }

    // MARK: Private

    private static let reservedCombos: Set<KeyCombo> = {
        let cmd = NSEvent.ModifierFlags.command.rawValue
        let cmdShift = NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.shift.rawValue
        let ctrl = NSEvent.ModifierFlags.control.rawValue

        return [
            KeyCombo(keyCode: 12, modifiers: cmd),
            KeyCombo(keyCode: 4, modifiers: cmd),
            KeyCombo(keyCode: 46, modifiers: cmd),
            KeyCombo(keyCode: 49, modifiers: cmd),
            KeyCombo(keyCode: 13, modifiers: cmd),
            KeyCombo(keyCode: 8, modifiers: cmd),
            KeyCombo(keyCode: 9, modifiers: cmd),
            KeyCombo(keyCode: 7, modifiers: cmd),
            KeyCombo(keyCode: 0, modifiers: cmd),
            KeyCombo(keyCode: 6, modifiers: cmd),
            KeyCombo(keyCode: 6, modifiers: cmdShift),
            KeyCombo(keyCode: 45, modifiers: cmd),
            KeyCombo(keyCode: 12, modifiers: cmdShift),
            KeyCombo(keyCode: 126, modifiers: ctrl),
            KeyCombo(keyCode: 125, modifiers: ctrl),
            KeyCombo(keyCode: 123, modifiers: ctrl),
            KeyCombo(keyCode: 124, modifiers: ctrl),
            KeyCombo(keyCode: 48, modifiers: cmd),   // Cmd+Tab
            KeyCombo(keyCode: 50, modifiers: cmd),   // Cmd+`
        ]
    }()

    @State private var isRecording = false
    @State private var showReserved = false
    @State private var conflictMessage: String?
    @State private var monitor: Any?

    // MARK: - Event Monitor

    private func installMonitor() {
        self.removeMonitor()

        self.monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .keyDown {
                self.handleKeyDown(event)
                return nil
            }
            return event
        }
    }

    private func removeMonitor() {
        if let monitor = self.monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        let keyCode = event.keyCode

        if keyCode == 53 {
            self.isRecording = false
            return
        }

        let rawModifiers = event.modifierFlags.rawValue
            & (NSEvent.ModifierFlags.command.rawValue
                | NSEvent.ModifierFlags.shift.rawValue
                | NSEvent.ModifierFlags.control.rawValue
                | NSEvent.ModifierFlags.option.rawValue)

        let newCombo = KeyCombo(keyCode: keyCode, modifiers: rawModifiers)

        guard newCombo.hasModifier else { return }

        if Self.reservedCombos.contains(newCombo) {
            self.showReserved = true
            Task(name: "reserved-feedback") {
                try? await Task.sleep(for: .seconds(1.0))
                self.showReserved = false
            }
            return
        }

        let isConflict = HotkeyManager.shared.allBindings().contains { $0.combo == newCombo }
        if isConflict {
            self.conflictMessage = "Already in use"
            Task(name: "conflict-feedback") {
                try? await Task.sleep(for: .seconds(2.0))
                self.conflictMessage = nil
            }
            return
        }

        self.combo = newCombo
        self.onChanged?(newCombo)
        self.isRecording = false
    }
}

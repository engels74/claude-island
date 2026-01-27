//
//  SessionLabelEditor.swift
//  ClaudeIsland
//
//  Inline editor for session color and name customization
//

import SwiftUI

struct SessionLabelEditor: View {
    let sessionID: String

    static let colorPresets: [(color: Color, hex: String)] = [
        (Color(red: 0.94, green: 0.27, blue: 0.27), "EF4444"), // red
        (Color(red: 0.98, green: 0.45, blue: 0.09), "F97316"), // orange
        (Color(red: 0.92, green: 0.70, blue: 0.03), "EAB308"), // yellow
        (Color(red: 0.13, green: 0.77, blue: 0.37), "22C55E"), // green
        (Color(red: 0.23, green: 0.51, blue: 0.96), "3B82F6"), // blue
        (Color(red: 0.55, green: 0.36, blue: 0.96), "8B5CF6"), // purple
        (Color(red: 0.93, green: 0.29, blue: 0.60), "EC4899"), // pink
    ]

    private let metadataManager = SessionMetadataManager.shared

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(Self.colorPresets.enumerated()), id: \.offset) { _, preset in
                colorDot(preset.color, hex: preset.hex)
            }

            Spacer()

            clearButton
        }
    }

    private func colorDot(_ color: Color, hex: String) -> some View {
        let currentHex = metadataManager.sessionColors[sessionID]
        let isSelected = currentHex == hex

        return Button {
            metadataManager.setColor(hex, for: sessionID)
        } label: {
            Circle()
                .fill(color)
                .frame(width: 18, height: 18)
                .overlay(
                    Circle()
                        .stroke(Color.white, lineWidth: isSelected ? 2 : 0)
                )
        }
        .buttonStyle(.plain)
    }

    private var clearButton: some View {
        Button {
            metadataManager.setColor(nil, for: sessionID)
        } label: {
            Circle()
                .stroke(Color.white.opacity(0.3), lineWidth: 1)
                .frame(width: 18, height: 18)
                .overlay(
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.4))
                )
        }
        .buttonStyle(.plain)
    }
}

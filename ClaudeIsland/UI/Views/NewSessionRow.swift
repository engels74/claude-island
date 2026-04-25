//
//  NewSessionRow.swift
//  ClaudeIsland
//
//  Dashed "New Session" row for the instances list
//

import SwiftUI

struct NewSessionRow: View {
    // MARK: Internal

    let onTap: () -> Void

    var body: some View {
        Button(action: self.onTap) {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
                    .frame(width: 14)

                Text("New Session")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        Color.white.opacity(self.isHovered ? 0.4 : 0.2),
                        style: StrokeStyle(lineWidth: 1, dash: [6, 4]),
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(self.isHovered ? Color.white.opacity(0.04) : Color.clear),
                    ),
            )
        }
        .buttonStyle(.plain)
        .onHover { self.isHovered = $0 }
    }

    // MARK: Private

    @State private var isHovered = false
}

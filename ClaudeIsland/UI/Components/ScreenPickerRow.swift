//
//  ScreenPickerRow.swift
//  ClaudeIsland
//
//  Screen selection picker for settings menu
//

import SwiftUI

// MARK: - ScreenPickerRow

struct ScreenPickerRow: View {
    // MARK: Internal

    /// ScreenSelector is @Observable, so SwiftUI automatically tracks property access
    var screenSelector: ScreenSelector

    var body: some View {
        VStack(spacing: 0) {
            // Main row - shows current selection
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    setExpanded(!isExpanded)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "display")
                        .font(.system(size: 12))
                        .foregroundColor(textColor)
                        .frame(width: 16)

                    Text("Screen")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(textColor)

                    Spacer()

                    Text(currentSelectionLabel)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                        .lineLimit(1)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isHovered ? Color.white.opacity(0.08) : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }

            // Expanded screen list
            if isExpanded {
                VStack(spacing: 2) {
                    // Automatic option
                    ScreenOptionRow(
                        label: "Automatic",
                        sublabel: "Built-in or Main",
                        isSelected: screenSelector.selectionMode == .automatic
                    ) {
                        screenSelector.selectAutomatic()
                        triggerWindowRecreation()
                        collapseAfterDelay()
                    }

                    // Individual screens
                    ForEach(screenSelector.availableScreens, id: \.self) { screen in
                        ScreenOptionRow(
                            label: screen.localizedName,
                            sublabel: screenSublabel(for: screen),
                            isSelected: screenSelector.selectionMode == .specificScreen &&
                                screenSelector.isSelected(screen)
                        ) {
                            screenSelector.selectScreen(screen)
                            triggerWindowRecreation()
                            collapseAfterDelay()
                        }
                    }
                }
                .padding(.leading, 28)
                .padding(.top, 4)
            }
        }
    }

    // MARK: Private

    @State private var isHovered = false
    @State private var collapseTask: Task<Void, Never>?

    private var isExpanded: Bool { screenSelector.isPickerExpanded }

    private var currentSelectionLabel: String {
        switch screenSelector.selectionMode {
        case .automatic:
            return "Auto"
        case .specificScreen:
            if let screen = screenSelector.selectedScreen {
                return screen.localizedName
            }
            return "Auto"
        }
    }

    private var textColor: Color {
        .white.opacity(isHovered ? 1.0 : 0.7)
    }

    private func setExpanded(_ value: Bool) {
        screenSelector.isPickerExpanded = value
    }

    private func screenSublabel(for screen: NSScreen) -> String? {
        var parts: [String] = []
        if screen.isBuiltinDisplay {
            parts.append("Built-in")
        }
        if screen == NSScreen.main {
            parts.append("Main")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private func triggerWindowRecreation() {
        // Notify to recreate the window
        NotificationCenter.default.post(
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    private func collapseAfterDelay() {
        collapseTask?.cancel()
        collapseTask = Task {
            try? await Task.sleep(for: .seconds(0.3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                setExpanded(false)
            }
        }
    }
}

// MARK: - ScreenOptionRow

private struct ScreenOptionRow: View {
    // MARK: Internal

    let label: String
    let sublabel: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isSelected ? TerminalColors.green : Color.white.opacity(0.2))
                    .frame(width: 6, height: 6)

                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(isHovered ? 1.0 : 0.7))

                    if let sublabel {
                        Text(sublabel)
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.4))
                    }
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(TerminalColors.green)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.white.opacity(0.06) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    // MARK: Private

    @State private var isHovered = false
}

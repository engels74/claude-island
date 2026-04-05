//
//  SessionLauncherView.swift
//  ClaudeIsland
//
//  Raycast-style session launcher with progressive disclosure
//

import SwiftUI

struct SessionLauncherView: View {
    // MARK: Internal

    let onSubmit: (String, String, String) -> Void
    let onDismiss: () -> Void
    var onSizeChange: ((CGSize) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            // Prompt
            self.promptField
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)

            // Session name (hidden by default)
            if self.showNameField {
                self.nameField
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Divider
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)
                .padding(.horizontal, 16)

            // Directory row
            self.directoryRow
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            // Directory picker dropdown (inline, grows panel)
            if self.isDropdownOpen {
                DirectoryPickerView(
                    selectedPath: self.$selectedDirectory,
                    onSelect: {
                        withAnimation(.easeOut(duration: 0.15)) {
                            self.isDropdownOpen = false
                        }
                    },
                    onBrowse: { self.openBrowser() },
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Bottom bar
            self.bottomBar
        }
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            GeometryReader { geometry in
                Color.clear
                    .preference(key: SizePreferenceKey.self, value: geometry.size)
            },
        )
        .onPreferenceChange(SizePreferenceKey.self) { size in
            self.onSizeChange?(size)
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: self.showNameField)
        .animation(.spring(response: 0.2, dampingFraction: 0.85), value: self.isDropdownOpen)
        .onAppear {
            Task(name: "focus-launcher-prompt") {
                try? await Task.sleep(for: .seconds(0.15))
                guard !Task.isCancelled else { return }
                self.focusedField = .prompt
            }
        }
        .onKeyPress(.escape) {
            if self.isDropdownOpen {
                withAnimation { self.isDropdownOpen = false }
                return .handled
            }
            if self.showNameField, self.focusedField == .name {
                withAnimation { self.showNameField = false }
                self.focusedField = .prompt
                return .handled
            }
            self.onDismiss()
            return .handled
        }
    }

    // MARK: Private

    private enum Field: Hashable {
        case prompt
        case name
    }

    @State private var prompt = ""
    @State private var sessionName = ""
    @State private var selectedDirectory: String = AppSettings.lastUsedDirectory
        ?? ProjectStore.shared.pinnedProjects.first?.path
        ?? FileManager.default.homeDirectoryForCurrentUser.path
    @State private var showNameField = false
    @State private var isDropdownOpen = false
    @FocusState private var focusedField: Field?

    private let accentBlue = Color(red: 0.04, green: 0.52, blue: 1.0)

    private var resolvedSessionName: String {
        if !self.sessionName.isEmpty {
            return self.sessionName
        }
        if !self.prompt.isEmpty {
            return String(self.prompt.prefix(30))
                .lowercased()
                .replacingOccurrences(of: " ", with: "-")
                .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return "claude-\(formatter.string(from: Date()))"
    }

    private var resolvedCommand: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dateStr = formatter.string(from: Date())

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH-mm"
        let timeStr = timeFormatter.string(from: Date())

        return AppSettings.claudeCommandTemplate
            .replacingOccurrences(of: "{{name}}", with: self.resolvedSessionName)
            .replacingOccurrences(of: "{{date}}", with: dateStr)
            .replacingOccurrences(of: "{{time}}", with: timeStr)
            .replacingOccurrences(of: "{{dir}}", with: self.selectedDirectory)
    }

    private var hasCustomTemplate: Bool {
        AppSettings.claudeCommandTemplate.contains("{{")
    }

    private var selectedProjectName: String {
        URL(fileURLWithPath: self.selectedDirectory).lastPathComponent
    }

    private var selectedProjectIsPinned: Bool {
        ProjectStore.shared.pinnedProjects.contains { $0.path == self.selectedDirectory }
    }

    private var hintText: String {
        if self.isDropdownOpen {
            return "\u{2191}\u{2193} navigate \u{00B7} \u{23CE} select \u{00B7} Esc close"
        }
        if self.focusedField == .name {
            return "\u{23CE} launch \u{00B7} Esc cancel"
        }
        return "Tab: session name \u{00B7} \u{23CE} launch \u{00B7} Esc cancel"
    }

    // MARK: - Prompt Field

    private var promptField: some View {
        TextField("What should Claude do?", text: self.$prompt, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 15))
            .foregroundColor(.white)
            .focused(self.$focusedField, equals: .prompt)
            .lineLimit(1 ... 5)
            .onKeyPress(.return, phases: .down) { keyPress in
                if keyPress.modifiers.contains(.shift) {
                    return .ignored
                }
                self.submit()
                return .handled
            }
            .onKeyPress(.tab, phases: .down) { _ in
                withAnimation {
                    self.showNameField = true
                }
                self.focusedField = .name
                return .handled
            }
            .padding(12)
            .background(Color.white.opacity(0.06))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        self.accentBlue.opacity(self.focusedField == .prompt ? 0.4 : 0),
                        lineWidth: 1.5,
                    ),
            )
            .animation(.easeInOut(duration: 0.15), value: self.focusedField)
    }

    // MARK: - Name Field

    private var nameField: some View {
        HStack(spacing: 8) {
            Text("AS")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.3))
                .tracking(0.5)

            TextField(self.resolvedSessionName, text: self.$sessionName)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .focused(self.$focusedField, equals: .name)
                .onSubmit { self.submit() }
                .padding(8)
                .background(Color.white.opacity(0.06))
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(
                            self.accentBlue.opacity(self.focusedField == .name ? 0.4 : 0),
                            lineWidth: 1.5,
                        ),
                )
                .animation(.easeInOut(duration: 0.15), value: self.focusedField)
        }
    }

    // MARK: - Directory Row

    private var directoryRow: some View {
        Button {
            withAnimation {
                self.isDropdownOpen.toggle()
            }
        } label: {
            HStack(spacing: 10) {
                Text("IN")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.3))
                    .tracking(0.5)

                Image(systemName: self.selectedProjectIsPinned ? "star.fill" : "clock")
                    .font(.system(size: 11))
                    .foregroundColor(self.selectedProjectIsPinned ? .yellow.opacity(0.7) : .white.opacity(0.4))

                Text(self.selectedProjectName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))

                Spacer()

                Image(systemName: self.isDropdownOpen ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.3))
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)

            VStack(spacing: 2) {
                if self.hasCustomTemplate {
                    Text(self.resolvedCommand)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.22))
                        .lineLimit(1)
                        .padding(.top, 6)

                    Text(self.hintText)
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.13))
                        .padding(.bottom, 6)
                } else {
                    Text(self.hintText)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.18))
                        .padding(.vertical, 7)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func submit() {
        let trimmedPrompt = self.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        self.onSubmit(trimmedPrompt, self.resolvedSessionName, self.selectedDirectory)
    }

    private func openBrowser() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: self.selectedDirectory)

        SessionLauncherPanel.shared.orderOut(nil)

        panel.begin { response in
            if response == .OK, let url = panel.url {
                self.selectedDirectory = url.path
                ProjectStore.shared.recordUsage(path: url.path)
            }
            SessionLauncherPanel.shared.makeKeyAndOrderFront(nil)
        }
    }
}

// MARK: - SizePreferenceKey

private struct SizePreferenceKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

//
//  SessionLauncherView.swift
//  ClaudeIsland
//
//  SwiftUI content for the session launcher panel
//

import SwiftUI

struct SessionLauncherView: View {
    // MARK: Internal

    let onSubmit: (String, String, String) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            self.promptField
            if self.showNameField {
                self.nameField
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            self.directoryPicker
            self.bottomBar
        }
        .padding(20)
        .frame(width: 500)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: self.showNameField)
        .onAppear {
            self.focusedField = .prompt
        }
    }

    // MARK: Private

    @State private var prompt = ""
    @State private var sessionName = ""
    @State private var selectedDirectory: String = AppSettings.lastUsedDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path
    @State private var showNameField = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case prompt
        case name
    }

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
        AppSettings.claudeCommandTemplate
            .replacingOccurrences(of: "{{name}}", with: self.resolvedSessionName)
            .replacingOccurrences(of: "{{dir}}", with: self.selectedDirectory)
    }

    private func submit() {
        let trimmedPrompt = self.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        self.onSubmit(trimmedPrompt, self.resolvedSessionName, self.selectedDirectory)
    }

    // MARK: - Prompt Field

    private var promptField: some View {
        ZStack(alignment: .topLeading) {
            if self.prompt.isEmpty {
                Text("What should Claude do?")
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(0.3))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 10)
            }

            TextEditor(text: self.$prompt)
                .font(.system(size: 15))
                .foregroundColor(.white)
                .scrollContentBackground(.hidden)
                .focused(self.$focusedField, equals: .prompt)
                .frame(minHeight: 40, maxHeight: 120)
                .fixedSize(horizontal: false, vertical: true)
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
        }
        .padding(8)
        .background(Color.white.opacity(0.08))
        .cornerRadius(8)
    }

    // MARK: - Name Field

    private var nameField: some View {
        TextField("Session name (optional)", text: self.$sessionName)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundColor(.white)
            .focused(self.$focusedField, equals: .name)
            .padding(10)
            .background(Color.white.opacity(0.06))
            .cornerRadius(6)
            .onSubmit {
                self.submit()
            }
    }

    // MARK: - Directory Picker

    private var directoryPicker: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Directory")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.4))
                .padding(.leading, 4)

            VStack(spacing: 1) {
                if let lastUsed = AppSettings.lastUsedDirectory {
                    self.directoryRow(
                        icon: "clock",
                        name: URL(fileURLWithPath: lastUsed).lastPathComponent,
                        path: lastUsed,
                        isSelected: self.selectedDirectory == lastUsed
                    )
                }

                let homePath = FileManager.default.homeDirectoryForCurrentUser.path
                if self.selectedDirectory != homePath || AppSettings.lastUsedDirectory == nil {
                    self.directoryRow(
                        icon: "house",
                        name: "Home",
                        path: homePath,
                        isSelected: self.selectedDirectory == homePath
                    )
                }

                self.browseRow
            }
            .background(Color.white.opacity(0.04))
            .cornerRadius(6)
        }
    }

    private func directoryRow(icon: String, name: String, path: String, isSelected: Bool) -> some View {
        Button {
            self.selectedDirectory = path
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(width: 14)

                Text(name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))

                Text(path)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.3))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isSelected ? Color.white.opacity(0.08) : Color.clear)
        }
        .buttonStyle(.plain)
    }

    private var browseRow: some View {
        Button {
            self.openDirectoryPicker()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(width: 14)

                Text("Browse...")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
    }

    private func openDirectoryPicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: self.selectedDirectory)

        SessionLauncherPanel.shared.orderOut(nil)

        panel.begin { response in
            if response == .OK, let url = panel.url {
                self.selectedDirectory = url.path
            }
            SessionLauncherPanel.shared.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            Text(self.resolvedCommand)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.35))
                .lineLimit(1)

            Spacer()

            Button("Launch") {
                self.submit()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.black)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.9))
            .clipShape(Capsule())
        }
    }
}

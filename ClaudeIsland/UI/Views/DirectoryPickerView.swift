//
//  DirectoryPickerView.swift
//  ClaudeIsland
//
//  Directory picker for the session launcher
//

import SwiftUI

struct DirectoryPickerView: View {
    // MARK: Internal

    @Binding var selectedPath: String

    var onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Directory")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.4))
                .padding(.leading, 4)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 1) {
                    ForEach(Array(self.allItems.enumerated()), id: \.element.id) { index, item in
                        Button {
                            if item.id == "browse" {
                                self.openBrowser()
                            } else {
                                self.selectedPath = item.path
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: item.icon)
                                    .font(.system(size: 10))
                                    .foregroundColor(item.id == "browse" ? .white
                                        .opacity(0.5) : (item.icon == "star.fill" ? .yellow.opacity(0.7) : .white.opacity(0.4)))
                                    .frame(width: 14)

                                Text(item.name)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.white.opacity(item.id == "browse" ? 0.6 : 0.8))

                                if item.id != "browse" {
                                    Text(item.path)
                                        .font(.system(size: 10))
                                        .foregroundColor(.white.opacity(0.3))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }

                                Spacer()

                                if self.selectedPath == item.path, item.id != "browse" {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(.white.opacity(0.6))
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                self.selectedPath == item.path && item.id != "browse"
                                    ? Color(red: 0.04, green: 0.52, blue: 1.0).opacity(0.15)
                                    : (index == self.highlightedIndex ? Color.white.opacity(0.06) : Color.clear),
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 200)
            .background(Color.white.opacity(0.04))
            .cornerRadius(6)
        }
        .onKeyPress(.upArrow) {
            self.highlightedIndex = max(0, self.highlightedIndex - 1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            self.highlightedIndex = min(self.allItems.count - 1, self.highlightedIndex + 1)
            return .handled
        }
        .onKeyPress(.return) {
            let items = self.allItems
            guard self.highlightedIndex < items.count else { return .ignored }
            let item = items[self.highlightedIndex]
            if item.id == "browse" {
                self.openBrowser()
            } else {
                self.selectedPath = item.path
                self.onSubmit()
            }
            return .handled
        }
    }

    // MARK: Private

    @State private var highlightedIndex = 0

    private var projectStore = ProjectStore.shared

    private var allItems: [(id: String, icon: String, name: String, path: String)] {
        var items: [(id: String, icon: String, name: String, path: String)] = []

        for project in self.projectStore.pinnedProjects {
            items.append((id: project.id.uuidString, icon: "star.fill", name: project.displayName, path: project.path))
        }

        for project in self.projectStore.recentProjects {
            items.append((id: project.id.uuidString, icon: "clock", name: project.displayName, path: project.path))
        }

        if items.isEmpty {
            let homePath = FileManager.default.homeDirectoryForCurrentUser.path
            items.append((id: "home", icon: "house", name: "Home", path: homePath))
        }

        items.append((id: "browse", icon: "folder", name: "Browse...", path: ""))

        return items
    }

    private func openBrowser() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: self.selectedPath)

        SessionLauncherPanel.shared.orderOut(nil)

        panel.begin { response in
            if response == .OK, let url = panel.url {
                self.selectedPath = url.path
                ProjectStore.shared.recordUsage(path: url.path)
            }
            SessionLauncherPanel.shared.makeKeyAndOrderFront(nil)
        }
    }
}

//
//  DirectoryPickerView.swift
//  ClaudeIsland
//
//  Directory picker for the session launcher
//

import SwiftUI

// MARK: - DirectoryItem

private struct DirectoryItem: Identifiable {
    let id: String
    let icon: String
    let name: String
    let path: String
    let isHeader: Bool
}

// MARK: - DirectoryPickerView

struct DirectoryPickerView: View {
    // MARK: Lifecycle

    init(selectedPath: Binding<String>, onSubmit: @escaping () -> Void) {
        self._selectedPath = selectedPath
        self.onSubmit = onSubmit
    }

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
                        if item.isHeader {
                            Text(item.name)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.white.opacity(0.3))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 3)
                        } else {
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
            }
            .frame(maxHeight: 200)
            .background(Color.white.opacity(0.04))
            .cornerRadius(6)
        }
        .onKeyPress(.upArrow) {
            let items = self.allItems
            let count = items.count
            var newIndex = (self.highlightedIndex - 1 + count) % count
            var safety = 0
            while items[newIndex].isHeader, safety < count {
                newIndex = (newIndex - 1 + count) % count
                safety += 1
            }
            if !items[newIndex].isHeader {
                self.highlightedIndex = newIndex
            }
            return .handled
        }
        .onKeyPress(.downArrow) {
            let items = self.allItems
            let count = items.count
            var newIndex = (self.highlightedIndex + 1) % count
            var safety = 0
            while items[newIndex].isHeader, safety < count {
                newIndex = (newIndex + 1) % count
                safety += 1
            }
            if !items[newIndex].isHeader {
                self.highlightedIndex = newIndex
            }
            return .handled
        }
        .onKeyPress(.return) {
            let items = self.allItems
            guard self.highlightedIndex < items.count else { return .ignored }
            let item = items[self.highlightedIndex]
            guard !item.isHeader else { return .ignored }
            if item.id == "browse" {
                self.openBrowser()
            } else {
                self.selectedPath = item.path
                self.onSubmit()
            }
            return .handled
        }
        .onAppear {
            let items = self.allItems
            if let firstNonHeader = items.firstIndex(where: { !$0.isHeader }) {
                self.highlightedIndex = firstNonHeader
            }
        }
    }

    // MARK: Private

    @State private var highlightedIndex = 0

    private var projectStore = ProjectStore.shared

    private var allItems: [DirectoryItem] {
        var items: [DirectoryItem] = []

        if !self.projectStore.pinnedProjects.isEmpty {
            items.append(DirectoryItem(id: "header-pinned", icon: "", name: "Pinned", path: "", isHeader: true))
            for project in self.projectStore.pinnedProjects {
                items.append(DirectoryItem(
                    id: project.id.uuidString,
                    icon: "star.fill",
                    name: project.displayName,
                    path: project.path,
                    isHeader: false,
                ))
            }
        }

        if !self.projectStore.recentProjects.isEmpty {
            items.append(DirectoryItem(id: "header-recent", icon: "", name: "Recent", path: "", isHeader: true))
            for project in self.projectStore.recentProjects {
                items.append(DirectoryItem(id: project.id.uuidString, icon: "clock", name: project.displayName, path: project.path, isHeader: false))
            }
        }

        if items.isEmpty {
            let homePath = FileManager.default.homeDirectoryForCurrentUser.path
            items.append(DirectoryItem(id: "home", icon: "house", name: "Home", path: homePath, isHeader: false))
        }

        items.append(DirectoryItem(id: "browse", icon: "folder", name: "Browse...", path: "", isHeader: false))

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

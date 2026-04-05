//
//  DirectoryPickerView.swift
//  ClaudeIsland
//
//  Dropdown directory picker for the session launcher
//

import SwiftUI

// MARK: - DirectoryPickerView

struct DirectoryPickerView: View {
    // MARK: Lifecycle

    init(
        selectedPath: Binding<String>,
        onSelect: @escaping () -> Void,
        onBrowse: @escaping () -> Void,
    ) {
        self._selectedPath = selectedPath
        self.onSelect = onSelect
        self.onBrowse = onBrowse
    }

    // MARK: Internal

    @Binding var selectedPath: String

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                // Pinned section
                if !self.projectStore.pinnedProjects.isEmpty {
                    self.sectionHeader("Pinned")
                    ForEach(self.projectStore.pinnedProjects) { project in
                        self.projectRow(
                            icon: "star.fill",
                            iconColor: .yellow.opacity(0.7),
                            name: project.displayName,
                            trailing: self.selectedPath == project.path
                                ? AnyView(Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundColor(.white.opacity(0.5)))
                                : nil,
                            isHighlighted: self.highlightedPath == project.path,
                            isSelected: self.selectedPath == project.path,
                        ) {
                            self.selectedPath = project.path
                            self.onSelect()
                        }
                    }
                }

                // Recent section
                if !self.projectStore.recentProjects.isEmpty {
                    if !self.projectStore.pinnedProjects.isEmpty {
                        Rectangle()
                            .fill(Color.white.opacity(0.06))
                            .frame(height: 1)
                            .padding(.horizontal, 4)
                    }
                    self.sectionHeader("Recent")
                    ForEach(self.projectStore.recentProjects) { project in
                        self.projectRow(
                            icon: "clock",
                            iconColor: .white.opacity(0.4),
                            name: project.displayName,
                            trailing: AnyView(
                                Text(SessionPhaseHelpers.timeAgo(project.lastUsedAt, now: Date()))
                                    .font(.system(size: 10))
                                    .foregroundColor(.white.opacity(0.3)),
                            ),
                            isHighlighted: self.highlightedPath == project.path,
                            isSelected: self.selectedPath == project.path,
                        ) {
                            self.selectedPath = project.path
                            self.onSelect()
                        }
                    }
                }

                // Empty state
                if self.projectStore.pinnedProjects.isEmpty, self.projectStore.recentProjects.isEmpty {
                    let homePath = FileManager.default.homeDirectoryForCurrentUser.path
                    self.projectRow(
                        icon: "house",
                        iconColor: .white.opacity(0.4),
                        name: "Home",
                        trailing: self.selectedPath == homePath
                            ? AnyView(Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundColor(.white.opacity(0.5)))
                            : nil,
                        isHighlighted: false,
                        isSelected: self.selectedPath == homePath,
                    ) {
                        self.selectedPath = homePath
                        self.onSelect()
                    }
                }

                // Browse
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 1)
                    .padding(.horizontal, 4)

                Button {
                    self.onBrowse()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.4))
                            .frame(width: 14)
                        Text("Browse...")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.5))
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxHeight: 200)
        .background(Color(red: 0.06, green: 0.06, blue: 0.12).opacity(0.98))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.1), lineWidth: 1),
        )
        .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
    }

    // MARK: Private

    private let onSelect: () -> Void
    private let onBrowse: () -> Void

    @State private var highlightedPath: String?
    private var projectStore = ProjectStore.shared

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(.white.opacity(0.25))
            .tracking(0.5)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }

    private func projectRow(
        icon: String,
        iconColor: Color,
        name: String,
        trailing: AnyView?,
        isHighlighted: Bool,
        isSelected: Bool,
        action: @escaping () -> Void,
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundColor(iconColor)
                    .frame(width: 14)

                Text(name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(isSelected ? 0.95 : 0.7))

                Spacer()

                if let trailing {
                    trailing
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                isSelected
                    ? Color(red: 0.04, green: 0.52, blue: 1.0).opacity(0.15)
                    : (isHighlighted ? Color.white.opacity(0.06) : Color.clear),
            )
        }
        .buttonStyle(.plain)
    }
}

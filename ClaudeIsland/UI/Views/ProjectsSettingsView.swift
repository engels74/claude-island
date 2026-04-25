//
//  ProjectsSettingsView.swift
//  ClaudeIsland
//
//  Expandable projects settings section for NotchMenuView
//

import SwiftUI

// MARK: - ProjectsSettingsView

struct ProjectsSettingsView: View {
    // MARK: Internal

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    self.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(self.isHovered || self.isExpanded ? 1.0 : 0.7))
                        .frame(width: 16)

                    Text("Projects")
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
                    self.pinnedSection
                    self.recentSection
                    self.addButton
                }
                .padding(.leading, 12)
                .padding(.trailing, 12)
                .padding(.vertical, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: Private

    @State private var isExpanded = false
    @State private var isHovered = false

    private var projectStore = ProjectStore.shared

    // MARK: - Pinned Section

    private var pinnedSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Pinned")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.4))
                .padding(.leading, 4)

            if self.projectStore.pinnedProjects.isEmpty {
                Text("No pinned projects")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.3))
                    .padding(.leading, 4)
                    .padding(.vertical, 4)
            } else {
                ForEach(self.projectStore.pinnedProjects) { project in
                    ProjectRow(
                        project: project,
                        isPinned: true,
                        onPin: nil,
                        onUnpin: { self.projectStore.unpin(id: project.id) },
                        onRemove: { self.projectStore.remove(id: project.id) },
                    )
                }
            }
        }
    }

    // MARK: - Recent Section

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Recent")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.4))
                .padding(.leading, 4)

            if self.projectStore.recentProjects.isEmpty {
                Text("No recent projects")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.3))
                    .padding(.leading, 4)
                    .padding(.vertical, 4)
            } else {
                ForEach(self.projectStore.recentProjects) { project in
                    ProjectRow(
                        project: project,
                        isPinned: false,
                        onPin: { self.projectStore.pin(id: project.id) },
                        onUnpin: nil,
                        onRemove: { self.projectStore.remove(id: project.id) }, // swiftlint:disable:this trailing_closure
                    )
                }
            }
        }
    }

    // MARK: - Add Button

    private var addButton: some View {
        Button {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false

            let notchPanels = NSApp.windows.filter { $0 is NotchPanel }
            notchPanels.forEach { $0.orderOut(nil) }

            panel.begin { response in
                if response == .OK, let url = panel.url {
                    self.projectStore.addPinned(path: url.path)
                }
                notchPanels.forEach { $0.makeKeyAndOrderFront(nil) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 11))
                Text("Add Project...")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(.white.opacity(0.5))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - ProjectRow

private struct ProjectRow: View {
    // MARK: Internal

    let project: ProjectEntry
    let isPinned: Bool
    let onPin: (() -> Void)?
    let onUnpin: (() -> Void)?
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: self.isPinned ? "star.fill" : "clock")
                .font(.system(size: 10))
                .foregroundColor(self.isPinned ? .yellow.opacity(0.8) : .white.opacity(0.4))
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(self.project.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(FileManager.default.fileExists(atPath: self.project.path) ? .white.opacity(0.8) : .white.opacity(0.3))

                if self.isPinned, !FileManager.default.fileExists(atPath: self.project.path) {
                    Text("Not found")
                        .font(.system(size: 10))
                        .foregroundColor(.red.opacity(0.5))
                }

                Text(self.project.path)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.3))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if !self.isPinned {
                Text(SessionPhaseHelpers.timeAgo(self.project.lastUsedAt, now: Date()))
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.3))
            }

            if self.isHovered {
                HStack(spacing: 4) {
                    if let onPin {
                        Button("Pin") { onPin() }
                            .font(.system(size: 10, weight: .medium))
                            .buttonStyle(.plain)
                            .foregroundColor(.white.opacity(0.6))
                    }
                    if let onUnpin {
                        Button("Unpin") { onUnpin() }
                            .font(.system(size: 10, weight: .medium))
                            .buttonStyle(.plain)
                            .foregroundColor(.white.opacity(0.6))
                    }
                    Button("Remove") { self.onRemove() }
                        .font(.system(size: 10, weight: .medium))
                        .buttonStyle(.plain)
                        .foregroundColor(.red.opacity(0.7))
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(self.isHovered ? Color.white.opacity(0.06) : Color.clear),
        )
        .onHover { self.isHovered = $0 }
    }

    // MARK: Private

    @State private var isHovered = false
}

//
//  ModuleLayoutSettingsView.swift
//  ClaudeIsland
//
//  Settings UI for configuring notch module layout
//

import SwiftUI

// MARK: - ModuleLayoutSettingsView

struct ModuleLayoutSettingsView: View {
    // MARK: Lifecycle

    init(layoutEngine: ModuleLayoutEngine, onDismiss: @escaping () -> Void) {
        self.layoutEngine = layoutEngine
        self.onDismiss = onDismiss
    }

    // MARK: Internal

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 4) {
                self.header

                Divider()
                    .background(Color.white.opacity(0.08))
                    .padding(.vertical, 4)

                HStack(alignment: .top, spacing: 12) {
                    ModuleColumnView(
                        title: "Left",
                        modules: self.$leftModules,
                        registry: self.layoutEngine.registry,
                    ) { id, beforeID in self.handleDrop(id: id, targetSide: .left, beforeID: beforeID) }
                    ModuleColumnView(
                        title: "Right",
                        modules: self.$rightModules,
                        registry: self.layoutEngine.registry,
                    ) { id, beforeID in self.handleDrop(id: id, targetSide: .right, beforeID: beforeID) }
                }

                ModuleColumnView(
                    title: "Hidden",
                    modules: self.$hiddenModules,
                    registry: self.layoutEngine.registry,
                ) { id, beforeID in self.handleDrop(id: id, targetSide: .hidden, beforeID: beforeID) }
                    .padding(.top, 4)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { self.loadFromConfig() }
    }

    // MARK: Private

    @State private var leftModules: [ModulePlacement] = []
    @State private var rightModules: [ModulePlacement] = []
    @State private var hiddenModules: [ModulePlacement] = []

    private let layoutEngine: ModuleLayoutEngine
    private let onDismiss: () -> Void

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                self.onDismiss()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .medium))
                    Text("Layout")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(.white.opacity(0.7))
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                self.layoutEngine.resetToDefaults()
                self.loadFromConfig()
            } label: {
                Text("Reset")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func loadFromConfig() {
        self.leftModules = self.layoutEngine.config.modulesForSide(.left)
        self.rightModules = self.layoutEngine.config.modulesForSide(.right)
        self.hiddenModules = self.layoutEngine.config.modulesForSide(.hidden)
    }

    private func saveToConfig() {
        var placements: [ModulePlacement] = []
        for (index, var placement) in self.leftModules.enumerated() {
            placement.side = .left
            placement.order = index
            placements.append(placement)
        }
        for (index, var placement) in self.rightModules.enumerated() {
            placement.side = .right
            placement.order = index
            placements.append(placement)
        }
        for (index, var placement) in self.hiddenModules.enumerated() {
            placement.side = .hidden
            placement.order = index
            placements.append(placement)
        }
        self.layoutEngine.config = ModuleLayoutConfig(placements: placements)
    }

    private func handleDrop(id: String, targetSide: ModuleSide, beforeID: String?) {
        self.leftModules.removeAll { $0.id == id }
        self.rightModules.removeAll { $0.id == id }
        self.hiddenModules.removeAll { $0.id == id }

        func insertionIndex(in array: [ModulePlacement]) -> Int {
            guard let beforeID, let index = array.firstIndex(where: { $0.id == beforeID }) else {
                return array.count
            }
            return index
        }

        let placement = ModulePlacement(id: id, side: targetSide, order: 0)
        switch targetSide {
        case .left:
            self.leftModules.insert(placement, at: insertionIndex(in: self.leftModules))
        case .right:
            self.rightModules.insert(placement, at: insertionIndex(in: self.rightModules))
        case .hidden:
            self.hiddenModules.insert(placement, at: insertionIndex(in: self.hiddenModules))
        }
        self.saveToConfig()
    }
}

// MARK: - ModuleColumnView

private struct ModuleColumnView: View {
    // MARK: Internal

    let title: String
    @Binding var modules: [ModulePlacement]

    let registry: ModuleRegistry
    let onDrop: (String, String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(self.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))
                .padding(.horizontal, 12)
                .padding(.top, 4)

            VStack(spacing: 2) {
                ForEach(self.modules) { placement in
                    ModuleRowView(placement: placement, registry: self.registry)
                        .draggable(placement.id)
                        .overlay(alignment: .top) {
                            if self.targetedRowID == placement.id {
                                Color.white.opacity(0.4)
                                    .frame(height: 2)
                            }
                        }
                        .dropDestination(for: String.self) { items, _ in
                            guard let id = items.first else { return false }
                            self.onDrop(id, placement.id)
                            return true
                        } isTargeted: { targeted in
                            if targeted {
                                self.targetedRowID = placement.id
                            } else if self.targetedRowID == placement.id {
                                self.targetedRowID = nil
                            }
                        }
                }

                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        self.isEndTargeted ? Color.white.opacity(0.3) : Color.white.opacity(0.06),
                        lineWidth: 1,
                    )
                    .frame(maxWidth: .infinity, minHeight: self.modules.isEmpty ? 32 : 16)
                    .overlay {
                        if self.modules.isEmpty {
                            Text("None")
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.2))
                        }
                    }
                    .dropDestination(for: String.self) { items, _ in
                        guard let id = items.first else { return false }
                        self.onDrop(id, nil)
                        return true
                    } isTargeted: { self.isEndTargeted = $0 }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.04)),
        )
    }

    // MARK: Private

    @State private var targetedRowID: String?
    @State private var isEndTargeted = false
}

// MARK: - ModuleRowView

private struct ModuleRowView: View {
    // MARK: Internal

    let placement: ModulePlacement
    let registry: ModuleRegistry

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.25))

            Text(self.displayName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.8))
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.04)),
        )
    }

    // MARK: Private

    private var displayName: String {
        self.registry.module(for: self.placement.id)?.displayName ?? self.placement.id
    }
}

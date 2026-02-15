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
                        onMoveModule: self.moveModule,
                        onReorder: self.saveToConfig,
                    )
                    ModuleColumnView(
                        title: "Right",
                        modules: self.$rightModules,
                        registry: self.layoutEngine.registry,
                        onMoveModule: self.moveModule,
                        onReorder: self.saveToConfig,
                    )
                }

                ModuleColumnView(
                    title: "Hidden",
                    modules: self.$hiddenModules,
                    registry: self.layoutEngine.registry,
                    onMoveModule: self.moveModule,
                    onReorder: self.saveToConfig,
                )
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

    private func moveModule(id: String, to targetSide: ModuleSide) {
        self.leftModules.removeAll { $0.id == id }
        self.rightModules.removeAll { $0.id == id }
        self.hiddenModules.removeAll { $0.id == id }

        let placement = ModulePlacement(id: id, side: targetSide, order: 0)
        switch targetSide {
        case .left:
            self.leftModules.append(placement)
        case .right:
            self.rightModules.append(placement)
        case .hidden:
            self.hiddenModules.append(placement)
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
    let onMoveModule: (String, ModuleSide) -> Void
    let onReorder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(self.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))
                .padding(.horizontal, 12)
                .padding(.top, 4)

            if self.modules.isEmpty {
                Text("None")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.2))
                    .frame(maxWidth: .infinity, minHeight: 32)
            } else {
                VStack(spacing: 2) {
                    ForEach(Array(self.modules.enumerated()), id: \.element.id) { index, placement in
                        ModuleRowView(
                            placement: placement,
                            registry: self.registry,
                            currentSide: self.currentSide,
                            isFirst: index == 0,
                            isLast: index == self.modules.count - 1,
                            onMove: self.onMoveModule,
                            onMoveUp: {
                                guard index > 0 else { return }
                                self.modules.swapAt(index, index - 1)
                                self.onReorder()
                            },
                            onMoveDown: {
                                guard index < self.modules.count - 1 else { return }
                                self.modules.swapAt(index, index + 1)
                                self.onReorder()
                            },
                        )
                    }
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.04)),
        )
    }

    // MARK: Private

    private var currentSide: ModuleSide {
        switch self.title {
        case "Left": .left
        case "Right": .right
        default: .hidden
        }
    }
}

// MARK: - ModuleRowView

private struct ModuleRowView: View {
    // MARK: Internal

    let placement: ModulePlacement
    let registry: ModuleRegistry
    let currentSide: ModuleSide
    let isFirst: Bool
    let isLast: Bool
    let onMove: (String, ModuleSide) -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(self.displayName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.8))
                .lineLimit(1)

            Spacer()

            if self.isHovered {
                HStack(spacing: 2) {
                    Button { self.onMoveUp() } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(self.isFirst ? .white.opacity(0.15) : .white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .disabled(self.isFirst)

                    Button { self.onMoveDown() } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(self.isLast ? .white.opacity(0.15) : .white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .disabled(self.isLast)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(self.isHovered ? Color.white.opacity(0.08) : Color.white.opacity(0.04)),
        )
        .onHover { self.isHovered = $0 }
        .contextMenu {
            ForEach(ModuleSide.allCases.filter { $0 != self.currentSide }, id: \.self) { side in
                Button("Move to \(side.rawValue.capitalized)") {
                    self.onMove(self.placement.id, side)
                }
            }
        }
    }

    // MARK: Private

    @State private var isHovered = false

    private var displayName: String {
        self.registry.module(for: self.placement.id)?.displayName ?? self.placement.id
    }
}

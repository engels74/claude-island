//
//  SoundSelector.swift
//  ClaudeIsland
//
//  Manages sound selection state for the settings menu
//

import Combine
import Foundation

@MainActor
class SoundSelector: ObservableObject {
    // MARK: Lifecycle

    private init() {}

    // MARK: Internal

    static let shared = SoundSelector()

    // MARK: - Published State

    @Published var isPickerExpanded = false

    // MARK: - Public API

    /// Extra height needed when picker is expanded (capped for scrolling)
    var expandedPickerHeight: CGFloat {
        guard isPickerExpanded else { return 0 }
        let totalOptions = NotificationSound.allCases.count
        let visibleOptions = min(totalOptions, maxVisibleOptions)
        return CGFloat(visibleOptions) * rowHeight + 8 // +8 for padding
    }

    // MARK: Private

    // MARK: - Constants

    /// Maximum number of sound options to show before scrolling
    private let maxVisibleOptions = 6

    /// Height per sound option row
    private let rowHeight: CGFloat = 32
}

//
//  TerminalVisibilityDetector.swift
//  ClaudeIsland
//
//  Detects if terminal windows are visible on current space
//

import AppKit
import CoreGraphics
import OcclusionKit

enum TerminalVisibilityDetector {
    // MARK: Internal

    /// Check if any terminal window is visible on the current space
    static func isTerminalVisibleOnCurrentSpace() -> Bool {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]

        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        for window in windowList {
            guard let ownerName = window[kCGWindowOwnerName as String] as? String,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0
            else { continue }

            if TerminalAppRegistry.isTerminal(ownerName) {
                return true
            }
        }

        return false
    }

    /// Check if the frontmost (active) application is a terminal
    static func isTerminalFrontmost() -> Bool {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
              let bundleID = frontmostApp.bundleIdentifier
        else {
            return false
        }

        return TerminalAppRegistry.isTerminalBundle(bundleID)
    }

    /// Check if a Claude session is currently focused (user is looking at it)
    /// - Parameter sessionPid: The PID of the Claude process
    /// - Returns: true if the session's terminal is frontmost and (for tmux) the pane is active
    static func isSessionFocused(sessionPID: Int) async -> Bool {
        // If no terminal is frontmost, session is definitely not focused
        guard self.isTerminalFrontmost() else {
            return false
        }

        let tree = ProcessTreeBuilder.shared.buildTree()
        let isInTmux = ProcessTreeBuilder.shared.isInTmux(pid: sessionPID, tree: tree)

        if isInTmux {
            // For tmux sessions, check if the session's pane is active
            return await TmuxTargetFinder.shared.isSessionPaneActive(claudePID: sessionPID)
        } else {
            // For non-tmux sessions, check if the session's terminal app is frontmost
            guard let sessionTerminalPID = ProcessTreeBuilder.shared.findTerminalPID(forProcess: sessionPID, tree: tree),
                  let frontmostApp = NSWorkspace.shared.frontmostApplication
            else {
                return false
            }

            // Use isDescendant for iTerm/Warp compatibility (child processes may differ from main app)
            let frontmostPID = Int(frontmostApp.processIdentifier)
            return sessionTerminalPID == frontmostPID ||
                ProcessTreeBuilder.shared.isDescendant(targetPID: sessionPID, ofAncestor: frontmostPID, tree: tree)
        }
    }

    /// Check if a Claude session's terminal window is visible (≥50% unobscured)
    /// - Parameter sessionPID: The PID of the Claude process
    /// - Returns: true if the session's terminal window is sufficiently visible
    static func isSessionTerminalVisible(sessionPID: Int) async -> Bool {
        let tree = ProcessTreeBuilder.shared.buildTree()

        // Find the terminal PID for this session
        guard let sessionTerminalPID = ProcessTreeBuilder.shared.findTerminalPID(forProcess: sessionPID, tree: tree) else {
            return false
        }

        // Get all on-screen windows
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        // Find windows belonging to the session's terminal
        var terminalWindowIDs: [CGWindowID] = []

        for window in windowList {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? Int,
                  let windowID = window[kCGWindowNumber as String] as? CGWindowID,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0 // Normal window layer
            else { continue }

            // Check if this window belongs to the terminal (direct match or descendant)
            if ownerPID == sessionTerminalPID ||
                ProcessTreeBuilder.shared.isDescendant(targetPID: sessionPID, ofAncestor: ownerPID, tree: tree) {
                terminalWindowIDs.append(windowID)
            }
        }

        // Check visibility of each terminal window using OcclusionKit
        for windowID in terminalWindowIDs {
            do {
                let result = try await OcclusionKit.calculate(for: windowID)
                if result.visiblePercentage >= self.visibilityThreshold {
                    return true
                }
            } catch {
                // If occlusion detection fails for this window, continue to the next
                continue
            }
        }

        return false
    }

    // MARK: Private

    // MARK: - Constants

    /// Minimum visible percentage to consider a window "visible"
    private static let visibilityThreshold: CGFloat = 0.5
}

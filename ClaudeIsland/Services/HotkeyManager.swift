//
//  HotkeyManager.swift
//  ClaudeIsland
//
//  Global hotkey manager using CGEvent tap
//

import ApplicationServices
import Foundation
import Observation
import os

// MARK: - HotkeyManager

@MainActor @Observable
final class HotkeyManager {
    // MARK: Lifecycle

    private init() {
        self.loadSavedShortcuts()
    }

    // MARK: Internal

    static let shared = HotkeyManager()

    func startIfPermitted() {
        guard AXIsProcessTrusted() else {
            Self.logger.debug("Accessibility not granted, skipping hotkey tap")
            return
        }
        guard self.eventTap == nil else { return }
        self.installEventTap()
    }

    func register(combo: KeyCombo, action: HotkeyAction) {
        self.hotkeyMap[combo] = action
        if let tap = self.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        self.saveShortcuts()
    }

    func unregister(combo: KeyCombo) {
        self.hotkeyMap.removeValue(forKey: combo)
        self.saveShortcuts()
    }

    func removeShortcut(forSession sessionID: String) {
        for (combo, action) in self.hotkeyMap {
            if case let .focusSession(id) = action, id == sessionID {
                self.hotkeyMap.removeValue(forKey: combo)
            }
        }
        self.saveShortcuts()
    }

    func combo(for action: HotkeyAction) -> KeyCombo? {
        self.hotkeyMap.first { $0.value == action }?.key
    }

    func allBindings() -> [(combo: KeyCombo, action: HotkeyAction)] {
        self.hotkeyMap.map { (combo: $0.key, action: $0.value) }
    }

    func verifyTapHealth() {
        guard let tap = self.eventTap else {
            self.startIfPermitted()
            return
        }
        if !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
            Self.logger.info("Re-enabled CGEvent tap")
        }
    }

    func cleanupOrphanedBindings() async {
        let sessions = await SessionStore.shared.allSessions()
        let activeIDs = Set(sessions.map(\.sessionID))

        let orphanedCombos = self.hotkeyMap.compactMap { combo, action -> KeyCombo? in
            if case let .focusSession(sessionID) = action, !activeIDs.contains(sessionID) {
                return combo
            }
            return nil
        }
        for combo in orphanedCombos {
            self.hotkeyMap.removeValue(forKey: combo)
        }
        self.saveShortcuts()
    }

    func removeEventTap() {
        if let source = self.runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = self.eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        self.eventTap = nil
        self.runLoopSource = nil
        Self.logger.info("CGEvent tap removed")
    }

    // MARK: Private

    nonisolated private static let logger = Logger(
        subsystem: "com.engels74.ClaudeIsland",
        category: "HotkeyManager",
    )

    private var hotkeyMap: [KeyCombo: HotkeyAction] = [:]
    @ObservationIgnored private var eventTap: CFMachPort?
    @ObservationIgnored private var runLoopSource: CFRunLoopSource?

    private func installEventTap() {
        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue

        let callback: CGEventTapCallBack = { _, _, event, refcon -> Unmanaged<CGEvent>? in
            guard let refcon else { return Unmanaged.passRetained(event) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()

            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags
            let modifiers = flags.rawValue
                & (CGEventFlags.maskCommand.rawValue
                    | CGEventFlags.maskShift.rawValue
                    | CGEventFlags.maskControl.rawValue
                    | CGEventFlags.maskAlternate.rawValue)

            let combo = KeyCombo(keyCode: keyCode, modifiers: UInt(modifiers))

            let matchedAction: HotkeyAction? = manager.hotkeyMap[combo]

            if let action = matchedAction {
                DispatchQueue.main.async {
                    manager.handleAction(action)
                }
                return nil
            }

            return Unmanaged.passRetained(event)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: selfPtr,
        )
        else {
            Self.logger.warning("Failed to create CGEvent tap")
            return
        }

        self.eventTap = tap

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        Self.logger.info("CGEvent tap installed successfully")
    }

    private func handleAction(_ action: HotkeyAction) {
        switch action {
        case .openLauncher:
            SessionLauncherPanel.shared.show()

        case let .focusSession(sessionID):
            Task(name: "hotkey-focus-session") {
                guard let session = await SessionStore.shared.session(for: sessionID) else {
                    self.removeShortcut(forSession: sessionID)
                    return
                }
                let viewModel = SessionLauncherPanel.shared.viewModel
                viewModel?.showChat(for: session)
                viewModel?.notchOpen(reason: .sessionCreated)
                viewModel?.focusInputOnAppear = true
            }
        }
    }

    private func loadSavedShortcuts() {
        if let globalCombo = AppSettings.globalShortcut {
            self.hotkeyMap[globalCombo] = .openLauncher
        }

        let sessionShortcuts = AppSettings.sessionShortcuts
        for (sessionID, combo) in sessionShortcuts {
            self.hotkeyMap[combo] = .focusSession(sessionID: sessionID)
        }
    }

    private func saveShortcuts() {
        var globalCombo: KeyCombo?
        var sessionMap: [String: KeyCombo] = [:]

        for (combo, action) in self.hotkeyMap {
            switch action {
            case .openLauncher:
                globalCombo = combo
            case let .focusSession(sessionID):
                sessionMap[sessionID] = combo
            }
        }

        AppSettings.globalShortcut = globalCombo
        AppSettings.sessionShortcuts = sessionMap
    }
}

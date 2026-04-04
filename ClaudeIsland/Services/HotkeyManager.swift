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
import Synchronization

// MARK: - HotkeyManager

@Observable
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
        self.hotkeyMap.withLock { map in
            map[combo] = action
        }
        self.saveShortcuts()
    }

    func unregister(combo: KeyCombo) {
        self.hotkeyMap.withLock { map in
            map.removeValue(forKey: combo)
        }
        self.saveShortcuts()
    }

    func removeShortcut(forSession sessionID: String) {
        self.hotkeyMap.withLock { map in
            for (combo, action) in map {
                if case let .focusSession(id) = action, id == sessionID {
                    map.removeValue(forKey: combo)
                }
            }
        }
        self.saveShortcuts()
    }

    func combo(for action: HotkeyAction) -> KeyCombo? {
        self.hotkeyMap.withLock { map in
            map.first { $0.value == action }?.key
        }
    }

    func allBindings() -> [(combo: KeyCombo, action: HotkeyAction)] {
        self.hotkeyMap.withLock { map in
            map.map { (combo: $0.key, action: $0.value) }
        }
    }

    // MARK: Private

    nonisolated private static let logger = Logger(
        subsystem: "com.engels74.ClaudeIsland",
        category: "HotkeyManager",
    )

    private let hotkeyMap = Mutex<[KeyCombo: HotkeyAction]>([:])
    @ObservationIgnored private var eventTap: CFMachPort?
    @ObservationIgnored private var runLoopSource: CFRunLoopSource?

    private func installEventTap() {
        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue
        let hotkeyMapRef = self.hotkeyMap

        let callback: CGEventTapCallBack = { _, _, event, refcon -> Unmanaged<CGEvent>? in
            guard let refcon else { return Unmanaged.passRetained(event) }
            let mapPointer = Unmanaged<AnyObject>.fromOpaque(refcon).takeUnretainedValue()
            guard let mutex = mapPointer as? Mutex<[KeyCombo: HotkeyAction]> else { return Unmanaged.passRetained(event) }

            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags
            let modifiers = flags.rawValue
                & (CGEventFlags.maskCommand.rawValue
                    | CGEventFlags.maskShift.rawValue
                    | CGEventFlags.maskControl.rawValue
                    | CGEventFlags.maskAlternate.rawValue)

            let combo = KeyCombo(keyCode: keyCode, modifiers: UInt(modifiers))

            let matchedAction: HotkeyAction? = mutex.withLock { map in
                map[combo]
            }

            if let action = matchedAction {
                Task { @MainActor in
                    Self.shared.handleAction(action)
                }
                return nil
            }

            return Unmanaged.passRetained(event)
        }

        let mutexRef = Unmanaged.passUnretained(hotkeyMapRef as AnyObject).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: mutexRef,
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
            self.hotkeyMap.withLock { map in
                map[globalCombo] = .openLauncher
            }
        }

        let sessionShortcuts = AppSettings.sessionShortcuts
        self.hotkeyMap.withLock { map in
            for (sessionID, combo) in sessionShortcuts {
                map[combo] = .focusSession(sessionID: sessionID)
            }
        }
    }

    private func saveShortcuts() {
        self.hotkeyMap.withLock { map in
            var globalCombo: KeyCombo?
            var sessionMap: [String: KeyCombo] = [:]

            for (combo, action) in map {
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
}

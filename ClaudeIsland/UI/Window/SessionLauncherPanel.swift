//
//  SessionLauncherPanel.swift
//  ClaudeIsland
//
//  Floating panel for the session launcher
//

import AppKit
import os
import SwiftUI

final class SessionLauncherPanel: NSPanel {
    // MARK: Lifecycle

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true,
        )

        self.isFloatingPanel = true
        self.level = .mainMenu + 4
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.hidesOnDeactivate = false
        self.isMovableByWindowBackground = false

        let visualEffect = NSVisualEffectView()
        visualEffect.material = .hudWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 16
        visualEffect.layer?.masksToBounds = true

        self.contentView = visualEffect
        self.visualEffectView = visualEffect
    }

    // MARK: Internal

    static let shared = SessionLauncherPanel()

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    weak var viewModel: NotchViewModel?

    override func cancelOperation(_: Any?) {
        self.dismiss()
    }

    func show() {
        guard !self.isVisible else { return }

        self.updateHostingView()
        self.centerOnNotchScreen()
        self.alphaValue = 0

        self.makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1
        }

        self.installMonitors()
    }

    func dismiss() {
        self.removeMonitors()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        } completionHandler: {
            self.orderOut(nil)
        }
    }

    // MARK: Private

    nonisolated private static let logger = Logger(
        subsystem: "com.engels74.ClaudeIsland",
        category: "SessionLauncherPanel",
    )

    private var visualEffectView: NSVisualEffectView?
    private var localMonitor: Any?
    private var globalMonitor: Any?

    private func updateHostingView() {
        guard let visualEffectView else { return }

        visualEffectView.subviews.forEach { $0.removeFromSuperview() }

        let launcherView = SessionLauncherView(
            onSubmit: { [weak self] prompt, name, directory in
                self?.handleSubmit(prompt: prompt, sessionName: name, directory: directory)
            },
            onDismiss: { [weak self] in
                self?.dismiss()
            },
        )

        let hostingView = NSHostingView(rootView: launcherView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor),
        ])
    }

    private func centerOnNotchScreen() {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let panelSize = self.frame.size
        let originX = screenFrame.midX - panelSize.width / 2
        let originY = screenFrame.midY - panelSize.height / 2 + 50
        self.setFrameOrigin(NSPoint(x: originX, y: originY))
    }

    private func installMonitors() {
        self.localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.dismiss()
                return nil
            }
            return event
        }

        self.globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard let self, self.isVisible else { return }
            if !self.frame.contains(NSEvent.mouseLocation) {
                self.dismiss()
            }
        }
    }

    private func removeMonitors() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
    }

    private func handleSubmit(prompt: String, sessionName: String, directory: String) {
        self.dismiss()

        self.viewModel?.notchOpen(reason: .sessionCreated)
        self.viewModel?.contentType = .instances

        Task(name: "launch-session") {
            do {
                try await TmuxSessionCreator.shared.launch(
                    prompt: prompt,
                    sessionName: sessionName,
                    directory: directory,
                    commandTemplate: AppSettings.claudeCommandTemplate,
                )
            } catch {
                Self.logger.error("Launch failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

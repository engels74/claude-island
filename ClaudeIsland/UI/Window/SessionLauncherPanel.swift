//
//  SessionLauncherPanel.swift
//  ClaudeIsland
//
//  Floating panel for the session launcher
//

import AppKit
import os
import SwiftUI

// MARK: - SessionLauncherPanel

final class SessionLauncherPanel: NSPanel {
    // MARK: Lifecycle

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 200),
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

    func show() {
        guard !self.isVisible else { return }

        self.setupContent()
        self.centerOnNotchScreen()
        self.alphaValue = 0

        self.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: false)

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
            self.hostingController = nil
        }
    }

    // MARK: Private

    nonisolated private static let logger = Logger(
        subsystem: "com.engels74.ClaudeIsland",
        category: "SessionLauncherPanel",
    )

    private var hostingController: AnyObject?
    private var globalMonitor: Any?

    private func setupContent() {
        let launcherView = SessionLauncherView(
            onSubmit: { [weak self] prompt, name, directory in
                self?.handleSubmit(prompt: prompt, sessionName: name, directory: directory)
            },
            onDismiss: { [weak self] in
                self?.dismiss()
            },
            onSizeChange: { [weak self] size in
                self?.resizeToFit(size)
            },
        )

        let wrappedView = launcherView
            .background(
                VisualEffectBackground(material: .hudWindow, cornerRadius: 16),
            )

        let controller = NSHostingController(rootView: wrappedView)
        controller.view.wantsLayer = true
        controller.view.layer?.cornerRadius = 16
        controller.view.layer?.masksToBounds = true

        self.contentView = controller.view
        self.hostingController = controller
    }

    private func resizeToFit(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let newHeight = size.height
        let currentFrame = self.frame
        // Grow/shrink from top (keep top edge fixed, adjust origin.y)
        let newOriginY = currentFrame.origin.y + currentFrame.height - newHeight
        let newFrame = NSRect(
            x: currentFrame.origin.x,
            y: newOriginY,
            width: currentFrame.width,
            height: newHeight,
        )
        self.setFrame(newFrame, display: true, animate: false)
    }

    private func centerOnNotchScreen() {
        // Let the content determine the window size
        if let contentView {
            let fittingSize = contentView.fittingSize
            self.setContentSize(NSSize(width: max(fittingSize.width, 500), height: fittingSize.height))
        }

        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let panelSize = self.frame.size
        let originX = screenFrame.midX - panelSize.width / 2
        let originY = screenFrame.midY - panelSize.height / 2 + 50
        self.setFrameOrigin(NSPoint(x: originX, y: originY))
    }

    private func installMonitors() {
        self.globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard let self, self.isVisible else { return }
            if !self.frame.contains(NSEvent.mouseLocation) {
                self.dismiss()
            }
        }
    }

    private func removeMonitors() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
    }

    private func handleSubmit(prompt: String, sessionName: String, directory: String) {
        self.dismiss()

        self.viewModel?.notchOpen(reason: .sessionCreated)
        self.viewModel?.contentType = .instances

        let viewModel = self.viewModel
        Task(name: "launch-session") {
            do {
                try await TmuxSessionCreator.shared.launch(
                    prompt: prompt,
                    sessionName: sessionName,
                    directory: directory,
                    commandTemplate: AppSettings.claudeCommandTemplate,
                )
                let sessions = await SessionStore.shared.allSessions()
                if let newSession = sessions.first(where: { $0.cwd == directory }) {
                    await MainActor.run {
                        viewModel?.showChat(for: newSession)
                    }
                }
            } catch {
                Self.logger.error("Launch failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

// MARK: - VisualEffectBackground

private struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let cornerRadius: CGFloat

    func makeNSView(context _: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = self.material
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = self.cornerRadius
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context _: Context) {
        nsView.material = self.material
    }
}

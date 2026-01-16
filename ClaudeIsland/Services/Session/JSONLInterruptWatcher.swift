//
//  JSONLInterruptWatcher.swift
//  ClaudeIsland
//
//  Watches JSONL files for interrupt patterns in real-time
//  Uses file system events to detect interrupts faster than hook polling
//

import Foundation
import os.log

/// Logger for interrupt watcher
private let logger = Logger(subsystem: "com.claudeisland", category: "Interrupt")

// MARK: - JSONLInterruptWatcherDelegate

protocol JSONLInterruptWatcherDelegate: AnyObject {
    func didDetectInterrupt(sessionID: String)
}

// MARK: - JSONLInterruptWatcher

/// Watches a session's JSONL file for interrupt patterns in real-time
/// Uses DispatchSource for immediate detection when new lines are written
class JSONLInterruptWatcher {
    // MARK: Lifecycle

    init(sessionID: String, cwd: String) {
        self.sessionID = sessionID
        let projectDir = cwd.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        self.filePath = NSHomeDirectory() + "/.claude/projects/" + projectDir + "/" + sessionID + ".jsonl"
    }

    deinit {
        // Cancel the source - the cancel handler will close the file handle
        if let source {
            source.cancel()
        }
    }

    // MARK: Internal

    weak var delegate: JSONLInterruptWatcherDelegate?

    /// Start watching the JSONL file for interrupts
    func start() {
        queue.async { [weak self] in
            self?.startWatching()
        }
    }

    /// Stop watching
    func stop() {
        queue.async { [weak self] in
            self?.stopInternal()
        }
    }

    // MARK: Private

    /// Patterns that indicate an interrupt occurred
    /// We check for is_error:true combined with interrupt content
    private static let interruptContentPatterns = [
        "Interrupted by user",
        "interrupted by user",
        "user doesn't want to proceed",
        "[Request interrupted by user",
    ]

    private var fileHandle: FileHandle?
    private var source: DispatchSourceFileSystemObject?
    private var lastOffset: UInt64 = 0
    private let sessionID: String
    private let filePath: String
    private let queue = DispatchQueue(label: "com.claudeisland.interruptwatcher", qos: .userInteractive)

    private func startWatching() {
        stopInternal()

        guard FileManager.default.fileExists(atPath: filePath),
              let handle = FileHandle(forReadingAtPath: filePath)
        else {
            logger.warning("Failed to open file: \(filePath, privacy: .public)")
            return
        }

        fileHandle = handle

        do {
            lastOffset = try handle.seekToEnd()
        } catch {
            logger.error("Failed to seek to end: \(error.localizedDescription, privacy: .public)")
            return
        }

        let fd = handle.fileDescriptor
        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: queue
        )

        newSource.setEventHandler { [weak self] in
            self?.checkForInterrupt()
        }

        newSource.setCancelHandler { [weak self] in
            try? self?.fileHandle?.close()
            self?.fileHandle = nil
        }

        source = newSource
        newSource.resume()

        logger.debug("Started watching: \(sessionID.prefix(8), privacy: .public)...")
    }

    private func checkForInterrupt() {
        guard let handle = fileHandle else { return }

        let currentSize: UInt64
        do {
            currentSize = try handle.seekToEnd()
        } catch {
            return
        }

        guard currentSize > lastOffset else { return }

        do {
            try handle.seek(toOffset: lastOffset)
        } catch {
            return
        }

        guard let newData = try? handle.readToEnd(),
              let newContent = String(data: newData, encoding: .utf8)
        else {
            return
        }

        lastOffset = currentSize

        let lines = newContent.components(separatedBy: "\n")
        for line in lines where !line.isEmpty {
            if isInterruptLine(line) {
                logger.info("Detected interrupt in session: \(self.sessionID.prefix(8), privacy: .public)")
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.delegate?.didDetectInterrupt(sessionID: self.sessionID)
                }
                return
            }
        }
    }

    private func isInterruptLine(_ line: String) -> Bool {
        if line.contains("\"type\":\"user\"") {
            if line.contains("[Request interrupted by user]") ||
                line.contains("[Request interrupted by user for tool use]") {
                return true
            }
        }

        if line.contains("\"tool_result\"") && line.contains("\"is_error\":true") {
            if Self.interruptContentPatterns.contains(where: { line.contains($0) }) {
                return true
            }
        }

        if line.contains("\"interrupted\":true") {
            return true
        }

        return false
    }

    private func stopInternal() {
        guard let existingSource = source else { return }
        logger.debug("Stopped watching: \(sessionID.prefix(8), privacy: .public)...")
        existingSource.cancel()
        source = nil
        // fileHandle closed by cancel handler
    }
}

// MARK: - InterruptWatcherManager

/// Manages interrupt watchers for all active sessions
@MainActor
class InterruptWatcherManager {
    // MARK: Lifecycle

    private init() {}

    // MARK: Internal

    static let shared = InterruptWatcherManager()

    weak var delegate: JSONLInterruptWatcherDelegate?

    func startWatching(sessionID: String, cwd: String) {
        guard watchers[sessionID] == nil else { return }

        let watcher = JSONLInterruptWatcher(sessionID: sessionID, cwd: cwd)
        watcher.delegate = delegate
        watcher.start()
        watchers[sessionID] = watcher
    }

    /// Stop watching a specific session
    func stopWatching(sessionID: String) {
        watchers[sessionID]?.stop()
        watchers.removeValue(forKey: sessionID)
    }

    /// Stop all watchers
    func stopAll() {
        for (_, watcher) in watchers {
            watcher.stop()
        }
        watchers.removeAll()
    }

    /// Check if we're watching a session
    func isWatching(sessionID: String) -> Bool {
        watchers[sessionID] != nil
    }

    // MARK: Private

    private var watchers: [String: JSONLInterruptWatcher] = [:]
}

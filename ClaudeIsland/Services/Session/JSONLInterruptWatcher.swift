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
private let logger = Logger(subsystem: "com.engels74.ClaudeIsland", category: "Interrupt")

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
        self.directoryPath = NSHomeDirectory() + "/.claude/projects/" + projectDir
        self.filePath = self.directoryPath + "/" + sessionID + ".jsonl"
    }

    deinit {
        // Cancel the sources - the cancel handlers will close the file handles
        if let source {
            source.cancel()
        }
        if let directorySource {
            directorySource.cancel()
        }
    }

    // MARK: Internal

    weak var delegate: JSONLInterruptWatcherDelegate?

    /// Start watching the JSONL file for interrupts
    func start() {
        self.queue.async { [weak self] in
            self?.startWatching()
        }
    }

    /// Stop watching
    func stop() {
        self.queue.async { [weak self] in
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
    private var directorySource: DispatchSourceFileSystemObject?
    private var directoryHandle: FileHandle?
    private var lastOffset: UInt64 = 0
    private let sessionID: String
    private let filePath: String
    private let directoryPath: String
    private let queue = DispatchQueue(label: "com.claudeisland.interruptwatcher", qos: .userInteractive)

    private func startWatching() {
        self.stopInternal()

        // Try to watch the file directly
        if FileManager.default.fileExists(atPath: self.filePath) {
            self.startFileWatcher()
        } else {
            // File doesn't exist yet - watch the parent directory
            self.startDirectoryWatcher()
        }
    }

    private func startFileWatcher() {
        guard let handle = FileHandle(forReadingAtPath: filePath) else {
            logger.warning("Failed to open file: \(self.filePath, privacy: .public)")
            return
        }

        self.fileHandle = handle

        do {
            self.lastOffset = try handle.seekToEnd()
        } catch {
            logger.error("Failed to seek to end: \(error.localizedDescription, privacy: .public)")
            return
        }

        let fd = handle.fileDescriptor
        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: self.queue
        )

        newSource.setEventHandler { [weak self] in
            self?.checkForInterrupt()
        }

        newSource.setCancelHandler { [weak self] in
            try? self?.fileHandle?.close()
            self?.fileHandle = nil
        }

        self.source = newSource
        newSource.resume()

        logger.debug("Started watching file: \(self.sessionID.prefix(8), privacy: .public)...")
    }

    private func startDirectoryWatcher() {
        // Ensure the directory exists
        guard FileManager.default.fileExists(atPath: self.directoryPath) else {
            logger.warning("Directory doesn't exist: \(self.directoryPath, privacy: .public)")
            return
        }

        guard let handle = FileHandle(forReadingAtPath: self.directoryPath) else {
            logger.warning("Failed to open directory for watching: \(self.directoryPath, privacy: .public)")
            return
        }

        self.directoryHandle = handle
        let fd = handle.fileDescriptor

        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write],
            queue: self.queue
        )

        newSource.setEventHandler { [weak self] in
            self?.checkForFileAppearance()
        }

        newSource.setCancelHandler { [weak self] in
            try? self?.directoryHandle?.close()
            self?.directoryHandle = nil
        }

        self.directorySource = newSource
        newSource.resume()

        logger.debug("Started watching directory for file appearance: \(self.sessionID.prefix(8), privacy: .public)...")
    }

    private func checkForFileAppearance() {
        // Check if the file now exists
        guard FileManager.default.fileExists(atPath: self.filePath) else {
            return
        }

        logger.debug("File appeared, switching to file watcher: \(self.sessionID.prefix(8), privacy: .public)")

        // Stop directory watcher
        if let existingDirSource = directorySource {
            existingDirSource.cancel()
            self.directorySource = nil
        }

        // Start file watcher
        self.startFileWatcher()
    }

    private func checkForInterrupt() {
        guard let handle = fileHandle else { return }

        let currentSize: UInt64
        do {
            currentSize = try handle.seekToEnd()
        } catch {
            return
        }

        guard currentSize > self.lastOffset else { return }

        do {
            try handle.seek(toOffset: self.lastOffset)
        } catch {
            return
        }

        guard let newData = try? handle.readToEnd(),
              let newContent = String(data: newData, encoding: .utf8)
        else {
            return
        }

        self.lastOffset = currentSize

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
        // Stop file watcher
        if let existingSource = source {
            existingSource.cancel()
            self.source = nil
        }
        // Stop directory watcher
        if let existingDirSource = directorySource {
            existingDirSource.cancel()
            self.directorySource = nil
        }
        // fileHandle and directoryHandle closed by cancel handlers
        logger.debug("Stopped watching: \(self.sessionID.prefix(8), privacy: .public)...")
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
        guard self.watchers[sessionID] == nil else { return }

        let watcher = JSONLInterruptWatcher(sessionID: sessionID, cwd: cwd)
        watcher.delegate = self.delegate
        watcher.start()
        self.watchers[sessionID] = watcher
    }

    /// Stop watching a specific session
    func stopWatching(sessionID: String) {
        self.watchers[sessionID]?.stop()
        self.watchers.removeValue(forKey: sessionID)
    }

    /// Stop all watchers
    func stopAll() {
        for (_, watcher) in self.watchers {
            watcher.stop()
        }
        self.watchers.removeAll()
    }

    /// Check if we're watching a session
    func isWatching(sessionID: String) -> Bool {
        self.watchers[sessionID] != nil
    }

    // MARK: Private

    private var watchers: [String: JSONLInterruptWatcher] = [:]
}

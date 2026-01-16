//
//  AgentFileWatcher.swift
//  ClaudeIsland
//
//  Watches agent JSONL files for real-time subagent tool updates.
//  Each Task tool gets its own watcher for its agent file.
//

import Foundation
import os.log

/// Logger for agent file watcher
private let logger = Logger(subsystem: "com.engels74.ClaudeIsland", category: "AgentFileWatcher")

// MARK: - AgentFileWatcherDelegate

/// Protocol for receiving agent file update notifications
protocol AgentFileWatcherDelegate: AnyObject {
    func didUpdateAgentTools(sessionID: String, taskToolID: String, tools: [SubagentToolInfo])
}

// MARK: - AgentFileWatcher

/// Watches a single agent JSONL file for tool updates
class AgentFileWatcher {
    // MARK: Lifecycle

    init(sessionID: String, taskToolID: String, agentID: String, cwd: String) {
        self.sessionID = sessionID
        self.taskToolID = taskToolID
        self.agentID = agentID
        self.cwd = cwd

        let projectDir = cwd.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        self.filePath = NSHomeDirectory() + "/.claude/projects/" + projectDir + "/agent-" + agentID + ".jsonl"
    }

    deinit {
        // Suspend before cancel ensures cancel handler executes properly
        // if the source was in a suspended state
        if let source {
            source.cancel()
        }
    }

    // MARK: Internal

    weak var delegate: AgentFileWatcherDelegate?

    /// Start watching the agent file
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

    private var fileHandle: FileHandle?
    private var source: DispatchSourceFileSystemObject?
    private var lastOffset: UInt64 = 0
    private let sessionID: String
    private let taskToolID: String
    private let agentID: String
    private let cwd: String
    private let filePath: String
    private let queue = DispatchQueue(label: "com.claudeisland.agentfilewatcher", qos: .userInitiated)

    /// Track seen tool IDs to avoid duplicates
    private var seenToolIDs: Set<String> = []

    private func startWatching() {
        self.stopInternal()

        guard FileManager.default.fileExists(atPath: self.filePath),
              let handle = FileHandle(forReadingAtPath: self.filePath)
        else {
            logger.warning("Failed to open agent file: \(self.filePath, privacy: .public)")
            return
        }

        self.fileHandle = handle
        self.lastOffset = 0
        self.parseTools()

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
            self?.parseTools()
        }

        newSource.setCancelHandler { [weak self] in
            try? self?.fileHandle?.close()
            self?.fileHandle = nil
        }

        self.source = newSource
        newSource.resume()

        logger
            .debug(
                "Started watching agent file: \(self.agentID.prefix(8), privacy: .public) for task: \(self.taskToolID.prefix(12), privacy: .public)"
            )
    }

    private func parseTools() {
        let tools = ConversationParser.parseSubagentToolsSync(agentID: self.agentID, cwd: self.cwd)

        let newTools = tools.filter { !self.seenToolIDs.contains($0.id) }
        guard !newTools.isEmpty || tools.count != self.seenToolIDs.count else { return }

        self.seenToolIDs = Set(tools.map(\.id))
        logger.debug("Agent \(self.agentID.prefix(8), privacy: .public) has \(tools.count) tools")

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.didUpdateAgentTools(
                sessionID: self.sessionID,
                taskToolID: self.taskToolID,
                tools: tools
            )
        }
    }

    private func stopInternal() {
        guard let existingSource = source else { return }
        logger.debug("Stopped watching agent file: \(self.agentID.prefix(8), privacy: .public)")
        existingSource.cancel()
        self.source = nil
    }
}

// MARK: - AgentFileWatcherManager

/// Manages agent file watchers for active Task tools
@MainActor
class AgentFileWatcherManager {
    // MARK: Lifecycle

    private init() {}

    // MARK: Internal

    static let shared = AgentFileWatcherManager()

    weak var delegate: AgentFileWatcherDelegate?

    func startWatching(sessionID: String, taskToolID: String, agentID: String, cwd: String) {
        let key = "\(sessionID)-\(taskToolID)"
        guard self.watchers[key] == nil else { return }

        let watcher = AgentFileWatcher(
            sessionID: sessionID,
            taskToolID: taskToolID,
            agentID: agentID,
            cwd: cwd
        )
        watcher.delegate = self.delegate
        watcher.start()
        self.watchers[key] = watcher

        logger.info("Started agent watcher for task \(taskToolID.prefix(12), privacy: .public)")
    }

    /// Stop watching a specific Task's agent file
    func stopWatching(sessionID: String, taskToolID: String) {
        let key = "\(sessionID)-\(taskToolID)"
        self.watchers[key]?.stop()
        self.watchers.removeValue(forKey: key)
    }

    /// Stop all watchers for a session
    func stopWatchingSession(sessionID: String) {
        let keysToRemove = self.watchers.keys.filter { $0.hasPrefix(sessionID) }
        for key in keysToRemove {
            self.watchers[key]?.stop()
            self.watchers.removeValue(forKey: key)
        }
    }

    /// Stop all watchers
    func stopAll() {
        for (_, watcher) in self.watchers {
            watcher.stop()
        }
        self.watchers.removeAll()
    }

    /// Check if we're watching a Task's agent file
    func isWatching(sessionID: String, taskToolID: String) -> Bool {
        let key = "\(sessionID)-\(taskToolID)"
        return self.watchers[key] != nil
    }

    // MARK: Private

    /// Active watchers keyed by "sessionId-taskToolId"
    private var watchers: [String: AgentFileWatcher] = [:]
}

// MARK: - AgentFileWatcherBridge

/// Bridge between AgentFileWatcherManager and SessionStore
/// Converts delegate callbacks into SessionEvent processing
@MainActor
class AgentFileWatcherBridge: AgentFileWatcherDelegate {
    // MARK: Lifecycle

    private init() {}

    // MARK: Internal

    static let shared = AgentFileWatcherBridge()

    func didUpdateAgentTools(sessionID: String, taskToolID: String, tools: [SubagentToolInfo]) {
        Task {
            await SessionStore.shared.process(
                .agentFileUpdated(sessionID: sessionID, taskToolID: taskToolID, tools: tools)
            )
        }
    }
}

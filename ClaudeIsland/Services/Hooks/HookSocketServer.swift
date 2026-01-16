//
//  HookSocketServer.swift
//  ClaudeIsland
//
//  Unix domain socket server for real-time hook events
//  Supports request/response for permission decisions
//

import Foundation
import os.log

/// Logger for hook socket server
private let logger = Logger(subsystem: "com.claudeisland", category: "Hooks")

// MARK: - HookEvent

/// Event received from Claude Code hooks
struct HookEvent: Codable, Sendable {
    // MARK: Lifecycle

    /// Create a copy with updated toolUseID
    init(
        sessionID: String,
        cwd: String,
        event: String,
        status: String,
        pid: Int?,
        tty: String?,
        tool: String?,
        toolInput: [String: AnyCodable]?,
        toolUseID: String?,
        notificationType: String?,
        message: String?
    ) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.event = event
        self.status = status
        self.pid = pid
        self.tty = tty
        self.tool = tool
        self.toolInput = toolInput
        self.toolUseID = toolUseID
        self.notificationType = notificationType
        self.message = message
    }

    // MARK: Internal

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case cwd, event, status, pid, tty, tool
        case toolInput = "tool_input"
        case toolUseID = "tool_use_id"
        case notificationType = "notification_type"
        case message
    }

    let sessionID: String
    let cwd: String
    let event: String
    let status: String
    let pid: Int?
    let tty: String?
    let tool: String?
    let toolInput: [String: AnyCodable]?
    let toolUseID: String?
    let notificationType: String?
    let message: String?

    var sessionPhase: SessionPhase {
        if event == "PreCompact" {
            return .compacting
        }

        switch status {
        case "waiting_for_approval":
            // Note: Full PermissionContext is constructed by SessionStore, not here
            // This is just for quick phase checks
            return .waitingForApproval(PermissionContext(
                toolUseID: toolUseID ?? "",
                toolName: tool ?? "unknown",
                toolInput: toolInput,
                receivedAt: Date()
            ))
        case "waiting_for_input":
            return .waitingForInput
        case "running_tool",
             "processing",
             "starting":
            return .processing
        case "compacting":
            return .compacting
        default:
            return .idle
        }
    }

    /// Whether this event expects a response (permission request)
    nonisolated var expectsResponse: Bool {
        event == "PermissionRequest" && status == "waiting_for_approval"
    }
}

// MARK: - HookResponse

/// Response to send back to the hook
struct HookResponse: Codable {
    let decision: String // "allow", "deny", or "ask"
    let reason: String?
}

// MARK: - PendingPermission

/// Pending permission request waiting for user decision
struct PendingPermission: Sendable {
    let sessionID: String
    let toolUseID: String
    let clientSocket: Int32
    let event: HookEvent
    let receivedAt: Date
}

/// Callback for hook events
typealias HookEventHandler = @Sendable (HookEvent) -> Void

/// Callback for permission response failures (socket died)
typealias PermissionFailureHandler = @Sendable (_ sessionID: String, _ toolUseID: String) -> Void

// MARK: - HookSocketServer

/// Unix domain socket server that receives events from Claude Code hooks
/// Uses GCD DispatchSource for non-blocking I/O
class HookSocketServer { // swiftlint:disable:this type_body_length
    // MARK: Lifecycle

    private init() {}

    // MARK: Internal

    static let shared = HookSocketServer()
    static let socketPath = "/tmp/claude-island.sock"

    /// Start the socket server
    func start(onEvent: @escaping HookEventHandler, onPermissionFailure: PermissionFailureHandler? = nil) {
        queue.async { [weak self] in
            self?.startServer(onEvent: onEvent, onPermissionFailure: onPermissionFailure)
        }
    }

    /// Stop the socket server
    func stop() {
        // Cancel accept source if active
        if let source = acceptSource {
            source.cancel()
            acceptSource = nil
        }
        unlink(Self.socketPath)

        // Clean up pending permissions
        permissionsLock.lock()
        for (_, pending) in pendingPermissions {
            close(pending.clientSocket)
        }
        pendingPermissions.removeAll()
        permissionsLock.unlock()
    }

    /// Respond to a pending permission request by toolUseID
    func respondToPermission(toolUseID: String, decision: String, reason: String? = nil) {
        queue.async { [weak self] in
            self?.sendPermissionResponse(toolUseID: toolUseID, decision: decision, reason: reason)
        }
    }

    /// Respond to permission by sessionID (finds the most recent pending for that session)
    func respondToPermissionBySession(sessionID: String, decision: String, reason: String? = nil) {
        queue.async { [weak self] in
            self?.sendPermissionResponseBySession(sessionID: sessionID, decision: decision, reason: reason)
        }
    }

    /// Cancel all pending permissions for a session (when Claude stops waiting)
    func cancelPendingPermissions(sessionID: String) {
        queue.async { [weak self] in
            self?.cleanupPendingPermissions(sessionID: sessionID)
        }
    }

    /// Check if there's a pending permission request for a session
    func hasPendingPermission(sessionID: String) -> Bool {
        permissionsLock.lock()
        defer { permissionsLock.unlock() }
        return pendingPermissions.values.contains { $0.sessionID == sessionID }
    }

    /// Get the pending permission details for a session (if any)
    func getPendingPermission(sessionID: String) -> (toolName: String?, toolID: String?, toolInput: [String: AnyCodable]?)? {
        permissionsLock.lock()
        defer { permissionsLock.unlock() }
        guard let pending = pendingPermissions.values.first(where: { $0.sessionID == sessionID }) else {
            return nil
        }
        return (pending.event.tool, pending.toolUseID, pending.event.toolInput)
    }

    /// Cancel a specific pending permission by toolUseID (when tool completes via terminal approval)
    func cancelPendingPermission(toolUseID: String) {
        queue.async { [weak self] in
            self?.cleanupSpecificPermission(toolUseID: toolUseID)
        }
    }

    // MARK: Private

    // MARK: - Tool Use ID Cache

    /// Encoder with sorted keys for deterministic cache keys
    private static let sortedEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    private var serverSocket: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var eventHandler: HookEventHandler?
    private var permissionFailureHandler: PermissionFailureHandler?
    private let queue = DispatchQueue(label: "com.claudeisland.socket", qos: .userInitiated)

    /// Pending permission requests indexed by toolUseID
    private var pendingPermissions: [String: PendingPermission] = [:]
    private let permissionsLock = NSLock()

    /// Cache tool_use_id from PreToolUse to correlate with PermissionRequest
    /// Key: "sessionId:toolName:serializedInput" -> Queue of tool_use_ids (FIFO)
    /// PermissionRequest events don't include tool_use_id, so we cache from PreToolUse
    private var toolUseIDCache: [String: [String]] = [:]
    private let cacheLock = NSLock()

    private func startServer(onEvent: @escaping HookEventHandler, onPermissionFailure: PermissionFailureHandler?) {
        guard serverSocket < 0 else { return }

        eventHandler = onEvent
        permissionFailureHandler = onPermissionFailure

        unlink(Self.socketPath)

        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            logger.error("Failed to create socket: \(errno)")
            return
        }

        let flags = fcntl(serverSocket, F_GETFL)
        _ = fcntl(serverSocket, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        Self.socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let pathBufferPtr = UnsafeMutableRawPointer(pathPtr)
                    .assumingMemoryBound(to: CChar.self)
                strcpy(pathBufferPtr, ptr)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(serverSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            logger.error("Failed to bind socket: \(errno)")
            close(serverSocket)
            serverSocket = -1
            return
        }

        chmod(Self.socketPath, 0o777)

        guard listen(serverSocket, 10) == 0 else {
            logger.error("Failed to listen: \(errno)")
            close(serverSocket)
            serverSocket = -1
            return
        }

        logger.info("Listening on \(Self.socketPath, privacy: .public)")

        acceptSource = DispatchSource.makeReadSource(fileDescriptor: serverSocket, queue: queue)
        acceptSource?.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        acceptSource?.setCancelHandler { [weak self] in
            if let fd = self?.serverSocket, fd >= 0 {
                close(fd)
                self?.serverSocket = -1
            }
        }
        acceptSource?.resume()
    }

    private func cleanupSpecificPermission(toolUseID: String) {
        permissionsLock.lock()
        guard let pending = pendingPermissions.removeValue(forKey: toolUseID) else {
            permissionsLock.unlock()
            return
        }
        permissionsLock.unlock()

        logger
            .debug(
                "Tool completed externally, closing socket for \(pending.sessionID.prefix(8), privacy: .public) tool:\(toolUseID.prefix(12), privacy: .public)"
            )
        close(pending.clientSocket)
    }

    private func cleanupPendingPermissions(sessionID: String) {
        permissionsLock.lock()
        let matching = pendingPermissions.filter { $0.value.sessionID == sessionID }
        for (toolUseID, pending) in matching {
            logger.debug("Cleaning up stale permission for \(sessionID.prefix(8), privacy: .public) tool:\(toolUseID.prefix(12), privacy: .public)")
            close(pending.clientSocket)
            pendingPermissions.removeValue(forKey: toolUseID)
        }
        permissionsLock.unlock()
    }

    /// Generate cache key from event properties
    private func cacheKey(sessionID: String, toolName: String?, toolInput: [String: AnyCodable]?) -> String {
        let inputStr: String = if let input = toolInput,
                                  let data = try? Self.sortedEncoder.encode(input),
                                  let str = String(data: data, encoding: .utf8) {
            str
        } else {
            "{}"
        }
        return "\(sessionID):\(toolName ?? "unknown"):\(inputStr)"
    }

    /// Cache tool_use_id from PreToolUse event (FIFO queue per key)
    private func cacheToolUseID(event: HookEvent) {
        guard let toolUseID = event.toolUseID else { return }

        let key = cacheKey(sessionID: event.sessionID, toolName: event.tool, toolInput: event.toolInput)

        cacheLock.lock()
        if toolUseIDCache[key] == nil {
            toolUseIDCache[key] = []
        }
        toolUseIDCache[key]?.append(toolUseID)
        cacheLock.unlock()

        logger
            .debug(
                "Cached tool_use_id for \(event.sessionID.prefix(8), privacy: .public) tool:\(event.tool ?? "?", privacy: .public) id:\(toolUseID.prefix(12), privacy: .public)"
            )
    }

    /// Pop and return cached tool_use_id for PermissionRequest (FIFO)
    private func popCachedToolUseID(event: HookEvent) -> String? {
        let key = cacheKey(sessionID: event.sessionID, toolName: event.tool, toolInput: event.toolInput)

        cacheLock.lock()
        defer { cacheLock.unlock() }

        guard var queue = toolUseIDCache[key], !queue.isEmpty else {
            return nil
        }

        let toolUseID = queue.removeFirst()

        if queue.isEmpty {
            toolUseIDCache.removeValue(forKey: key)
        } else {
            toolUseIDCache[key] = queue
        }

        logger
            .debug(
                "Retrieved cached tool_use_id for \(event.sessionID.prefix(8), privacy: .public) tool:\(event.tool ?? "?", privacy: .public) id:\(toolUseID.prefix(12), privacy: .public)"
            )
        return toolUseID
    }

    /// Clean up cache entries for a session (on session end)
    private func cleanupCache(sessionID: String) {
        cacheLock.lock()
        let keysToRemove = toolUseIDCache.keys.filter { $0.hasPrefix("\(sessionID):") }
        for key in keysToRemove {
            toolUseIDCache.removeValue(forKey: key)
        }
        cacheLock.unlock()

        if !keysToRemove.isEmpty {
            logger.debug("Cleaned up \(keysToRemove.count) cache entries for session \(sessionID.prefix(8), privacy: .public)")
        }
    }

    private func acceptConnection() {
        let clientSocket = accept(serverSocket, nil, nil)
        guard clientSocket >= 0 else { return }

        var nosigpipe: Int32 = 1
        setsockopt(clientSocket, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))

        handleClient(clientSocket)
    }

    private func handleClient(_ clientSocket: Int32) {
        let flags = fcntl(clientSocket, F_GETFL)
        _ = fcntl(clientSocket, F_SETFL, flags | O_NONBLOCK)

        guard let data = readClientData(clientSocket: clientSocket) else {
            close(clientSocket)
            return
        }

        guard let event = parseHookEvent(from: data) else {
            close(clientSocket)
            return
        }

        processEventActions(event)

        if event.expectsResponse {
            handlePermissionRequest(event: event, clientSocket: clientSocket)
        } else {
            close(clientSocket)
            eventHandler?(event)
        }
    }

    private func readClientData(clientSocket: Int32) -> Data? {
        var allData = Data()
        var buffer = [UInt8](repeating: 0, count: 131_072)
        var pollFd = pollfd(fd: clientSocket, events: Int16(POLLIN), revents: 0)

        let startTime = Date()
        while Date().timeIntervalSince(startTime) < 0.5 {
            let pollResult = poll(&pollFd, 1, 50)

            if pollResult > 0 && (pollFd.revents & Int16(POLLIN)) != 0 {
                let bytesRead = read(clientSocket, &buffer, buffer.count)
                if bytesRead > 0 {
                    allData.append(contentsOf: buffer[0 ..< bytesRead])
                } else if bytesRead == 0 || (errno != EAGAIN && errno != EWOULDBLOCK) {
                    break
                }
            } else if pollResult == 0 && !allData.isEmpty {
                break
            } else if pollResult != 0 {
                break
            }
        }

        return allData.isEmpty ? nil : allData
    }

    private func parseHookEvent(from data: Data) -> HookEvent? {
        guard let event = try? JSONDecoder().decode(HookEvent.self, from: data) else {
            logger.warning("Failed to parse event: \(String(data: data, encoding: .utf8) ?? "?", privacy: .public)")
            return nil
        }
        logger.debug("Received: \(event.event, privacy: .public) for \(event.sessionID.prefix(8), privacy: .public)")
        return event
    }

    private func processEventActions(_ event: HookEvent) {
        if event.event == "PreToolUse" {
            cacheToolUseID(event: event)
        }
        if event.event == "SessionEnd" {
            cleanupCache(sessionID: event.sessionID)
        }
    }

    private func handlePermissionRequest(event: HookEvent, clientSocket: Int32) {
        guard let toolUseID = resolveToolUseID(for: event) else {
            logger.warning("Permission request missing tool_use_id for \(event.sessionID.prefix(8), privacy: .public) - no cache hit")
            close(clientSocket)
            eventHandler?(event)
            return
        }

        logger.debug("Permission request - keeping socket open for \(event.sessionID.prefix(8), privacy: .public) tool:\(toolUseID.prefix(12), privacy: .public)")

        let updatedEvent = createUpdatedEvent(from: event, with: toolUseID)
        storePendingPermission(event: updatedEvent, toolUseID: toolUseID, clientSocket: clientSocket)
        eventHandler?(updatedEvent)
    }

    private func resolveToolUseID(for event: HookEvent) -> String? {
        if let eventToolUseID = event.toolUseID {
            return eventToolUseID
        }
        return popCachedToolUseID(event: event)
    }

    private func createUpdatedEvent(from event: HookEvent, with toolUseID: String) -> HookEvent {
        HookEvent(
            sessionID: event.sessionID,
            cwd: event.cwd,
            event: event.event,
            status: event.status,
            pid: event.pid,
            tty: event.tty,
            tool: event.tool,
            toolInput: event.toolInput,
            toolUseID: toolUseID,
            notificationType: event.notificationType,
            message: event.message
        )
    }

    private func storePendingPermission(event: HookEvent, toolUseID: String, clientSocket: Int32) {
        let pending = PendingPermission(
            sessionID: event.sessionID,
            toolUseID: toolUseID,
            clientSocket: clientSocket,
            event: event,
            receivedAt: Date()
        )
        permissionsLock.lock()
        pendingPermissions[toolUseID] = pending
        permissionsLock.unlock()
    }

    private func sendPermissionResponse(toolUseID: String, decision: String, reason: String?) {
        permissionsLock.lock()
        guard let pending = pendingPermissions.removeValue(forKey: toolUseID) else {
            permissionsLock.unlock()
            logger.debug("No pending permission for toolUseId: \(toolUseID.prefix(12), privacy: .public)")
            return
        }
        permissionsLock.unlock()

        let response = HookResponse(decision: decision, reason: reason)
        guard let data = try? JSONEncoder().encode(response) else {
            close(pending.clientSocket)
            return
        }

        let age = Date().timeIntervalSince(pending.receivedAt)
        logger
            .info(
                "Sending response: \(decision, privacy: .public) for \(pending.sessionID.prefix(8), privacy: .public) tool:\(toolUseID.prefix(12), privacy: .public) (age: \(String(format: "%.1f", age), privacy: .public)s)"
            )

        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                logger.error("Failed to get data buffer address")
                return
            }
            let result = write(pending.clientSocket, baseAddress, data.count)
            if result < 0 {
                logger.error("Write failed with errno: \(errno)")
            } else {
                logger.debug("Write succeeded: \(result) bytes")
            }
        }

        close(pending.clientSocket)
    }

    private func sendPermissionResponseBySession(sessionID: String, decision: String, reason: String?) {
        permissionsLock.lock()
        let matchingPending = pendingPermissions.values
            .filter { $0.sessionID == sessionID }
            .max { $0.receivedAt < $1.receivedAt }

        guard let pending = matchingPending else {
            permissionsLock.unlock()
            logger.debug("No pending permission for session: \(sessionID.prefix(8), privacy: .public)")
            return
        }

        pendingPermissions.removeValue(forKey: pending.toolUseID)
        permissionsLock.unlock()

        let response = HookResponse(decision: decision, reason: reason)
        guard let data = try? JSONEncoder().encode(response) else {
            close(pending.clientSocket)
            permissionFailureHandler?(sessionID, pending.toolUseID)
            return
        }

        let age = Date().timeIntervalSince(pending.receivedAt)
        logger
            .info(
                "Sending response: \(decision, privacy: .public) for \(sessionID.prefix(8), privacy: .public) tool:\(pending.toolUseID.prefix(12), privacy: .public) (age: \(String(format: "%.1f", age), privacy: .public)s)"
            )

        var writeSuccess = false
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                logger.error("Failed to get data buffer address")
                return
            }
            let result = write(pending.clientSocket, baseAddress, data.count)
            if result < 0 {
                logger.error("Write failed with errno: \(errno)")
            } else {
                logger.debug("Write succeeded: \(result) bytes")
                writeSuccess = true
            }
        }

        close(pending.clientSocket)

        if !writeSuccess {
            permissionFailureHandler?(sessionID, pending.toolUseID)
        }
    }
}

// MARK: - AnyCodable

/// Type-erasing codable wrapper for heterogeneous values
/// Used to decode JSON objects with mixed value types
///
/// `@unchecked Sendable` safety justification:
/// 1. The `value` property is immutable (`let`) - once set, it cannot be changed
/// 2. In practice, values are only JSON-compatible types (String, Int, Double, Bool, Array, Dict)
/// 3. These JSON-compatible types are all either value types or immutable reference types
/// 4. The struct is created from JSON decoding and immediately passed across actor boundaries
/// 5. No mutation occurs after initialization - it's effectively a "frozen" value container
///
/// Note: For types that need true Sendable safety (like PermissionContext), we serialize
/// the AnyCodable content to a JSON string instead. See PermissionContext.toolInputJSON.
struct AnyCodable: Codable, @unchecked Sendable {
    // MARK: Lifecycle

    /// Initialize with any value
    init(_ value: Any) {
        self.value = value
    }

    /// Decode from JSON
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self.value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            self.value = bool
        } else if let int = try? container.decode(Int.self) {
            self.value = int
        } else if let double = try? container.decode(Double.self) {
            self.value = double
        } else if let string = try? container.decode(String.self) {
            self.value = string
        } else if let array = try? container.decode([Self].self) {
            self.value = array.map(\.value)
        } else if let dict = try? container.decode([String: Self].self) {
            self.value = dict.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode value")
        }
    }

    // MARK: Internal

    /// The underlying value
    /// `nonisolated(unsafe)` is required because `Any` is not Sendable, but we ensure safety
    /// through immutability (let) and limiting to JSON-compatible value types only
    nonisolated(unsafe) let value: Any

    /// Encode to JSON
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { Self($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { Self($0) })
        default:
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: [], debugDescription: "Cannot encode value"))
        }
    }
}

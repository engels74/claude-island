---
type: "agent_requested"
description: "Modern Swift Best Practices for macOS"
---

# Modern Swift Best Practices for macOS Menu Bar Apps

**Swift 5.9–6.x patterns for building reactive, event-driven menu bar utilities on macOS 15+ have coalesced around actor-isolated state stores, the @Observable macro, and structured concurrency.**

---

## 1. Actor and concurrency patterns

Swift actors have become the standard for thread-safe shared state in event-driven architectures. For menu bar apps with a centralized `SessionStore`, actors eliminate manual synchronization while providing compile-time data race safety.

### Use actors for shared mutable state

**Rule**: Design actors to protect mutable shared state, using them as thread-safe wrappers around data that requires synchronized access across multiple concurrent contexts.

**Rationale**: Actors serialize access to their mutable state, preventing data races at compile-time. Unlike classes with manual locking via dispatch queues and barriers, actors hide synchronization as an implementation detail. Use actors when you need reference semantics for shared state, mutable data accessed from multiple tasks, and Sendable conformance for passing across isolation boundaries.

**Example**:

```swift
actor SessionStore {
    private var events: [SessionEvent] = []
    private var subscribers: [UUID: (SessionEvent) -> Void] = [:]

    func append(_ event: SessionEvent) {
        events.append(event)
        for subscriber in subscribers.values {
            subscriber(event)
        }
    }

    func subscribe(id: UUID, handler: @escaping (SessionEvent) -> Void) {
        subscribers[id] = handler
    }

    // nonisolated for immutable computed properties
    nonisolated var storeDescription: String {
        "Session store for conversation tracking"
    }
}
```

**Anti-pattern**:

```swift
// ❌ Using class with manual dispatch queue synchronization
final class SessionStoreOld {
    private var events: [SessionEvent] = []
    private let queue = DispatchQueue(label: "events", attributes: .concurrent)

    func append(_ event: SessionEvent) {
        queue.sync(flags: .barrier) { events.append(event) }  // Error-prone
    }
}
```

**When to deviate**: Use `@MainActor` classes (not custom actors) for SwiftUI view models with `@Published` properties, since `@StateObject`/`@ObservedObject` already leverage `@MainActor`. Use structs for simple immutable data models that don't need shared mutable state. Avoid actors for performance-critical paths where serialization overhead matters.

### Mark view model classes with @MainActor

**Rule**: Annotate all observable view model classes with `@MainActor` to guarantee UI updates happen on the main thread.

**Rationale**: In Xcode 16+, all SwiftUI `View` types automatically receive `@MainActor` isolation. However, explicitly marking view models with `@MainActor` ensures `@Published` property updates always occur on the main thread, works correctly when view models perform async/await work, and future-proofs code as Swift 6 removes implicit inference from property wrappers.

**Example**:

```swift
@MainActor
class MenuBarViewModel: ObservableObject {
    @Published var statusItems: [StatusItem] = []
    @Published var isLoading = false

    private let sessionStore: SessionStore

    func loadEvents() {
        Task {
            isLoading = true
            defer { isLoading = false }

            let events = try await sessionStore.fetchEvents()
            statusItems = events.map { StatusItem(from: $0) }
            // ✅ Safe: @MainActor guarantees main thread execution
        }
    }
}
```

**Anti-pattern**:

```swift
// ❌ Completion handler pattern - @MainActor has NO effect
@MainActor class ViewModel: ObservableObject {
    @Published var data: String = ""

    func fetchData() {
        networkService.fetch { [weak self] result in
            // ⚠️ This may NOT run on main thread!
            self?.data = result  // Potential crash
        }
    }
}
```

**When to deviate**: Use `nonisolated` for pure functions that don't access actor state. Use `MainActor.run {}` or `MainActor.assumeIsolated {}` when bridging callback-based APIs.

### Enforce Sendable correctness across actor boundaries

**Rule**: Mark types crossing actor boundaries as `Sendable` by using value types with Sendable properties, immutable final classes, or actor-isolated types. Avoid `@unchecked Sendable` except for internally-synchronized types.

**Rationale**: Sendable is the compiler's mechanism for ensuring thread-safe data transfer between isolation domains. Swift automatically infers Sendable for value types with all-Sendable stored properties, actors, and final classes with only constant Sendable properties.

**Example**:

```swift
// ✅ Value types: automatically Sendable if all properties are Sendable
struct ConversationEvent: Sendable {
    let id: UUID
    let timestamp: Date
    let eventType: EventType  // Must also be Sendable
}

// ✅ Final class with immutable Sendable properties
final class EventConfiguration: Sendable {
    let refreshInterval: TimeInterval
    let maxRetries: Int
}

// ✅ Using 'sending' parameter for non-Sendable in safe contexts (Swift 6)
actor DataProcessor {
    func process(data: sending Data) async -> ProcessedResult {
        // Compiler verifies 'data' is disconnected from caller
    }
}
```

**Anti-pattern**:

```swift
// ❌ Non-final class cannot be Sendable
class NetworkConfig: Sendable {  // Compiler error
    let baseURL: URL
}

// ❌ @unchecked Sendable without internal synchronization
class UnsafeCache: @unchecked Sendable {
    var items: [String: Data] = [:]  // Data race waiting to happen!
}
```

### Prefer structured concurrency over fire-and-forget tasks

**Rule**: Use structured concurrency (`async let`, `TaskGroup`) over unstructured (`Task {}`, `Task.detached`) to leverage automatic cancellation propagation and resource cleanup. Use `AsyncStream` for event-driven callbacks.

**Rationale**: Structured concurrency ensures child tasks cannot outlive their parent scope, providing automatic cancellation, priority inheritance, and error propagation. For menu bar apps with real-time events, `AsyncStream` bridges callback-based APIs into async/await while maintaining proper lifecycle management.

**Example**:

```swift
// ✅ AsyncStream for real-time event handling
func systemEventStream() -> AsyncStream<SystemEvent> {
    AsyncStream { continuation in
        let observer = NotificationCenter.default.addObserver(
            forName: .systemEventOccurred,
            object: nil,
            queue: nil
        ) { notification in
            if let event = notification.object as? SystemEvent {
                continuation.yield(event)
            }
        }

        // Critical: Clean up when stream terminates
        continuation.onTermination = { @Sendable _ in
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

// ✅ SwiftUI integration with automatic cancellation
struct MenuBarView: View {
    var body: some View {
        ContentView()
            .task {
                // Automatically cancelled when view disappears
                for await event in systemEventStream() {
                    await handleEvent(event)
                }
            }
    }
}
```

**Anti-pattern**:

```swift
// ❌ Fire-and-forget Task without lifecycle management
func startMonitoring() {
    Task {  // Who cancels this? Memory leak risk!
        while true {
            let status = await checkStatus()
            updateUI(status)
            try? await Task.sleep(for: .seconds(5))
        }
    }
}
```

**When to deviate**: Use unstructured `Task {}` in SwiftUI event handlers (button actions) where view lifecycle doesn't apply. Use `Task.detached` only when you explicitly need to escape inherited actor context and priority.

### Handle actor reentrancy defensively

**Rule**: Assume actor state may change across any `await`; validate assumptions after suspension points and use task-caching patterns to prevent duplicate work.

**Rationale**: Actor reentrancy means that while an actor method awaits an async call, other tasks can execute on that same actor. This prevents deadlocks but means state can change unexpectedly during suspension.

**Example**:

```swift
// ✅ Task-caching pattern to prevent duplicate network calls
actor TokenManager {
    private var cachedToken: String?
    private var refreshTask: Task<String, Error>?

    func getToken() async throws -> String {
        if let token = cachedToken, isValid(token) {
            return token
        }

        // If refresh already in progress, await same task
        if let existingTask = refreshTask {
            return try await existingTask.value
        }

        // Start new refresh, store BEFORE await
        let task = Task { try await performTokenRefresh() }
        refreshTask = task  // ✅ Set before suspension point

        do {
            let token = try await task.value
            cachedToken = token
            refreshTask = nil
            return token
        } catch {
            refreshTask = nil
            throw error
        }
    }
}
```

**Anti-pattern**:

```swift
// ❌ Assuming state unchanged after await
actor BrokenTokenManager {
    var token: String?

    func getToken() async throws -> String {
        if token == nil {
            // Multiple concurrent calls each start their own refresh!
            token = try await refreshToken()
        }
        return token!
    }
}
```

---

## 2. SwiftUI and AppKit interop

Modern SwiftUI (iOS 17+/macOS 14+) introduces the `@Observable` macro as the preferred observation mechanism, while AppKit integration remains essential for floating panel overlays and advanced menu bar features.

### Adopt @Observable with @State for owned models

**Rule**: Use `@Observable` macro with `@State` property wrapper for owned model objects instead of `ObservableObject` with `@StateObject`.

**Rationale**: The @Observable macro provides per-property change tracking—SwiftUI only redraws views when properties they actually access change, versus ObservableObject which triggers redraws for ANY @Published property change. This significantly reduces unnecessary view re-evaluations.

**Example**:

```swift
import Observation

@Observable
final class OverlayViewModel {
    private(set) var messages: [Message] = []
    private(set) var connectionStatus: ConnectionStatus = .disconnected
    var debugCounter: Int = 0  // Changes won't trigger UI updates if unused

    func loadMessages() async { /* ... */ }
}

struct OverlayView: View {
    @State var viewModel = OverlayViewModel()  // Use @State, not @StateObject

    var body: some View {
        VStack {
            Text("Status: \(viewModel.connectionStatus.description)")
            ForEach(viewModel.messages) { message in
                MessageRow(message: message)
            }
        }
    }
}
```

**Anti-pattern**:

```swift
// ❌ Legacy approach - triggers redraw for ANY @Published change
final class OverlayViewModel: ObservableObject {
    @Published private(set) var messages: [Message] = []
    @Published private(set) var debugCounter: Int = 0  // Changes here trigger ALL views!
}

struct OverlayView: View {
    @StateObject var viewModel = OverlayViewModel()  // ❌ @StateObject with @Published
}
```

**When to deviate**: Use ObservableObject when targeting macOS 13 or earlier, or when integrating with Combine pipelines that rely on `objectWillChange` publisher.

### Use @Bindable for creating bindings to @Observable objects

**Rule**: Use `@Bindable` property wrapper to create bindings to properties of @Observable objects; use it inline in body when the object comes from @Environment.

**Rationale**: @Observable objects don't provide projected values ($) automatically like @ObservedObject did. @Bindable wraps the observable to enable binding syntax.

**Example**:

```swift
@Observable
class SettingsModel {
    var apiEndpoint: String = ""
    var autoRefresh: Bool = true
}

// Option 1: @Bindable on property
struct SettingsView: View {
    @Bindable var settings: SettingsModel

    var body: some View {
        TextField("API Endpoint", text: $settings.apiEndpoint)
        Toggle("Auto Refresh", isOn: $settings.autoRefresh)
    }
}

// Option 2: Inline @Bindable for @Environment objects
struct EnvironmentSettingsView: View {
    @Environment(SettingsModel.self) private var settings

    var body: some View {
        @Bindable var settings = settings  // Create bindable inline
        TextField("API Endpoint", text: $settings.apiEndpoint)
    }
}
```

### Subclass NSPanel for floating overlay windows

**Rule**: Create floating overlay windows by subclassing `NSPanel` with `.nonactivatingPanel` style mask and `.floating` window level.

**Rationale**: NSPanel provides panel-specific behaviors like floating above other windows, hiding when app deactivates, and non-activating interaction essential for Dynamic Island-style overlays.

**Example**:

```swift
class FloatingPanel<Content: View>: NSPanel {
    @Binding var isPresented: Bool

    init(view: () -> Content, contentRect: NSRect, isPresented: Binding<Bool>) {
        self._isPresented = isPresented

        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        // Floating panel configuration
        isFloatingPanel = true
        level = .floating
        collectionBehavior.insert(.fullScreenAuxiliary)

        // Hide title bar but keep window moveable
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = true

        // Hide traffic lights
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        animationBehavior = .utilityWindow
        contentView = NSHostingView(rootView: view().ignoresSafeArea())
    }

    override func resignMain() {
        super.resignMain()
        close()
    }

    override func close() {
        super.close()
        isPresented = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
```

### Use MenuBarExtra for SwiftUI menu bar apps

**Rule**: Use `MenuBarExtra` scene type for menu bar apps; use `.menuBarExtraStyle(.window)` for custom UI beyond simple menus.

**Rationale**: MenuBarExtra (macOS 13+) is the native SwiftUI approach to menu bar items without AppKit bridging, with automatic lifecycle management.

**Example**:

```swift
@main
struct ConversationOverlayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Window-style for custom SwiftUI overlay
        MenuBarExtra("ConvoOverlay", systemImage: "bubble.left.and.bubble.right") {
            OverlayContentView()
                .frame(width: 400, height: 500)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}

// Hide dock icon: add LSUIElement = YES to Info.plist
```

**When to deviate**: Use NSStatusItem directly when needing right-click context menus, custom button behaviors, or targeting macOS 12.

### Use PhaseAnimator for multi-step animations

**Rule**: Use `PhaseAnimator` or `.phaseAnimator()` modifier for animations with discrete states/phases.

**Rationale**: PhaseAnimator provides declarative multi-step animations that are cleaner than manual state management with withAnimation, ideal for Dynamic Island-style transitions.

**Example**:

```swift
enum OverlayPhase: CaseIterable {
    case collapsed, expanding, expanded, collapsing

    var scale: CGFloat {
        switch self {
        case .collapsed: return 0.8
        case .expanding: return 1.1
        case .expanded: return 1.0
        case .collapsing: return 0.9
        }
    }

    var opacity: Double {
        switch self {
        case .collapsed, .collapsing: return 0.0
        case .expanding, .expanded: return 1.0
        }
    }
}

struct AnimatedOverlay: View {
    @State private var trigger = false

    var body: some View {
        OverlayContent()
            .phaseAnimator(OverlayPhase.allCases, trigger: trigger) { content, phase in
                content
                    .scaleEffect(phase.scale)
                    .opacity(phase.opacity)
            } animation: { phase in
                switch phase {
                case .expanding: .spring(duration: 0.25)
                case .collapsing: .easeOut(duration: 0.15)
                default: .default
                }
            }
    }
}
```

---

## 3. Event-driven architecture

Unidirectional data flow patterns provide predictable state management essential for real-time event handling. Model all state mutations as typed events flowing through a central reducer.

### Centralize state mutations through typed actions

**Rule**: All state mutations must flow through a single reducer function that processes typed actions and produces new state.

**Rationale**: Unidirectional data flow ensures predictable state changes, simplifies debugging by making cause and effect traceable, and eliminates scattered state management. For menu bar apps processing socket events, this creates a clear audit trail.

**Example**:

```swift
// State - Single source of truth
struct SessionState: Equatable {
    var messages: [Message] = []
    var connectionStatus: ConnectionStatus = .disconnected
    var isOverlayVisible: Bool = false
}

// Actions as enum with associated values
enum SessionAction {
    case messageReceived(Message)
    case connectionStatusChanged(ConnectionStatus)
    case toggleOverlay
    case clearMessages
    case socketError(Error)
}

// Pure reducer function
func sessionReducer(state: inout SessionState, action: SessionAction) {
    switch action {
    case .messageReceived(let message):
        state.messages.append(message)
    case .connectionStatusChanged(let status):
        state.connectionStatus = status
    case .toggleOverlay:
        state.isOverlayVisible.toggle()
    case .clearMessages:
        state.messages.removeAll()
    case .socketError:
        state.connectionStatus = .error
    }
}
```

### Model UI phases with enum-based state machines

**Rule**: Model UI phases as enum cases with associated values, and validate transitions by only allowing specific event→state pairs.

**Rationale**: State machines prevent degenerate states (showing loading AND error simultaneously), make impossible states impossible, and provide clear documentation of valid app flows.

**Example**:

```swift
enum ViewState<T> {
    case idle
    case loading(previousData: T?)
    case success(T)
    case error(Error, previousData: T?)
}

extension ViewState {
    mutating func handleEvent(_ event: LoadEvent<T>) {
        switch (self, event) {
        case (.idle, .startLoading):
            self = .loading(previousData: nil)
        case (.success(let data), .startLoading):
            self = .loading(previousData: data)
        case (.loading, .loadSuccess(let data)):
            self = .success(data)
        case (.loading(let prev), .loadFailure(let error)):
            self = .error(error, previousData: prev)
        case (.error(_, let prev), .retry):
            self = .loading(previousData: prev)
        default:
            break // Invalid transition - no-op
        }
    }
}
```

**Anti-pattern**:

```swift
// ❌ Multiple booleans create impossible states
class ViewModel {
    var isLoading = false
    var hasError = false
    var hasData = false
    // Can be loading AND hasError AND hasData simultaneously!
}
```

### Use CurrentValueSubject for state, PassthroughSubject for events

**Rule**: Use `CurrentValueSubject` when subscribers need immediate access to current value; use `PassthroughSubject` for discrete events relevant only at emission time.

**Rationale**: CurrentValueSubject maintains state and immediately delivers its current value to new subscribers. PassthroughSubject has no memory of past values—like a doorbell versus a light switch.

**Example**:

```swift
actor SessionStore {
    // CurrentValueSubject for state - new subscribers get current value
    let connectionState = CurrentValueSubject<ConnectionStatus, Never>(.disconnected)

    // PassthroughSubject for events - no replay for new subscribers  
    let socketEvents = PassthroughSubject<SocketEvent, Never>()

    func updateConnection(_ status: ConnectionStatus) {
        connectionState.send(status)
        // Or: connectionState.value = status
    }

    func emitEvent(_ event: SocketEvent) {
        socketEvents.send(event)
    }
}
```

### Apply debounce for search, throttle for scroll-like events

**Rule**: Use `debounce` when waiting for a pause in activity before processing; use `throttle` to limit emission rate to a maximum frequency.

**Example**:

```swift
class SearchViewModel: ObservableObject {
    @Published var searchText = ""
    @Published var results: [SearchResult] = []

    private var cancellables = Set<AnyCancellable>()

    init() {
        // DEBOUNCE: Wait 300ms after user stops typing
        $searchText
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .removeDuplicates()
            .filter { !$0.isEmpty }
            .flatMap { query in searchService.search(query) }
            .receive(on: DispatchQueue.main)
            .assign(to: &$results)
    }
}

// THROTTLE: Process scroll at most once per 100ms
scrollPosition
    .throttle(for: .milliseconds(100), scheduler: RunLoop.main, latest: true)
    .sink { position in updateVisibleItems(at: position) }
    .store(in: &cancellables)
```

---

## 4. Combine and async/await interop

Bridging Combine publishers with Swift concurrency enables gradual migration and interoperability between reactive and async paradigms.

### Bridge publishers to async with .values property

**Rule**: Use `.values` property to convert any Publisher to an AsyncSequence for iteration with `for await`; create custom `asyncMap` operators to call async functions within Combine pipelines.

**Example**:

```swift
// Publisher → AsyncSequence using .values
actor SocketHandler {
    private let eventSubject = CurrentValueSubject<SocketEvent?, Never>(nil)

    // Expose as AsyncSequence for structured concurrency
    var events: AsyncPublisher<AnyPublisher<SocketEvent?, Never>> {
        eventSubject.eraseToAnyPublisher().values
    }
}

// Usage with async/await
func processSocketEvents() async {
    for await event in await socketHandler.events {
        guard let event else { continue }
        await handleEvent(event)
    }
    // Loop ends when Task is cancelled or publisher completes
}

// Custom asyncMap for calling async within Combine
extension Publisher {
    func asyncMap<T>(
        _ transform: @escaping (Output) async throws -> T
    ) -> Publishers.FlatMap<Future<T, Error>, Self> {
        flatMap { value in
            Future { promise in
                Task {
                    do {
                        let output = try await transform(value)
                        promise(.success(output))
                    } catch {
                        promise(.failure(error))
                    }
                }
            }
        }
    }
}
```

### Prevent retain cycles with proper subscription management

**Rule**: Always use `[weak self]` in `sink` closures that capture self; prefer `assign(to: &$property)` over `assign(to:on:)` for @Published properties; store cancellables in the owning object.

**Rationale**: `assign(to:on:)` creates a strong reference cycle (subscription → self → subscriptions). AnyCancellable auto-cancels on dealloc, binding subscription lifetime to object lifetime.

**Example**:

```swift
// ❌ Anti-pattern: Creates retain cycle
class BadViewModel: ObservableObject {
    @Published var time: TimeInterval = 0
    private var cancellables = Set<AnyCancellable>()

    func start() {
        Timer.publish(every: 1, on: .main, in: .default)
            .autoconnect()
            .map(\.timeIntervalSince1970)
            .assign(to: \.time, on: self)  // Strong reference to self!
            .store(in: &cancellables)
    }
}

// ✅ Best practice: Use assign(to:) with @Published
class GoodViewModel: ObservableObject {
    @Published var time: TimeInterval = 0

    func start() {
        Timer.publish(every: 1, on: .main, in: .default)
            .autoconnect()
            .map(\.timeIntervalSince1970)
            .assign(to: &$time)  // Lifecycle managed by @Published
    }
}

// ✅ Alternative: Use [weak self] with sink
repository.dataPublisher
    .sink { [weak self] completion in
        if case .failure(let error) = completion {
            self?.handleError(error)
        }
    } receiveValue: { [weak self] data in
        self?.processData(data)
    }
    .store(in: &cancellables)
```

---

## 5. File I/O and JSONL parsing

Async file reading and streaming JSONL parsing are essential for conversation history handling. Use truly non-blocking I/O patterns that integrate with structured concurrency.

### Stream large files with FileHandle.bytes.lines

**Rule**: Use `FileHandle.bytes.lines` for memory-efficient streaming of large text files, especially JSONL.

**Rationale**: The AsyncSequence drives reading in chunks, keeping memory usage constant regardless of file size—critical for conversation histories that may contain thousands of entries.

**Example**:

```swift
struct JSONLParser<T: Decodable> {
    let decoder = JSONDecoder()

    func parse(from url: URL) -> AsyncThrowingStream<T, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let handle = try FileHandle(forReadingFrom: url)
                    for try await line in handle.bytes.lines {
                        guard !line.isEmpty else { continue }
                        let data = Data(line.utf8)
                        let item = try decoder.decode(T.self, from: data)
                        continuation.yield(item)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

// Usage
for try await message in JSONLParser<ConversationMessage>().parse(from: historyURL) {
    await sessionStore.append(message)
}
```

**Anti-pattern**:

```swift
// ❌ Loading entire file into memory
let content = try String(contentsOf: url)
let lines = content.split(separator: "\n")
// Memory spike for large files!
```

### Handle schema evolution with versioned Codable

**Rule**: Implement incremental migration by chaining version types with `PreviousVersion` associated types, or provide default values for new optional fields.

**Example**:

```swift
struct IPCMessage: Codable {
    var type: String
    var payload: Data
    var priority: Int = 0  // New field with default - old data decodes fine

    enum CodingKeys: String, CodingKey {
        case type, payload, priority
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        payload = try container.decode(Data.self, forKey: .payload)
        priority = try container.decodeIfPresent(Int.self, forKey: .priority) ?? 0
    }
}

// Property wrapper for missing arrays
@propertyWrapper
struct DefaultEmpty<T: Codable & RangeReplaceableCollection>: Codable {
    var wrappedValue: T

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        wrappedValue = (try? container.decode(T.self)) ?? T()
    }
}
```

---

## 6. Unix socket IPC with GCD DispatchSource

GCD DispatchSource provides event-driven socket I/O that integrates with Swift concurrency through AsyncStream bridging.

### Create dispatch sources for non-blocking socket I/O

**Rule**: Use `DISPATCH_SOURCE_TYPE_READ` dispatch sources with non-blocking file descriptors, always installing cancellation handlers for cleanup.

**Example**:

```swift
class UnixSocketConnection {
    private var readSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "socket.io")
    private var fd: Int32 = -1

    func connect(to path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.createFailed(errno) }

        // Set non-blocking
        var flags = fcntl(fd, F_GETFL)
        fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            _ = path.withCString { strncpy(ptr, $0, 104) }
        }

        // Connect...
        setupReadSource()
    }

    private func setupReadSource() {
        readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        readSource?.setEventHandler { [weak self] in
            self?.handleRead()
        }
        readSource?.setCancelHandler { [weak self] in
            if let fd = self?.fd, fd >= 0 { close(fd) }
        }
        readSource?.resume()
    }
}
```

### Wrap DispatchSource in AsyncStream for structured concurrency

**Rule**: Bridge GCD dispatch sources to Swift concurrency using AsyncStream with proper termination handling.

**Example**:

```swift
actor SocketActor {
    private var readSource: DispatchSourceRead?
    private let fd: Int32

    func dataStream() -> AsyncStream<Data> {
        AsyncStream { continuation in
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
            source.setEventHandler {
                var buffer = [UInt8](repeating: 0, count: 4096)
                let n = read(self.fd, &buffer, buffer.count)
                if n > 0 {
                    continuation.yield(Data(buffer[..<n]))
                } else if n == 0 {
                    continuation.finish()
                }
            }
            source.setCancelHandler {
                continuation.finish()
            }
            continuation.onTermination = { _ in
                source.cancel()
            }
            source.resume()
            self.readSource = source
        }
    }
}

// Usage with structured concurrency
for await data in await socketActor.dataStream() {
    try await processIncomingData(data)
}
```

### Implement exponential backoff with jitter for reconnection

**Rule**: Use exponential backoff with random jitter for reconnection to prevent thundering herd problems.

**Example**:

```swift
actor ReconnectionManager {
    private var attempt = 0
    private let maxAttempts = 10
    private let baseDelay: Double = 0.5
    private let maxDelay: Double = 60.0

    func reconnect(using connector: () async throws -> Void) async throws {
        while attempt < maxAttempts {
            try Task.checkCancellation()
            do {
                try await connector()
                attempt = 0  // Reset on success
                return
            } catch {
                attempt += 1
                let delay = calculateBackoff()
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        throw ConnectionError.maxRetriesExceeded
    }

    private func calculateBackoff() -> Double {
        let exponential = min(baseDelay * pow(2.0, Double(attempt)), maxDelay)
        let jitter = Double.random(in: 0...0.5) * exponential
        return exponential + jitter
    }
}
```

---

## 7. Testing async and actor code

Swift Testing (introduced at WWDC24) provides cleaner syntax for async testing with the `@Test` macro and `#expect` assertions.

### Use Swift Testing @Test macro and #expect assertions

**Rule**: Use the `@Test` macro for test functions and `#expect` macro for all assertions, replacing XCTest's multiple assertion variants.

**Rationale**: Swift Testing provides better failure diagnostics, automatic test discovery without naming conventions, and seamless async/await integration.

**Example**:

```swift
import Testing

@Test("SessionStore appends events correctly")
func sessionStoreAppend() async {
    let store = SessionStore()
    let event = SessionEvent(type: .messageReceived, timestamp: Date())

    await store.append(event)
    let events = await store.allEvents()

    #expect(events.count == 1)
    #expect(events.first?.type == .messageReceived)
}

// Parameterized tests
@Test("Connection status transitions", arguments: [
    (ConnectionStatus.disconnected, ConnectionStatus.connecting),
    (ConnectionStatus.connecting, ConnectionStatus.connected),
    (ConnectionStatus.connected, ConnectionStatus.disconnected)
])
func connectionTransitions(from: ConnectionStatus, to: ConnectionStatus) async {
    let store = SessionStore()
    await store.updateStatus(to)
    let status = await store.connectionStatus
    #expect(status == to)
}
```

**Anti-pattern (XCTest Legacy)**:

```swift
// ❌ Legacy XCTest approach
class SessionStoreTests: XCTestCase {
    func testAppendEvent() {
        XCTAssertEqual(events.count, 1)
        XCTAssertNotNil(events.first)
        XCTAssertTrue(events.first?.type == .messageReceived)
    }
}
```

### Test actors with async test functions and @MainActor

**Rule**: Mark test functions as `async` and use `await` when accessing actor-isolated properties; use `@MainActor` attribute when testing UI-related code.

**Example**:

```swift
@Test @MainActor
func viewModelLoadsMessages() async {
    let viewModel = OverlayViewModel()
    await viewModel.loadMessages()

    #expect(viewModel.messages.isEmpty == false)
    #expect(viewModel.connectionStatus == .connected)
}

// Using confirmation for event-based testing
@Test("Socket emits 10 events")
func socketEventCount() async {
    let socket = MockSocket()

    await confirmation(expectedCount: 10) { confirm in
        for await _ in socket.eventStream() {
            confirm()
        }
    }
}
```

### Test Combine publishers with continuations

**Rule**: Use `withCheckedContinuation` to bridge Combine publishers to async tests.

**Example**:

```swift
@Test("Publisher emits expected value")
func publisherTest() async throws {
    var cancellables: Set<AnyCancellable> = []
    let repository = DataRepository()

    await withCheckedContinuation { continuation in
        repository.dataPublisher
            .sink { data in
                #expect(data != nil)
                continuation.resume()
            }
            .store(in: &cancellables)
    }
}
```

---

## 8. Build and distribution

macOS menu bar apps distributed outside the App Store require Developer ID signing, notarization, and typically use Sparkle for auto-updates.

### Sign with Developer ID and enable Hardened Runtime

**Rule**: Sign with "Developer ID Application" certificate for macOS distribution outside the App Store; enable Hardened Runtime, which is required for notarization.

**Build Settings**:

- Code Signing Identity: `Developer ID Application`
- Development Team: `[Your Team ID]`
- Hardened Runtime: `YES`
- Code Sign on Copy: `YES`

**Entitlements** (for socket IPC and typical menu bar app needs):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "...">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
    <key>com.apple.security.cs.allow-jit</key>
    <true/>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
</dict>
</plist>
```

### Automate notarization with notarytool

**Rule**: Use `xcrun notarytool` for notarization (altool was deprecated November 2023); store credentials in keychain for automation.

**Example workflow**:

```bash
# Store credentials (one-time)
xcrun notarytool store-credentials "notarization-profile" \
    --apple-id "your@email.com" \
    --team-id "TEAMID123" \
    --password "app-specific-password"

# Submit and wait
xcrun notarytool submit MyApp.dmg \
    --keychain-profile "notarization-profile" \
    --wait

# Staple the ticket
xcrun stapler staple MyApp.dmg

# Verify
spctl --assess --type open --context context:primary-signature -v MyApp.dmg
```

### Integrate Sparkle 2 for auto-updates

**Rule**: Use Sparkle 2 via Swift Package Manager; configure EdDSA signing; host appcast.xml on HTTPS.

**Setup**:

1. Add package: `https://github.com/sparkle-project/Sparkle`
2. Generate EdDSA keys: `./bin/generate_keys`
3. Configure Info.plist with `SUFeedURL` and `SUPublicEDKey`

**SwiftUI Integration**:

```swift
import Sparkle

final class UpdaterViewModel: ObservableObject {
    let updater: SPUUpdater

    init() {
        updater = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        ).updater
    }

    func checkForUpdates() {
        updater.checkForUpdates()
    }
}

@main
struct MyMenuBarApp: App {
    @StateObject var updaterViewModel = UpdaterViewModel()

    var body: some Scene {
        MenuBarExtra("MyApp", systemImage: "star") {
            ContentView()
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    updaterViewModel.checkForUpdates()
                }
            }
        }
    }
}
```

---

## Legacy pattern reference

| Legacy Pattern | Modern Pattern (macOS 15+) |
|----------------|---------------------------|
| `ObservableObject` + `@Published` | `@Observable` macro |
| `@StateObject` | `@State` with @Observable |
| `@ObservedObject` | `let` or `@Bindable` |
| `@EnvironmentObject` | `@Environment` |
| Manual dispatch queue locks | Swift actors |
| `DispatchQueue.main.async` | `@MainActor` isolation |
| `XCTestCase` + `XCTAssert*` | `@Test` + `#expect` |
| `XCTestExpectation` | `confirmation()` or continuations |
| Fire-and-forget `Task {}` | Structured concurrency with `.task` |
| `assign(to:on:)` | `assign(to: &$property)` |
| Manual NSStatusItem | `MenuBarExtra` scene |

## Conclusion

Building modern macOS menu bar apps in Swift 5.9–6.x centers on **actor-isolated state stores** for thread-safe event handling, **@Observable** for efficient SwiftUI reactivity, and **structured concurrency** for predictable async lifecycles. The shift from ObservableObject to @Observable alone can dramatically reduce unnecessary view updates in real-time UIs.

For socket-based IPC, wrapping GCD DispatchSource in AsyncStream bridges low-level I/O with structured concurrency's automatic cancellation. JSONL streaming via `FileHandle.bytes.lines` keeps memory bounded regardless of conversation history size.

The testing story has evolved significantly—Swift Testing's `@Test` and `#expect` macros provide cleaner async test code than XCTest, while `confirmation()` replaces XCTestExpectation for event-based assertions. Distribution outside the App Store requires Developer ID signing, notarization via `notarytool`, and Sparkle 2 integration for seamless auto-updates.

Key patterns to internalize: always validate actor state after suspension points (reentrancy), use task-caching to prevent duplicate async work, prefer `assign(to: &$property)` over `assign(to:on:)` to avoid retain cycles, and structure all concurrent work to support automatic cancellation when views disappear or the app terminates.

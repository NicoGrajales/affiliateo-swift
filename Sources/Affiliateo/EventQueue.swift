import Foundation
#if canImport(Network)
import Network
#endif

/// EventQueue: durable best-effort delivery for analytics events.
///
/// Mirrors the @affiliateo/web and @affiliateo/react-native queues so all
/// three platforms behave consistently for merchants integrating across
/// web + RN + native iOS. The queue is per-process (singleton'd by the
/// Manager) and persists pending events to UserDefaults so they survive
/// app close / kill.
///
/// Architecture:
///   - In-memory `queue` array of QueuedEvent (id + request descriptor + retries)
///   - Persisted to UserDefaults under STORAGE_KEY as JSON on every mutation
///   - Background Timer fires every FLUSH_INTERVAL_SECS to attempt delivery
///   - NWPathMonitor pauses flushing while offline; an immediate flush
///     fires the moment connectivity returns (no waiting for the timer)
///   - Failed events bump a per-event retry counter; dropped after MAX_RETRIES
///
/// Why UserDefaults instead of FileManager / Keychain:
///   UserDefaults is the platform-idiomatic key-value store for small
///   structured data (think <1MB). At 100 events × ~500 bytes each
///   we're at 50 KB max, well inside UserDefaults' comfort zone.
///   FileManager would add async I/O overhead for no real benefit.
///
/// Caps (matched to web + RN for cross-platform consistency):
///   - maxRetries = 3
///   - maxQueueSize = 100      hard cap, FIFO drop on overflow
///   - flushIntervalSecs = 5   periodic auto-flush cadence
///   - sizeFlushThreshold = 10 trigger flush when queue grows past
final class EventQueue {
    // Wire format. Codable so JSONEncoder/JSONDecoder roundtrip works
    // for persistence. `payload` stored as Data (JSON-encoded) so we
    // don't need an Any-friendly Codable wrapper — the SDK builds the
    // payload as a [String: Any] dictionary, we serialize it once at
    // enqueue time and replay verbatim on flush.
    struct QueuedEvent: Codable {
        let id: String
        let endpoint: String
        let payloadJson: Data
        var retries: Int
    }

    private let storageKey = "affiliateo_event_queue"
    private let maxRetries = 3
    private let maxQueueSize = 100
    private let flushIntervalSecs: TimeInterval = 5
    private let sizeFlushThreshold = 10

    private let userDefaults: UserDefaults
    private var queue: [QueuedEvent] = []
    private var flushTimer: Timer?
    private var isFlushing = false
    private var shuttingDown = false
    // Optimistic default. NWPathMonitor's first callback flips this to
    // the real value within a few hundred ms of init.
    private var isConnected = true

    #if canImport(Network)
    private var pathMonitor: NWPathMonitor?
    private let monitorQueue = DispatchQueue(label: "com.affiliateo.network")
    #endif

    // Serial queue for all mutations so we never race a flush against an
    // enqueue. Cheap on iOS; the alternative would be a NSLock around
    // every field, which is more error-prone.
    private let serialQueue = DispatchQueue(label: "com.affiliateo.queue")

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        loadFromDisk()
        startNetworkMonitor()
        startFlushTimer()
        // Catch-up flush on init in case the previous app session ended
        // with events still queued. Best-effort: noops when offline.
        if !queue.isEmpty {
            scheduleFlush()
        }
    }

    /// Add an event to the queue. Returns immediately; persistence happens
    /// asynchronously on the serial queue.
    func enqueue(endpoint: String, payload: [String: Any]) {
        guard !shuttingDown else { return }
        // Serialize the payload synchronously so we don't capture a
        // mutable dictionary that could be modified by the caller after
        // enqueue returns. JSONSerialization is the cheapest path for
        // an [String: Any] payload.
        guard let payloadJson = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            return
        }
        let event = QueuedEvent(
            id: UUID().uuidString,
            endpoint: endpoint,
            payloadJson: payloadJson,
            retries: 0
        )
        serialQueue.async { [weak self] in
            guard let self = self else { return }
            self.queue.append(event)
            // FIFO drop when over cap. Network outage edge case: under
            // sustained failure the queue would grow until UserDefaults
            // started complaining. 100 events is a sane upper bound.
            if self.queue.count > self.maxQueueSize {
                self.queue.removeFirst(self.queue.count - self.maxQueueSize)
            }
            self.persist()
            if self.queue.count >= self.sizeFlushThreshold {
                self.scheduleFlush()
            }
        }
    }

    /// Try to deliver every queued event. Each event gets one attempt
    /// per flush; failures bump retries and stay queued. Events that
    /// hit maxRetries are dropped. Skipped entirely when offline.
    func flush() async {
        // Capture the work to do atomically off the serial queue, so the
        // network calls don't block other enqueue/flush calls.
        let snapshot: [QueuedEvent] = await withCheckedContinuation { cont in
            serialQueue.async { [weak self] in
                guard let self = self else { cont.resume(returning: []); return }
                if self.isFlushing || self.queue.isEmpty || !self.isConnected {
                    cont.resume(returning: [])
                    return
                }
                self.isFlushing = true
                cont.resume(returning: self.queue)
            }
        }
        if snapshot.isEmpty { return }

        // Per-event delivery. Sequential to keep the retry semantics
        // simple — head-of-line blocking is fine because all events go
        // to the same server and we already bound the snapshot.
        for event in snapshot {
            let ok = await sendOnce(event: event)
            await applyResult(event: event, ok: ok)
        }

        serialQueue.async { [weak self] in
            self?.persist()
            self?.isFlushing = false
        }
    }

    /// Wipe all queued events. Called by reset() and optOut().
    func clear() {
        serialQueue.async { [weak self] in
            guard let self = self else { return }
            self.queue.removeAll()
            self.userDefaults.removeObject(forKey: self.storageKey)
        }
    }

    /// Stop the timer + network monitor. Idempotent. Best-effort
    /// last flush attempt. Anything still queued persists to disk.
    func shutdown() {
        shuttingDown = true
        flushTimer?.invalidate()
        flushTimer = nil
        #if canImport(Network)
        pathMonitor?.cancel()
        pathMonitor = nil
        #endif
        Task { await self.flush() }
    }

    /// Read-only count. Used by tests / debug helpers.
    var size: Int {
        serialQueue.sync { queue.count }
    }

    // MARK: - Private

    private func loadFromDisk() {
        guard let data = userDefaults.data(forKey: storageKey) else { return }
        if let decoded = try? JSONDecoder().decode([QueuedEvent].self, from: data) {
            queue = decoded
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(queue) {
            userDefaults.set(data, forKey: storageKey)
        }
    }

    private func startFlushTimer() {
        flushTimer = Timer.scheduledTimer(withTimeInterval: flushIntervalSecs, repeats: true) { [weak self] _ in
            self?.scheduleFlush()
        }
    }

    private func scheduleFlush() {
        Task { await self.flush() }
    }

    private func startNetworkMonitor() {
        #if canImport(Network)
        // NWPathMonitor is iOS 12+ / macOS 10.14+; both well below our
        // minimum target. The first update callback fires within a few
        // hundred ms of start() and gives us the real current state.
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let wasOffline = !self.isConnected
            self.isConnected = path.status == .satisfied
            if wasOffline && self.isConnected {
                // Came back online — catch-up flush right now instead
                // of waiting up to flushIntervalSecs for the timer.
                self.scheduleFlush()
            }
        }
        monitor.start(queue: monitorQueue)
        pathMonitor = monitor
        #endif
    }

    private func sendOnce(event: QueuedEvent) async -> Bool {
        guard let url = URL(string: event.endpoint) else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = event.payloadJson
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                return true
            }
            return false
        } catch {
            return false
        }
    }

    private func applyResult(event: QueuedEvent, ok: Bool) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            serialQueue.async { [weak self] in
                guard let self = self else { cont.resume(); return }
                if ok {
                    self.queue.removeAll { $0.id == event.id }
                } else if let idx = self.queue.firstIndex(where: { $0.id == event.id }) {
                    self.queue[idx].retries += 1
                    if self.queue[idx].retries >= self.maxRetries {
                        self.queue.remove(at: idx)
                    }
                }
                cont.resume()
            }
        }
    }
}

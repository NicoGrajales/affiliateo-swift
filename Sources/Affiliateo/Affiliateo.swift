import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Main entry point for the Affiliateo SDK.
/// Wrap your app with `AffiliateoProvider` to start tracking.
///
/// ```swift
/// @main
/// struct MyApp: App {
///     var body: some Scene {
///         WindowGroup {
///             AffiliateoProvider(campaignId: "YOUR_CAMPAIGN_ID") {
///                 ContentView()
///             }
///         }
///     }
/// }
/// ```
public struct AffiliateoProvider<Content: View>: View {
    let campaignId: String
    let apiUrl: String
    let content: () -> Content

    @StateObject private var manager: AffiliateoManager

    public init(
        campaignId: String,
        apiUrl: String = "https://affiliateo.com",
        debug: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.campaignId = campaignId
        self.apiUrl = apiUrl
        self.content = content
        _manager = StateObject(wrappedValue: AffiliateoManager(
            campaignId: campaignId,
            apiUrl: apiUrl,
            debug: debug
        ))
    }

    public var body: some View {
        content()
            .environmentObject(manager)
            .onAppear { manager.start() }
    }
}

/// Access the affiliate ref code and attribution state from any view.
///
/// ```swift
/// struct ContentView: View {
///     @EnvironmentObject var affiliateo: AffiliateoManager
///
///     var body: some View {
///         if affiliateo.state.isMatched {
///             Text("Referred by: \(affiliateo.state.refCode ?? "")")
///         }
///     }
/// }
/// ```
public final class AffiliateoManager: ObservableObject {
    @Published public private(set) var state = AffiliateoState(
        refCode: nil,
        isMatched: false,
        isLoading: true,
        visitorId: nil
    )

    /// The most recently created manager. Used by the static `Affiliateo.page()`
    /// and `Affiliateo.track()` helpers so merchants can fire events without
    /// threading an `@EnvironmentObject` through every view.
    public internal(set) static weak var shared: AffiliateoManager?

    // Persistent opt-out flag. Mirrors @affiliateo/react-native 4.0.0 +
    // @affiliateo/web 3.0.0 behavior. When set to "true" the SDK silently
    // noops every outbound call until optIn() flips it. Stored in
    // UserDefaults so the flag survives app restarts; the
    // `@objc dynamic var` form isn't needed here because we only ever
    // read/write through the SDK's own methods.
    private static let optOutKey = "affiliateo_opt_out"

    private let campaignId: String
    private let apiUrl: String
    private let client: AffiliateoClient
    private var deviceId: String
    private let queue: EventQueue
    private var started = false
    // In-memory mirror of the on-disk opt-out flag. Hot-path check
    // inside every track/page/identify call; refreshed on optOut/optIn
    // calls so a mid-session decision applies immediately.
    private var isOptedOut: Bool
    // Debug flag. When true, every SDK decision (init, page, track,
    // identify, flush, opt in/out, reset) is printed to the Xcode console
    // via print(). Only useful during development. ship with debug=false
    // (the default) so production apps don't pay the print overhead AND
    // don't leak SDK internals to anyone running their app under a
    // debugger. Mirrors @affiliateo/web and @affiliateo/react-native.
    private let debug: Bool

    public init(
        campaignId: String,
        apiUrl: String = "https://affiliateo.com",
        debug: Bool = false
    ) {
        self.campaignId = campaignId
        self.apiUrl = apiUrl.hasSuffix("/") ? String(apiUrl.dropLast()) : apiUrl
        self.client = AffiliateoClient(apiUrl: apiUrl)
        self.deviceId = getStableDeviceId()
        self.queue = EventQueue()
        self.isOptedOut = UserDefaults.standard.string(forKey: AffiliateoManager.optOutKey) == "true"
        self.debug = debug
        AffiliateoManager.shared = self
    }

    /// Internal debug logger. No-op unless `debug: true` was passed to init.
    /// Single-arg form for messages without payload; two-arg form for
    /// messages with structured data. Output goes to the standard Xcode
    /// console (visible in DevTools / debug navigator while attached).
    private func log(_ msg: String, _ data: Any? = nil) {
        guard debug else { return }
        if let data = data {
            print("[Affiliateo] \(msg)", data)
        } else {
            print("[Affiliateo] \(msg)")
        }
    }

    /// Start tracking. Called automatically by AffiliateoProvider.
    /// Runs identify (mints visitor + matches affiliate) and registers the
    /// foreground keep-alive ping. Screens are NOT auto-tracked. the host
    /// app calls Affiliateo.page(name) per screen, matching the Mixpanel /
    /// Amplitude / Datafast mobile model.
    func start() {
        guard !started else { return }
        started = true

        // Opted-out fast path. Skip identify + foreground ping entirely.
        // The state is published with isLoading=false so any host UI
        // gated on it (e.g. a paywall waiting for the matched? check)
        // unblocks immediately. Public methods still exist and noop
        // until optIn() flips the flag back.
        if isOptedOut {
            log("blocked: opted out (call optIn() to re-enable)")
            self.state = AffiliateoState(
                refCode: nil,
                isMatched: false,
                isLoading: false,
                visitorId: nil,
                appAccountToken: nil
            )
            return
        }

        log("init", ["campaign": campaignId, "device": deviceId])
        Task {
            await identify()
        }

        // Keep the server-side session alive on foreground. The server's
        // start_mobile_session RPC handles rotation based on the 10-minute
        // inactivity timeout. No background screen_view. that was a ghost
        // event that polluted funnels.
        #if canImport(UIKit) && !os(watchOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        #endif
    }

    /// Fire a screen_view event for a specific screen.
    /// Call from `onAppear` in SwiftUI or `viewDidAppear` in UIKit.
    public func page(_ screenName: String, metadata: [String: Any]? = nil) {
        if isOptedOut { return }
        log("page", ["screen": screenName, "metadata": metadata as Any])
        // Build the wire payload here (instead of via client.sendEvents)
        // so we can enqueue it for retry. The endpoint + body shape match
        // what client.sendEvents would have sent.
        var event: [String: Any] = [
            "type": EventType.screenView.rawValue,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "screen": screenName,
        ]
        if let metadata = metadata { event["metadata"] = metadata }
        queue.enqueue(
            endpoint: "\(apiUrl)/api/v1/mobile/event",
            payload: [
                "campaign_id": campaignId,
                "device_id": deviceId,
                "events": [event],
            ]
        )
    }

    /// Fire a custom event with arbitrary name + metadata.
    public func track(_ eventName: String, metadata: [String: Any]? = nil) {
        if isOptedOut { return }
        log("track", ["event": eventName, "metadata": metadata as Any])
        var merged: [String: Any] = ["event": eventName]
        if let metadata = metadata {
            for (k, v) in metadata { merged[k] = v }
        }
        let event: [String: Any] = [
            "type": EventType.custom.rawValue,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "metadata": merged,
        ]
        queue.enqueue(
            endpoint: "\(apiUrl)/api/v1/mobile/event",
            payload: [
                "campaign_id": campaignId,
                "device_id": deviceId,
                "events": [event],
            ]
        )
    }

    /// Wipe the device identity. Drains pending events first (they land
    /// server-side under the OLD device_id which is correct), then clears
    /// the queue, regenerates the device_id, and resets state. Call on
    /// app logout when a different user might sign in afterwards
    /// (shared family iPad, kiosk app). Without this, the next user's
    /// actions get merged into the previous user's funnel.
    public func reset() {
        log("reset")
        Task {
            await queue.flush()
            queue.clear()
            // Reset the on-disk device_id cache so getStableDeviceId
            // mints a fresh one. The platform IDFV is tied to the
            // bundle and we can't change it; only the UUID fallback
            // (when IDFV unavailable) gets fresh entropy.
            // Key must match the one DeviceId.swift writes to. Earlier
            // versions used "affiliateo_device_id_fallback" here which
            // was a no-op since DeviceId.swift actually stores under
            // "com.affiliateo.device_id".
            UserDefaults.standard.removeObject(forKey: "com.affiliateo.device_id")
            self.deviceId = getStableDeviceId()
            await MainActor.run {
                self.state = AffiliateoState(
                    refCode: nil,
                    isMatched: false,
                    isLoading: false,
                    visitorId: nil,
                    appAccountToken: nil
                )
            }
        }
    }

    /// Stop tracking on this device. Sets the persistent opt-out flag
    /// in UserDefaults and silences ALL subsequent page / track /
    /// identify calls until optIn() is called. Survives app restart.
    /// Pending queued events are dropped — the visitor explicitly said
    /// no, sending events captured before the decision would still
    /// violate consent. Use for GDPR/CCPA "Don't track me" consent.
    public func optOut() {
        log("optOut")
        isOptedOut = true
        UserDefaults.standard.set("true", forKey: AffiliateoManager.optOutKey)
        queue.clear()
    }

    /// Re-enable tracking after a previous optOut(). The auto session
    /// start that fires on provider mount won't retroactively replay —
    /// to resume immediately the host should reinitialize the manager
    /// (e.g. tear down and re-create AffiliateoProvider).
    public func optIn() {
        log("optIn")
        isOptedOut = false
        UserDefaults.standard.removeObject(forKey: AffiliateoManager.optOutKey)
    }

    /// Force-drain the event queue immediately. Useful before a known
    /// unrecoverable transition (entering an in-app purchase flow,
    /// app about to be backgrounded for a long time). Best-effort: if
    /// offline the flush noops and events stay queued for the next
    /// retry cycle.
    public func flush() async {
        log("flush requested")
        await queue.flush()
    }

    /// Link this anonymous device install to a merchant user_id so the
    /// funnel can stitch the same person across devices, reinstalls,
    /// and the anonymous to logged-in handoff. Call once after sign-in.
    /// Idempotent: safe to call on every app launch when a user is
    /// signed in.
    ///
    /// user_id only. the SDK does NOT accept, collect, or transmit
    /// email or any other PII.
    public func identify(_ userId: String) {
        let cleanId = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanId.isEmpty, cleanId.count <= 128 else { return }
        log("identify (user)", ["user_id": cleanId])
        Task {
            try? await client.identifyUser(
                campaignId: campaignId,
                deviceId: deviceId,
                userId: cleanId
            )
        }
    }

    private func identify() async {
        do {
            let deviceInfo = DeviceInfo.current()
            let result = try await client.identify(
                campaignId: campaignId,
                deviceId: deviceId,
                deviceInfo: deviceInfo
            )

            // Apple native IAP attribution. Mint a stable UUID per
            // (campaignId, refCode) so the customer's purchase chain (initial
            // buy + every renewal + refund) all carry the same token Apple
            // stamped at first purchase. Customer's purchase code reads it
            // via state.appAccountToken and passes it as
            // .appAccountToken(uuid) to StoreKit 2's product.purchase(options:).
            //
            // Best-effort: registration failure here means the next launch
            // retries (the backend dedups via mobile_app_visitors unique
            // constraint).
            var appleToken: UUID? = nil
            if let refCode = result.refCode {
                appleToken = Affiliateo.getOrMintAppleAccountToken(campaignId: campaignId, refCode: refCode)
                if let token = appleToken {
                    Task {
                        try? await client.registerAppleToken(
                            campaignId: campaignId,
                            visitorId: result.visitorId,
                            token: token
                        )
                    }
                }
            }

            await MainActor.run {
                self.state = AffiliateoState(
                    refCode: result.refCode,
                    isMatched: result.matched,
                    isLoading: false,
                    visitorId: result.visitorId,
                    appAccountToken: appleToken
                )
            }
            log("identify success", [
                "visitor": result.visitorId,
                "matched": result.matched,
                "ref": result.refCode as Any,
            ])

            // Auto-set RevenueCat attribute if matched
            if let refCode = result.refCode {
                setRevenueCatAttribute(refCode: refCode)
            }
        } catch {
            log("identify failed (network error)")
            await MainActor.run {
                self.state = AffiliateoState(
                    refCode: nil,
                    isMatched: false,
                    isLoading: false,
                    visitorId: nil,
                    appAccountToken: nil
                )
            }
        }
    }

    /// Get or mint a stable StoreKit 2 appAccountToken for this affiliate match.
    /// Persisted in UserDefaults keyed by (campaignId, refCode) so the same UUID
    /// is reused across app launches for the same affiliate (binding the whole
    /// purchase chain to one affiliate).
    private static func getOrMintAppleAccountToken(campaignId: String, refCode: String) -> UUID {
        let key = "affiliateo_apple_token:\(campaignId):\(refCode)"
        if let existing = UserDefaults.standard.string(forKey: key),
           let uuid = UUID(uuidString: existing) {
            return uuid
        }
        let fresh = UUID()
        UserDefaults.standard.set(fresh.uuidString, forKey: key)
        return fresh
    }

    private func setRevenueCatAttribute(refCode: String) {
        // Try to set RevenueCat attribute if the SDK is available
        // Uses dynamic lookup to avoid a hard dependency on RevenueCat
        guard let purchasesClass = NSClassFromString("RCPurchases") as? NSObject.Type else { return }

        let sharedSelector = NSSelectorFromString("sharedPurchases")
        guard purchasesClass.responds(to: sharedSelector),
              let shared = purchasesClass.perform(sharedSelector)?.takeUnretainedValue() else { return }

        let setAttrSelector = NSSelectorFromString("setAttributes:")
        if shared.responds(to: setAttrSelector) {
            shared.perform(setAttrSelector, with: ["affiliateo_ref": refCode])
        }
    }

    @objc private func appDidBecomeActive() {
        if isOptedOut { return }
        // Route through the queue so foreground pings survive a flaky
        // network the way regular page/track events do. The server's
        // start_mobile_session RPC is idempotent so a duplicate from a
        // queue retry just no-ops.
        let event: [String: Any] = [
            "type": EventType.sessionStart.rawValue,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
        ]
        queue.enqueue(
            endpoint: "\(apiUrl)/api/v1/mobile/event",
            payload: [
                "campaign_id": campaignId,
                "device_id": deviceId,
                "events": [event],
            ]
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        // Persist any in-flight queue state and stop background timers.
        // Anything still queued stays on disk for the next launch.
        queue.shutdown()
    }
}

// MARK: - Static helpers

/// Top-level namespace for firing screen_view / custom events without
/// threading `@EnvironmentObject var affiliateo: AffiliateoManager` through
/// every view. No-op if `AffiliateoProvider` hasn't been mounted yet.
public enum Affiliateo {
    /// Fire a screen_view event. Call from `.onAppear` or `viewDidAppear`.
    public static func page(_ screenName: String, metadata: [String: Any]? = nil) {
        AffiliateoManager.shared?.page(screenName, metadata: metadata)
    }

    /// Fire a custom event with arbitrary name + metadata.
    public static func track(_ eventName: String, metadata: [String: Any]? = nil) {
        AffiliateoManager.shared?.track(eventName, metadata: metadata)
    }

    /// Link this anonymous device install to a merchant user_id.
    /// user_id only. the SDK does NOT accept, collect, or transmit
    /// email or any other PII. See `AffiliateoManager.identify` for
    /// the full doc.
    public static func identify(_ userId: String) {
        AffiliateoManager.shared?.identify(userId)
    }

    /// Wipe the device identity. Call on app logout when a different
    /// person might use this device afterwards. See
    /// `AffiliateoManager.reset` for full doc.
    public static func reset() {
        AffiliateoManager.shared?.reset()
    }

    /// Stop tracking on this device. Persistent across app restarts.
    /// Use for GDPR/CCPA "Don't track me" consent.
    public static func optOut() {
        AffiliateoManager.shared?.optOut()
    }

    /// Re-enable tracking after a previous optOut(). Host should
    /// reinitialize the provider to fully resume.
    public static func optIn() {
        AffiliateoManager.shared?.optIn()
    }

    /// Force-drain the event queue immediately. Best-effort. See
    /// `AffiliateoManager.flush` for full doc.
    public static func flush() async {
        await AffiliateoManager.shared?.flush()
    }
}

// MARK: - SwiftUI screen helper

/// One-line screen tracking modifier. Replaces the old pattern of:
///   ContentView()
///       .onAppear { Affiliateo.page("HomeScreen") }
///
/// With:
///   ContentView()
///       .trackedScreen("HomeScreen")
///
/// Mirrors @affiliateo/react-native's useAffiliateoScreen hook and
/// Datafast's useDataFastScreen hook. The metadata closure is fired
/// lazily so a screen that builds metadata from runtime state (a user
/// tier, an A/B variant) doesn't pay the cost on every render.
public extension View {
    /// Fire a screen_view event when this view first appears.
    /// Idempotent across re-renders: only the first `.onAppear` call
    /// per view instance fires.
    func trackedScreen(_ screenName: String, metadata: [String: Any]? = nil) -> some View {
        modifier(TrackedScreenModifier(screenName: screenName, metadata: metadata))
    }
}

private struct TrackedScreenModifier: ViewModifier {
    let screenName: String
    let metadata: [String: Any]?
    // Track-fired flag scoped to the view instance so re-renders don't
    // re-fire. SwiftUI's @State semantics make this stable across body
    // recomputations but reset on view-identity changes (e.g. NavigationStack
    // pushing a fresh screen of the same type, which is correctly counted
    // as a separate visit).
    @State private var fired = false

    func body(content: Content) -> some View {
        content.onAppear {
            if !fired {
                fired = true
                Affiliateo.page(screenName, metadata: metadata)
            }
        }
    }
}

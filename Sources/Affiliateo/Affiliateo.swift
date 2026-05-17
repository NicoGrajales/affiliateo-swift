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
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.campaignId = campaignId
        self.apiUrl = apiUrl
        self.content = content
        _manager = StateObject(wrappedValue: AffiliateoManager(campaignId: campaignId, apiUrl: apiUrl))
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

    private let campaignId: String
    private let client: AffiliateoClient
    private let deviceId: String
    private var started = false

    public init(campaignId: String, apiUrl: String = "https://affiliateo.com") {
        self.campaignId = campaignId
        self.client = AffiliateoClient(apiUrl: apiUrl)
        self.deviceId = getStableDeviceId()
    }

    /// Start tracking. Called automatically by AffiliateoProvider.
    func start() {
        guard !started else { return }
        started = true

        // Identify + session start
        Task {
            await identify()
        }

        // Listen for app going to background / foreground
        #if canImport(UIKit) && !os(watchOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        // No background observer — server handles inactivity via 10-minute timeout
        #endif
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

            // Auto-set RevenueCat attribute if matched
            if let refCode = result.refCode {
                setRevenueCatAttribute(refCode: refCode)
            }
        } catch {
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
        Task {
            try? await client.sendEvents(
                campaignId: campaignId,
                deviceId: deviceId,
                events: [MobileEvent(type: .sessionStart)]
            )
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

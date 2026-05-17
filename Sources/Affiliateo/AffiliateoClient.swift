import Foundation

/// HTTP client for communicating with the Affiliateo API.
final class AffiliateoClient {
    private let apiUrl: String

    init(apiUrl: String = "https://affiliateo.com") {
        self.apiUrl = apiUrl.hasSuffix("/") ? String(apiUrl.dropLast()) : apiUrl
    }

    /// Identify this device to the Affiliateo API and get attribution info.
    func identify(campaignId: String, deviceId: String, deviceInfo: DeviceInfo) async throws -> IdentifyResponse {
        let url = URL(string: "\(apiUrl)/api/v1/mobile/identify")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "campaign_id": campaignId,
            "device_id": deviceId,
            "device_model": deviceInfo.deviceModel,
            "os": deviceInfo.os,
            "os_version": deviceInfo.osVersion,
            "app_version": deviceInfo.appVersion,
            "screen_width": deviceInfo.screenWidth,
            "screen_height": deviceInfo.screenHeight,
            "timezone": deviceInfo.timezone,
            "language": deviceInfo.language,
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw AffiliateoError.identifyFailed
        }

        let result = try JSONDecoder().decode(IdentifyResponse.self, from: data)
        return result
    }

    /// Send a batch of session events (session_start, session_end).
    func sendEvents(campaignId: String, deviceId: String, events: [MobileEvent]) async throws {
        if events.isEmpty { return }

        let url = URL(string: "\(apiUrl)/api/v1/mobile/event")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let eventsArray: [[String: Any]] = events.map { event in
            [
                "type": event.type.rawValue,
                "timestamp": event.timestamp,
            ]
        }

        let body: [String: Any] = [
            "campaign_id": campaignId,
            "device_id": deviceId,
            "events": eventsArray,
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw AffiliateoError.eventSendFailed
        }
    }

    /// Bind a StoreKit 2 appAccountToken to this visitor on the server. After
    /// this returns, Apple notifications carrying this UUID in
    /// signedTransactionInfo.appAccountToken resolve to the same affiliate
    /// the visitor is matched to.
    func registerAppleToken(campaignId: String, visitorId: String, token: UUID) async throws {
        let url = URL(string: "\(apiUrl)/api/v1/mobile/apple-token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Apple's appAccountToken serializes to lowercase UUID by convention.
        let body: [String: Any] = [
            "campaign_id": campaignId,
            "visitor_id": visitorId,
            "token": token.uuidString.lowercased(),
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)

        // Best-effort: a 4xx here means the visitor isn't bindable (e.g.
        // campaign doesn't have Apple connected yet). Treat as non-fatal —
        // the caller still gets the local token and can retry next launch.
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw AffiliateoError.appleTokenRegisterFailed
        }
    }
}

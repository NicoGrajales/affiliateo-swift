import Foundation
#if canImport(UIKit)
import UIKit
#endif

extension DeviceInfo {
    /// Collects current device information automatically.
    static func current(appVersion: String? = nil) -> DeviceInfo {
        var model = "Unknown"
        var screenWidth = 0
        var screenHeight = 0

        #if canImport(UIKit) && !os(watchOS)
        model = UIDevice.current.model // "iPhone", "iPad", etc.
        let screen = UIScreen.main.bounds
        screenWidth = Int(screen.width)
        screenHeight = Int(screen.height)
        #endif

        let version = appVersion
            ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? "1.0.0"

        return DeviceInfo(
            deviceModel: model,
            os: "iOS",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            appVersion: version,
            screenWidth: screenWidth,
            screenHeight: screenHeight,
            timezone: TimeZone.current.identifier,
            language: Locale.current.languageCode ?? "en"
        )
    }
}

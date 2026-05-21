# Affiliateo Swift SDK

Mobile affiliate attribution and session tracking for iOS apps (SwiftUI & UIKit).

## Installation

In Xcode: **File → Add Package Dependencies** → paste this URL:

```
https://github.com/affiliateo/affiliateo-swift
```

## Usage (SwiftUI)

Wrap your app with `AffiliateoProvider`:

```swift
import SwiftUI
import Affiliateo

@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            AffiliateoProvider(campaignId: "YOUR_CAMPAIGN_ID") {
                ContentView()
            }
        }
    }
}
```

Access the attribution state from any view:

```swift
struct ContentView: View {
    @EnvironmentObject var affiliateo: AffiliateoManager

    var body: some View {
        if affiliateo.state.isMatched {
            Text("Referred by: \(affiliateo.state.refCode ?? "")")
        }
    }
}
```

## Track screens (manual)

Screens are tracked when you call `Affiliateo.page(name)` per screen. This matches the Mixpanel / Amplitude / Datafast model. predictable, no ghost events polluting funnels.

```swift
struct HomeScreen: View {
    var body: some View {
        YourScreenUI()
            .onAppear {
                Affiliateo.page("HomeScreen")
            }
    }
}
```

## Track custom events

For buttons or other moments that matter (signup, trial start, etc.):

```swift
Button("Continue") {
    Affiliateo.track("signup_completed")
    onNext()
}
```

## What it does

- **Identifies the device** using Apple's built-in IDFV (no permissions needed)
- **Tracks sessions** automatically (app foreground)
- **Matches affiliate referrals** via fingerprint matching
- **Sets RevenueCat attributes** automatically if RevenueCat is installed
- **IAP attribution** via StoreKit 2 `appAccountToken`

## Requirements

- iOS 15+
- Swift 5.9+

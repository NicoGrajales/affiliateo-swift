// swift-tools-version: 5.9
//
// SDK version: 3.0.0
// Swift Package Manager resolves the actual version from git tags, not
// from this file. The marker above documents the current source state
// so casual readers don't have to cross-reference the latest tag.
// Matches the @affiliateo/web 3.0.0 + @affiliateo/react-native 4.0.0 +
// affiliateo-kotlin 3.0.0 + affiliateo-flutter 3.0.0 parity work.

import PackageDescription

let package = Package(
    name: "Affiliateo",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "Affiliateo",
            targets: ["Affiliateo"]
        ),
    ],
    targets: [
        .target(
            name: "Affiliateo",
            path: "Sources/Affiliateo"
        ),
    ]
)

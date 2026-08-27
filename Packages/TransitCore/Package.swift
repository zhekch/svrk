// swift-tools-version:6.0
//
// The whole of the Node server's `lib/` and the browser's positioning code,
// as one platform-independent Swift module.
//
// Kept out of the app target on purpose: none of this needs UIKit, Mapbox or a
// simulator, so it builds and tests on the host in a second or two. That is
// what makes the port checkable against the JavaScript it came from.
import PackageDescription

let package = Package(
    name: "TransitCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "TransitCore", targets: ["TransitCore"]),
    ],
    targets: [
        .target(
            name: "TransitCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)

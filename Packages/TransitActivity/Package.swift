// swift-tools-version:6.0
//
// The Live Activity payload and its lock-screen / Dynamic Island drawing.
// Kept off TransitCore so the widget never pulls the timetable, and so the
// same ActivityAttributes type is compiled into one module that both the app
// and the extension can see — ActivityKit matches on that identity.
import PackageDescription

let package = Package(
    name: "TransitActivity",
    platforms: [.iOS("16.2"), .macOS(.v13)],
    products: [
        .library(name: "TransitActivity", targets: ["TransitActivity"]),
    ],
    targets: [
        .target(
            name: "TransitActivity",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "TransitActivityTests",
            dependencies: ["TransitActivity"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)

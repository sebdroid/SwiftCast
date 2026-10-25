// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftCast",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .tvOS(.v17),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "SwiftCast", targets: ["SwiftCast"]),
    ],
    targets: [
        .target(
            name: "SwiftCast",
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .executableTarget(
            name: "castctl",
            dependencies: ["SwiftCast"]
        ),
        .testTarget(
            name: "SwiftCastTests",
            dependencies: ["SwiftCast"]
        ),
    ],
    swiftLanguageModes: [.v6]
)

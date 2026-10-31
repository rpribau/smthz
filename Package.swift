// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "SmthzCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SmthzCore", targets: ["SmthzCore"]),
        .executable(name: "smthz", targets: ["smthz"]),
        .executable(name: "smthzd", targets: ["smthzd"]),
        .executable(name: "SmthzApp", targets: ["SmthzApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.99.1"),
        .package(url: "https://github.com/jpsim/Yams", exact: "6.2.2")
    ],
    targets: [
        .target(
            name: "SmthzCore",
            dependencies: [.product(name: "Yams", package: "Yams")],
            swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]
        ),
        .executableTarget(
            name: "smthz",
            dependencies: ["SmthzCore"]
        ),
        .executableTarget(name: "smthzd", dependencies: ["SmthzCore"]),
        .executableTarget(name: "SmthzApp", dependencies: [
            "SmthzCore",
            .product(name: "SwiftTerm", package: "SwiftTerm")
        ]),
        .testTarget(
            name: "SmthzCoreTests",
            dependencies: ["SmthzCore"],
            swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]
        )
    ]
)

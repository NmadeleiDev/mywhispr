// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MyWhispr",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "MyWhispr", targets: ["MyWhispr"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.6"),
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
    ],
    targets: [
        .executableTarget(
            name: "MyWhispr",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            resources: [.process("Resources")],
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "MyWhisprTests",
            dependencies: [
                "MyWhispr",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
    ]
)

// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BatteryKeeper",
    defaultLocalization: "en",
    platforms: [
        .macOS("27.0"),
    ],
    products: [
        .library(name: "BatteryKeeperCore", targets: ["BatteryKeeperCore"]),
        .library(name: "BatteryKeeperSystem", targets: ["BatteryKeeperSystem"]),
        .library(name: "BatteryKeeperHelperKit", targets: ["BatteryKeeperHelperKit"]),
    ],
    targets: [
        // Pure logic: battery model, calibration cycle, schedule, adapter lease, icon model, statistics.
        .target(name: "BatteryKeeperCore"),
        // C and Objective-C glue: the AppleSMC user client and the private PowerUI client.
        .target(
            name: "BatteryKeeperBridge",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("IOKit"),
            ]
        ),
        // Adapters for IOKit, SMC, PowerUI, the helper connection, login items and the statistics store.
        .target(
            name: "BatteryKeeperSystem",
            dependencies: ["BatteryKeeperCore", "BatteryKeeperBridge"],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        // The privileged helper: the adapter lease enforcer and its XPC listener.
        .target(
            name: "BatteryKeeperHelperKit",
            dependencies: ["BatteryKeeperCore", "BatteryKeeperSystem", "BatteryKeeperBridge"]
        ),
        .testTarget(
            name: "BatteryKeeperCoreTests",
            dependencies: ["BatteryKeeperCore"]
        ),
        .testTarget(
            name: "BatteryKeeperSystemTests",
            dependencies: ["BatteryKeeperSystem", "BatteryKeeperCore"]
        ),
        .testTarget(
            name: "BatteryKeeperHelperKitTests",
            dependencies: ["BatteryKeeperHelperKit", "BatteryKeeperCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)

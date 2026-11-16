// swift-tools-version: 6.0
import Foundation
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

// Без Xcode (только Command Line Tools) Swift Testing лежит отдельно — подключаем явно.
let cltFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let hasCLTTesting = FileManager.default.fileExists(atPath: cltFrameworks + "/Testing.framework")
let testSwift: [SwiftSetting] = v5 + (hasCLTTesting ? [.unsafeFlags(["-F", cltFrameworks, "-Xfrontend", "-disable-cross-import-overlays"])] : [])
let testLink: [LinkerSetting] = hasCLTTesting
    ? [.unsafeFlags(["-F", cltFrameworks, "-Xlinker", "-rpath", "-Xlinker", cltFrameworks])]
    : []

let package = Package(
    name: "AgentHUD",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "AgentHUD", targets: ["AgentHUD"]),
        .executable(name: "agenthud-hook", targets: ["agenthud-hook"]),
    ],
    targets: [
        .target(name: "AgentHUDCore", swiftSettings: v5),
        .executableTarget(name: "agenthud-hook", dependencies: ["AgentHUDCore"], swiftSettings: v5),
        .executableTarget(name: "AgentHUD", dependencies: ["AgentHUDCore"], swiftSettings: v5),
        // Тесты — исполняемый таргет: без Xcode `swift test` не запускает Swift Testing,
        // поэтому раннер вызываем сами: `swift run agenthud-tests`.
        .executableTarget(
            name: "agenthud-tests",
            dependencies: ["AgentHUDCore"],
            path: "Tests/AgentHUDCoreTests",
            resources: [.copy("Fixtures")],
            swiftSettings: testSwift,
            linkerSettings: testLink + [.linkedFramework("Testing")]
        ),
    ]
)

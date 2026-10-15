// swift-tools-version:5.9
// CellarCore: platform-independent world, simulation, input, session and sound
// synthesis. The iOS app compiles these same sources; this package lets the
// logic be tested with `swift test` on macOS or Linux without a device.
import PackageDescription

let package = Package(
    name: "CellarCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "CellarCore", targets: ["CellarCore"])],
    targets: [
        .target(name: "CellarCore", path: "Sources/CellarCore"),
        .testTarget(name: "CellarCoreTests", dependencies: ["CellarCore"], path: "Tests/CellarCoreTests"),
    ]
)

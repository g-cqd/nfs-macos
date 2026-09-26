// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "NFSMWMac",
  platforms: [.macOS(.v15)],
  products: [
    .executable(name: "NFSMWLauncher", targets: ["NFSMWLauncher"]),
    .executable(name: "NFSMWSession", targets: ["NFSMWSession"]),
  ],
  targets: [
    .target(name: "LauncherCore"),
    .executableTarget(name: "NFSMWSession", dependencies: ["LauncherCore"]),
    .executableTarget(name: "NFSMWLauncher", dependencies: ["LauncherCore"]),
    .testTarget(name: "LauncherCoreTests", dependencies: ["LauncherCore"], resources: [.copy("Fixtures")]),
    .testTarget(name: "LauncherUITests", dependencies: ["NFSMWLauncher", "LauncherCore"]),
  ],
  swiftLanguageModes: [.v6]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "NFSMWMac",
  platforms: [.macOS(.v15)],
  products: [
    .executable(name: "NFSMWLauncher", targets: ["NFSMWLauncher"]),
    .executable(name: "NFSMWSession", targets: ["NFSMWSession"]),
    .executable(name: "CoD4Launcher", targets: ["CoD4Launcher"]),
    .executable(name: "CoD4Session", targets: ["CoD4Session"]),
  ],
  targets: [
    .target(name: "LauncherCore"),
    .target(name: "SharedLauncher", dependencies: ["LauncherCore"]),
    .target(name: "CoD4Core", dependencies: ["LauncherCore"]),
    .target(name: "FarCry2Core", dependencies: ["LauncherCore"]),
    .target(name: "GameFixtures", dependencies: ["LauncherCore"], path: "Tests/GameFixtures"),
    .executableTarget(name: "CoD4Session", dependencies: ["LauncherCore", "CoD4Core"]),
    .executableTarget(
      name: "CoD4Launcher", dependencies: ["LauncherCore", "CoD4Core", "SharedLauncher"]),
    .executableTarget(name: "NFSMWSession", dependencies: ["LauncherCore"]),
    .executableTarget(name: "NFSMWLauncher", dependencies: ["LauncherCore", "SharedLauncher"]),
    .testTarget(
      name: "LauncherCoreTests", dependencies: ["LauncherCore", "GameFixtures"],
      resources: [.copy("Fixtures")]),
    .testTarget(
      name: "LauncherUITests", dependencies: ["NFSMWLauncher", "LauncherCore", "SharedLauncher"]),
    .testTarget(name: "CoD4CoreTests", dependencies: ["CoD4Core", "LauncherCore"]),
    .testTarget(
      name: "FarCry2CoreTests",
      dependencies: ["FarCry2Core", "LauncherCore", "GameFixtures"]),
    .testTarget(
      name: "CoD4UITests",
      dependencies: ["CoD4Launcher", "CoD4Core", "LauncherCore", "SharedLauncher"]),
  ],
  swiftLanguageModes: [.v6]
)

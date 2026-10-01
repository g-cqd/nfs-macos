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
    .executable(name: "NFS2015Launcher", targets: ["NFS2015Launcher"]),
    .executable(name: "NFS2015Session", targets: ["NFS2015Session"]),
  ],
  targets: [
    .target(name: "LauncherCore"),
    .target(name: "SharedLauncher", dependencies: ["LauncherCore"]),
    .target(name: "CoD4Core", dependencies: ["LauncherCore"]),
    .target(name: "NFS2015Core", dependencies: ["LauncherCore"]),
    .executableTarget(name: "NFS2015Session", dependencies: ["LauncherCore", "NFS2015Core"]),
    .executableTarget(
      name: "NFS2015Launcher", dependencies: ["LauncherCore", "NFS2015Core", "SharedLauncher"]),
    .executableTarget(name: "CoD4Session", dependencies: ["LauncherCore", "CoD4Core"]),
    .executableTarget(
      name: "CoD4Launcher", dependencies: ["LauncherCore", "CoD4Core", "SharedLauncher"]),
    .executableTarget(name: "NFSMWSession", dependencies: ["LauncherCore"]),
    .executableTarget(name: "NFSMWLauncher", dependencies: ["LauncherCore", "SharedLauncher"]),
    .testTarget(
      name: "LauncherCoreTests", dependencies: ["LauncherCore"], resources: [.copy("Fixtures")]),
    .testTarget(
      name: "LauncherUITests", dependencies: ["NFSMWLauncher", "LauncherCore", "SharedLauncher"]),
    .testTarget(name: "CoD4CoreTests", dependencies: ["CoD4Core", "LauncherCore"]),
    .testTarget(name: "NFS2015CoreTests", dependencies: ["NFS2015Core", "LauncherCore"]),
    .testTarget(
      name: "NFS2015UITests",
      dependencies: ["NFS2015Launcher", "NFS2015Core", "LauncherCore", "SharedLauncher"]),
    .testTarget(
      name: "CoD4UITests",
      dependencies: ["CoD4Launcher", "CoD4Core", "LauncherCore", "SharedLauncher"]),
  ],
  swiftLanguageModes: [.v6]
)

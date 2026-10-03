import Foundation
import Testing

@testable import LauncherCore

struct ExecutableEnvironmentTests {
  static let measured = [
    RendererSelection(api: "dxgi", backend: "dxmt", executable: "NFS16.exe"),
    RendererSelection(api: "dxgi", backend: "dxmt", executable: "EADesktop.exe"),
    RendererSelection(api: "dxgi", backend: "dxmt", executable: "EACefSubProcess.exe"),
  ]

  static let switchOn = ExecutableEnvironment(
    executable: "NFS16.exe",
    entries: [
      .init(name: "DXMT_METALFX_SPATIAL_SWAPCHAIN", value: "1"),
      .init(name: "DXMT_CONFIG", value: "d3d11.metalSpatialUpscaleFactor=1.5"),
    ])

  @Test
  func `adds nothing to the rules when there is no environment`() throws {
    let plain = try RendererSelection.compatibilityDatabase(Self.measured, kind: .nfs2015)
    let empty = try RendererSelection.compatibilityDatabase(
      Self.measured, kind: .nfs2015, environments: [])
    #expect(plain == empty)
    #expect(!plain.contains("env="))
  }

  @Test
  func `puts the variables on the game's rule line and on no other line`() throws {
    let rules = try RendererSelection.compatibilityDatabase(
      Self.measured, kind: .nfs2015, environments: [Self.switchOn])
    #expect(
      rules.split(separator: "\n").map(String.init) == [
        "v=3",
        "name=nfs2015-0;exe=NFS16.exe;dxgi=dxmt;env=DXMT_METALFX_SPATIAL_SWAPCHAIN=1"
          + ";env=DXMT_CONFIG=d3d11.metalSpatialUpscaleFactor=1.5",
        "name=nfs2015-1;exe=EADesktop.exe;dxgi=dxmt",
        "name=nfs2015-2;exe=EACefSubProcess.exe;dxgi=dxmt",
      ])
  }

  @Test
  func `gives a program that has no rule a rule of its own`() throws {
    let other = [RendererSelection(api: "dxgi", backend: "dxmt", executable: "EADesktop.exe")]
    let rules = try RendererSelection.compatibilityDatabase(
      other, kind: .nfs2015, environments: [Self.switchOn])
    #expect(
      rules.split(separator: "\n").map(String.init) == [
        "v=3", "name=nfs2015-0;exe=EADesktop.exe;dxgi=dxmt",
        "name=nfs2015-environment-1;exe=NFS16.exe;env=DXMT_METALFX_SPATIAL_SWAPCHAIN=1"
          + ";env=DXMT_CONFIG=d3d11.metalSpatialUpscaleFactor=1.5",
      ])
  }

  @Test
  func `matches the program name without regard to case, as the runtime does`() throws {
    let lower = ExecutableEnvironment(
      executable: "nfs16.exe", entries: [.init(name: "DXMT_CONFIG", value: "a=1")])
    let rules = try RendererSelection.compatibilityDatabase(
      Self.measured, kind: .nfs2015, environments: [lower])
    #expect(rules.contains("exe=NFS16.exe;dxgi=dxmt;env=DXMT_CONFIG=a=1"))
  }

  @Test
  func `reaches a game that has no renderer selection through the fixed rule`() throws {
    let rules = try LaunchEnvironment.compatibilityRules(
      .nfs2015, renderers: [], environments: [Self.switchOn])
    #expect(
      rules.split(separator: "\n").map(String.init) == [
        "v=3", "name=nfs2015-bundle;exe=*;d3d9=mtld3d;dxgi=wined3d",
        "name=nfs2015-environment-1;exe=NFS16.exe;env=DXMT_METALFX_SPATIAL_SWAPCHAIN=1"
          + ";env=DXMT_CONFIG=d3d11.metalSpatialUpscaleFactor=1.5",
      ])
  }

  @Test
  func `arrives in the launch environment only as part of the rules`() throws {
    let paths = try AppPaths(
      bundle: URL(fileURLWithPath: "/Applications/Need for Speed.app"),
      support: URL(fileURLWithPath: "/tmp/NFS Player"), game: .nfs2015)
    let environment = try LaunchEnvironment.make(
      paths: paths, prefix: paths.prefix, home: paths.support, temporary: paths.support,
      renderers: Self.measured, environments: [Self.switchOn])
    #expect(environment["DXMT_METALFX_SPATIAL_SWAPCHAIN"] == nil)
    #expect(environment["DXMT_CONFIG"] == nil)
    #expect(environment["WINE_COMPATDB"]?.contains("env=DXMT_METALFX_SPATIAL_SWAPCHAIN=1") == true)
    let plain = try LaunchEnvironment.make(
      paths: paths, prefix: paths.prefix, home: paths.support, temporary: paths.support,
      renderers: Self.measured)
    var withoutRules = environment
    withoutRules["WINE_COMPATDB"] = nil
    var plainWithoutRules = plain
    plainWithoutRules["WINE_COMPATDB"] = nil
    #expect(withoutRules == plainWithoutRules)
  }

  @Test
  func `refuses two environments for one program`() {
    let again = ExecutableEnvironment(
      executable: "nfs16.EXE", entries: [.init(name: "DXMT_CONFIG", value: "a=1")])
    #expect(throws: LauncherError.self) {
      try RendererSelection.compatibilityDatabase(
        Self.measured, kind: .nfs2015, environments: [Self.switchOn, again])
    }
  }

  @Test(arguments: [
    ExecutableEnvironment(executable: "NFS16", entries: [.init(name: "DXMT_CONFIG", value: "1")]),
    ExecutableEnvironment(executable: "*", entries: [.init(name: "DXMT_CONFIG", value: "1")]),
    ExecutableEnvironment(
      executable: "../NFS16.exe", entries: [.init(name: "DXMT_CONFIG", value: "1")]),
    ExecutableEnvironment(executable: "NFS16.exe", entries: []),
    ExecutableEnvironment(
      executable: "NFS16.exe",
      entries: (0..<9).map { .init(name: "DXMT_V\($0)", value: "1") }),
    ExecutableEnvironment(
      executable: "NFS16.exe", entries: [.init(name: "dxmt_config", value: "1")]),
    ExecutableEnvironment(executable: "NFS16.exe", entries: [.init(name: "1DXMT", value: "1")]),
    ExecutableEnvironment(executable: "NFS16.exe", entries: [.init(name: "A=B", value: "1")]),
    ExecutableEnvironment(executable: "NFS16.exe", entries: [.init(name: "", value: "1")]),
    ExecutableEnvironment(
      executable: "NFS16.exe", entries: [.init(name: "DXMT_CONFIG", value: "")]),
    ExecutableEnvironment(
      executable: "NFS16.exe", entries: [.init(name: "DXMT_CONFIG", value: "a;exe=*;dxgi=gptk")]),
    ExecutableEnvironment(
      executable: "NFS16.exe", entries: [.init(name: "DXMT_CONFIG", value: "100%25")]),
    ExecutableEnvironment(
      executable: "NFS16.exe", entries: [.init(name: "DXMT_CONFIG", value: "a\nname=x;exe=*")]),
    ExecutableEnvironment(
      executable: "NFS16.exe", entries: [.init(name: "DXMT_CONFIG", value: "caf\u{e9}")]),
    ExecutableEnvironment(
      executable: "NFS16.exe",
      entries: [.init(name: "DXMT_CONFIG", value: String(repeating: "a", count: 201))]),
    ExecutableEnvironment(
      executable: "NFS16.exe",
      entries: [.init(name: "DXMT_CONFIG", value: "1"), .init(name: "DXMT_CONFIG", value: "2")]),
  ])
  func `refuses a malformed environment before it can reach a rule`(
    environment: ExecutableEnvironment
  ) {
    #expect(throws: LauncherError.self) { try environment.validate() }
    #expect(throws: LauncherError.self) {
      try RendererSelection.compatibilityDatabase(
        Self.measured, kind: .nfs2015, environments: [environment])
    }
  }

  @Test(arguments: [
    "WINEDEBUG", "WINEDLLOVERRIDES", "WINE_COMPATDB", "DYLD_INSERT_LIBRARIES", "LD_PRELOAD",
    "ROSETTA_X87_PATH", "MTL_HUD_ENABLED", "PATH", "HOME", "TMPDIR",
  ])
  func `refuses a variable that decides how Wine loads or finds things`(name: String) {
    let environment = ExecutableEnvironment(
      executable: "NFS16.exe", entries: [.init(name: name, value: "1")])
    #expect(throws: LauncherError.self) { try environment.validate() }
  }
}

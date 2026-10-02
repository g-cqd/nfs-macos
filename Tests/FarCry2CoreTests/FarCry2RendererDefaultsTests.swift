import Foundation
import GameFixtures
import Testing

@testable import FarCry2Core
@testable import LauncherCore

/// The renderer configuration the recipe ships, and how the starter edits and launches around it.
struct FarCry2RendererDefaultsTests {
  private func shippedConfig(file: StaticString = #filePath) throws -> String {
    let root = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    return try String(
      contentsOf: root.appendingPathComponent("Packaging/FarCry2Defaults/mtld3d.conf"),
      encoding: .utf8)
  }

  private func comments(_ text: String) -> [String] {
    text.components(separatedBy: "\n").filter { $0.hasPrefix("#") }
  }

  @Test
  func `the shipped values are the ones the settings catalog calls default`() throws {
    let config = try ConfigText(try shippedConfig())
    for id in ["shader.asyncCompile", "render.scale", "present.maxFps"] {
      let setting = try #require(FarCry2Catalog.setting(id))
      #expect(config.value(section: "", key: id) == setting.defaultValue, "\(id)")
    }
    #expect(config.value(section: "", key: "shaderCache.enable") == "true")
  }

  @Test
  func `the shipped file is read back as the default settings`() throws {
    let settings = try FarCry2Settings(profile: nil, renderer: try shippedConfig())
    #expect(settings.value("shader.asyncCompile") == "false")
    #expect(settings.value("render.scale") == "1")
    #expect(settings.value("present.maxFps") == "0")
  }

  @Test
  func `editing the managed keys keeps the cache setting and every comment`() throws {
    let original = try shippedConfig()
    var settings = FarCry2Settings()
    settings.values["render.scale"] = "0.75"
    settings.values["shader.asyncCompile"] = "true"
    settings.values["present.maxFps"] = "60"
    let edited = try settings.rendererConfig(original: original)
    #expect(comments(edited) == comments(original), "no comment may be lost or reordered")
    let config = try ConfigText(edited)
    #expect(config.value(section: "", key: "render.scale") == "0.75")
    #expect(config.value(section: "", key: "shader.asyncCompile") == "true")
    #expect(config.value(section: "", key: "present.maxFps") == "60")
    #expect(config.value(section: "", key: "shaderCache.enable") == "true")
    #expect(
      try settings.rendererConfig(original: edited) == edited, "editing twice changes nothing")
  }

  @Test
  func `a player's own unmanaged lines survive an edit`() throws {
    let original = try shippedConfig() + "\nmemory.vramBudgetMB = 2048\n"
    let edited = try FarCry2Settings().rendererConfig(original: original)
    #expect(try ConfigText(edited).value(section: "", key: "memory.vramBudgetMB") == "2048")
  }

  @Test
  func `performance telemetry is switched off in the launch environment`() throws {
    let paths = try AppPaths(
      bundle: URL(fileURLWithPath: "/Applications/Far Cry 2.app"),
      support: URL(fileURLWithPath: "/tmp/Far Cry 2 Player"), game: .farcry2)
    let environment = try LaunchEnvironment.make(
      paths: paths, prefix: paths.prefix, home: paths.support, temporary: paths.support)
    let log = try #require(environment["RUST_LOG"])
    #expect(log.split(separator: ",").contains("mtld3d::perf=off"))
  }

  @Test
  func `the import never copies cache files from the player's folder`() throws {
    let rules = try RecipeRules.farCry2()
    let names = try #require(rules.directories.first { $0.path == "bin" }).excludedNames
    for name in ["mtld3d_shaders.bin", "mtld3d_shaders.bin.lock", "mtld3d_shaders.bin.owner"] {
      #expect(names.contains(name), "\(name)")
    }
  }
}

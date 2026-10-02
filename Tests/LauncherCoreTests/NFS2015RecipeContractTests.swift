import Foundation
import Testing

@testable import LauncherCore

/// The packager writes the bundled manifest from `Packaging/Recipes/nfs2015.json`, and the app
/// reads it. Decoding the same recipe here keeps the two from drifting apart.
struct NFS2015RecipeContractTests {
  private struct Recipe: Decodable {
    let storeClient: StoreClientPlan
    let controllerDevices: [String]
    let prefixSettings: [RegistrySetting]
    let bundledPrefixSettings: [RegistrySetting]
    let renderers: [RendererSelection]
    let runtimeTuning: [String: String]
    let originalFiles: [String]
    let originalDirectories: [String: [String]]
    let executableHashes: [String: String]
    let editions: [String]
  }

  private static func recipe(file: StaticString = #filePath) throws -> Recipe {
    let root = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    return try JSONDecoder().decode(
      Recipe.self,
      from: Data(contentsOf: root.appendingPathComponent("Packaging/Recipes/nfs2015.json")))
  }

  /// What the packager stages: every pinned path, plus the files its directories would add.
  private static func manifest(_ recipe: Recipe) -> BundleManifest {
    let digest = String(repeating: "b", count: 64)
    let paths =
      Set(recipe.executableHashes.keys).union(recipe.originalFiles).union([
        "Data/cas_01.cas", "Update/Patch/package.mft",
      ])
    return BundleManifest(
      version: "recipe",
      gameFiles: paths.sorted().map { ManifestFile(path: $0, size: 1, sha256: digest) },
      gameID: .nfs2015, runtimeTuning: RuntimeTuning(recipe.runtimeTuning),
      storeClient: recipe.storeClient, controllerDevices: recipe.controllerDevices,
      prefixSettings: recipe.prefixSettings + recipe.bundledPrefixSettings,
      renderers: recipe.renderers)
  }

  @Test
  func `the bundled manifest the packager writes is one the app accepts`() throws {
    let recipe = try Self.recipe()
    let manifest = Self.manifest(recipe)
    try manifest.validate()
    #expect(manifest.seedsPrefix)
    #expect(recipe.editions == ["import", "bundled"])
    // The pinned executables are the game's own files and nothing that holds state.
    for path in recipe.executableHashes.keys {
      #expect(!ManifestFile.isAccountState(path: path), "\(path)")
    }
    for path in recipe.originalFiles + Array(recipe.originalDirectories.keys) {
      #expect(!ManifestFile.isAccountState(path: path + "/x"), "\(path)")
    }
    #expect(recipe.executableHashes["NFS16.exe"]?.count == 64)
  }

  @Test
  func `registers the install folder exactly where the app seeds the game`() throws {
    let recipe = try Self.recipe()
    let installDir = try #require(recipe.bundledPrefixSettings.first { $0.name == "Install Dir" })
    #expect(installDir.kind == .windowsPath && installDir.hive == .localMachine)
    #expect(
      installDir.value
        == "C:\\" + recipe.storeClient.gameRoot.replacingOccurrences(of: "/", with: "\\") + "\\")
    for setting in recipe.bundledPrefixSettings { try setting.validate() }
    // Only the bundled edition writes the game's registration; an import app never does.
    #expect(!recipe.prefixSettings.contains { $0.name == "Install Dir" })
    #expect(recipe.prefixSettings.contains { $0.name == "RetinaMode" })
  }

  @Test
  func `serves the game and the client with the measured backend`() throws {
    let recipe = try Self.recipe()
    let rules = try RendererSelection.compatibilityDatabase(recipe.renderers, kind: .nfs2015)
    #expect(rules.contains("exe=NFS16.exe;dxgi=dxmt"))
    #expect(rules.contains("exe=EADesktop.exe;dxgi=dxmt"))
    #expect(!rules.contains("gptk") && !rules.contains("mtld3d"))
    #expect(recipe.controllerDevices == ["054C/05C4", "054C/0CE6"])
    #expect(recipe.runtimeTuning["WINE_TF_EMULATION"] == "1")
  }
}

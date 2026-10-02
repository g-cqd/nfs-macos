import Foundation
import LauncherCore

/// Loads the recognition rules straight from the packaging recipe, so the native scanner and the
/// packager can never disagree about what a Far Cry 2 installation looks like.
package enum RecipeRules {
  private struct Recipe: Decodable { let importRules: ImportRules }

  package static func farCry2(file: StaticString = #filePath) throws -> ImportRules {
    let root = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let url = root.appendingPathComponent("Packaging/Recipes/farcry2.json")
    return try JSONDecoder().decode(Recipe.self, from: Data(contentsOf: url)).importRules
  }

  /// The same names, suffixes and pairings with every size floor removed, for tiny synthetic trees.
  package static func farCry2Scaled() throws -> ImportRules {
    let rules = try farCry2()
    return ImportRules(
      executable: rules.executable, machine: rules.machine,
      required: rules.required.map { .init(path: $0.path, minimumSize: 1) },
      directories: rules.directories.map {
        .init(
          path: $0.path, minimumBytes: 0, excludedNames: $0.excludedNames,
          excludedSuffixes: $0.excludedSuffixes, excludedDirectories: $0.excludedDirectories)
      },
      pairings: rules.pairings, markers: rules.markers, knownBuilds: rules.knownBuilds,
      maximumFiles: rules.maximumFiles, maximumBytes: rules.maximumBytes)
  }
}

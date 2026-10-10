import Foundation
import LauncherCore

/// The recipes that say which parts of each known game's prefix stay real in an instance.
package enum InstanceRecipes {
  /// One game's row of the table: its id and the prefix folders that are kept real when present.
  private struct Row {
    let gameID: GameID
    let candidates: [String]
  }

  /// Files and folders needed to boot Wine in the prefix.
  private static let bootPaths = [
    "system.reg", "user.reg", "userdef.reg", ".update-timestamp", "dosdevices",
  ]

  /// Always kept real. Whether `drive_c/windows` can become placeholders is an open experiment.
  private static let alwaysReal = "drive_c/windows"

  /// The row for `kind`, or `nil` when the game has no recipe.
  private static func row(for kind: GameKind) -> Row? {
    let programFiles = ["drive_c/Program Files (x86)", "drive_c/Program Files"]
    let eaClient = ["drive_c/ProgramData/EA Desktop", "drive_c/ProgramData/Electronic Arts"]
    let users = "drive_c/users"
    switch kind {
    case .cod4: return Row(gameID: "cod4", candidates: programFiles + [users])
    case .bf3: return Row(gameID: "bf3", candidates: ["drive_c/Program Files"] + eaClient + [users])
    case .nfs2015: return Row(gameID: "nfs2015", candidates: programFiles + eaClient + [users])
    default: return nil
    }
  }

  /// The recipe for a game whose prefix is at `prefix`, or `nil` when the game is not known or the
  /// prefix has no `drive_c`. Inspects the prefix read-only: each candidate folder of the game's
  /// row is kept only when it exists, then the boot paths and `drive_c/windows` are added.
  /// - Complexity: O(1) in the size of the prefix; one existence check per candidate.
  package static func recipe(for kind: GameKind, prefix: URL) -> InstanceRecipe? {
    guard let row = row(for: kind) else { return nil }
    let files = FileManager.default
    guard files.fileExists(atPath: prefix.appendingPathComponent("drive_c").path) else {
      return nil
    }
    let present = row.candidates.filter {
      files.fileExists(atPath: prefix.appendingPathComponent($0).path)
    }
    return InstanceRecipe(
      gameID: row.gameID, realRoots: present + [alwaysReal], bootPaths: bootPaths)
  }
}

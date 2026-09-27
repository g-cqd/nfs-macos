/// Profile operations run under the same exclusive lock as the game.
package struct CoD4ProfileRequest: Codable, Sendable {
  package enum Action: String, Codable, Sendable {
    case create, remove, backup, restore, importProfile, exportProfile
  }
  package let action: Action
  package let name: String
  package let sourcePath: String?
  package let destinationPath: String?
  package let backup: String?
  package init(
    action: Action, name: String, sourcePath: String? = nil, destinationPath: String? = nil,
    backup: String? = nil
  ) {
    self.action = action
    self.name = name
    self.sourcePath = sourcePath
    self.destinationPath = destinationPath
    self.backup = backup
  }
}

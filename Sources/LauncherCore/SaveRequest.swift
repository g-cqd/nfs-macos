import Foundation

package enum SaveRequest: Codable, Sendable {
  case create(profile: String)
  case remove(profile: String, expected: String)
  case replace(profile: String, data: Data, expected: String?)
  case cheat(profile: String, expected: String, action: SaveCheat)
  case backup(profile: String, expected: String)
  case restore(profile: String, name: String, expected: String?)
}

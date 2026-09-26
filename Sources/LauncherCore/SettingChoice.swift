import Foundation

package struct SettingChoice: Identifiable, Sendable {
  package let id: String
  package let title: String

  package init(_ id: String, _ title: String) {
    self.id = id
    self.title = title
  }
}

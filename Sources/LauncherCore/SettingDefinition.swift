import Foundation

package struct SettingDefinition: Identifiable, Sendable {
  package enum Destination: Sendable { case registry, widescreen, input, renderer, launcher }
  package let id: String
  package let title: String
  package let group: String
  package let destination: Destination
  package let section: String
  package let key: String
  package let defaultValue: String
  package let choices: [SettingChoice]
  package let range: ClosedRange<Int>?
  package let help: String

  package init(
    _ id: String, _ title: String, _ group: String, _ destination: Destination,
    _ section: String, _ key: String, _ defaultValue: String,
    choices: [SettingChoice] = [], range: ClosedRange<Int>? = nil, help: String = ""
  ) {
    self.id = id
    self.title = title
    self.group = group
    self.destination = destination
    self.section = section
    self.key = key
    self.defaultValue = defaultValue
    self.choices = choices
    self.range = range
    self.help = help
  }

  package func accepts(_ value: String) -> Bool {
    if let range { return Int(value).map { range.contains($0) && String($0) == value } ?? false }
    return choices.contains { $0.id == value }
  }
}

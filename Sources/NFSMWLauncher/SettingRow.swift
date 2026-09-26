import LauncherCore
import SwiftUI

struct SettingRow: View {
  let definition: SettingDefinition
  let model: LauncherModel

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if definition.range != nil {
        TextField(definition.title, text: model.settingBinding(definition.id)).textFieldStyle(
          .roundedBorder)
      } else {
        Picker(definition.title, selection: model.settingBinding(definition.id)) {
          ForEach(definition.choices) { choice in Text(choice.title).tag(choice.id) }
        }
      }
      if !definition.help.isEmpty {
        Text(definition.help).font(.caption).foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 3)
  }
}

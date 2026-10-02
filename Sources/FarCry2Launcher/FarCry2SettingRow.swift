import FarCry2Core
import SwiftUI

struct FarCry2SettingRow: View {
  let setting: FarCry2Setting
  @Binding var value: String
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      switch setting.kind {
      case .choices(let choices):
        Picker(setting.title, selection: $value) {
          ForEach(choices) { Text($0.title).tag($0.id) }
        }
      case .resolution:
        TextField(setting.title, text: $value)
      }
      if !setting.help.isEmpty { Text(setting.help).font(.caption).foregroundStyle(.secondary) }
    }
  }
}

import CoD4Core
import SwiftUI

struct CoD4SettingRow: View {
  let setting: CoD4Setting
  @Binding var value: String
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      switch setting.kind {
      case .choices(let choices):
        Picker(setting.title, selection: $value) {
          ForEach(choices) { Text($0.title).tag($0.id) }
        }
      case .number(let range):
        HStack {
          Text(setting.title)
          Spacer()
          TextField(setting.title, text: $value).frame(width: 90).multilineTextAlignment(.trailing)
        }
        Text("\(range.lowerBound.formatted())–\(range.upperBound.formatted())").font(.caption)
          .foregroundStyle(.secondary)
      case .resolution:
        TextField(setting.title, text: $value)
      }
      if !setting.help.isEmpty { Text(setting.help).font(.caption).foregroundStyle(.secondary) }
    }
  }
}

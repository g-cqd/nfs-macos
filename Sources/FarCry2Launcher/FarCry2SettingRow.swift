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
      case .integer(let range):
        Stepper(value: integer(range), in: range) {
          LabeledContent(setting.title, value: value)
        }
      case .decimal(let range):
        LabeledContent(setting.title, value: value)
        Slider(value: decimal(range), in: range, step: 0.05)
      }
      if !setting.help.isEmpty { Text(setting.help).font(.caption).foregroundStyle(.secondary) }
    }
  }

  private func integer(_ range: ClosedRange<Int>) -> Binding<Int> {
    Binding(
      get: { Int(value) ?? Int(setting.defaultValue) ?? range.lowerBound },
      set: { value = String(min(max($0, range.lowerBound), range.upperBound)) })
  }

  private func decimal(_ range: ClosedRange<Double>) -> Binding<Double> {
    Binding(
      get: { Double(value) ?? Double(setting.defaultValue) ?? range.lowerBound },
      set: { value = FarCry2Setting.canonical(min(max($0, range.lowerBound), range.upperBound)) })
  }
}

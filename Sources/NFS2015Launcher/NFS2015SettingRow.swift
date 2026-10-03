import NFS2015Core
import SwiftUI

/// One catalog setting: its control, its range, where its values come from, and what to know.
struct NFS2015SettingRow: View {
  let setting: NFS2015Setting
  /// Whether the game's file holds a value for this setting that can be changed.
  let isChangeable: Bool
  /// What the game wrote, for a value that is shown but not changed.
  let recorded: String?
  @Binding var value: String
  @Binding var number: Double
  @State private var draft = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      control.disabled(!isChangeable)
      if let range = setting.rangeDescription {
        Text("Accepts \(range)").font(.caption).foregroundStyle(.secondary)
      }
      if let recorded {
        Text(
          setting.isEditable
            ? "The game's file holds \(recorded), which this app does not offer. It is left as it is."
            : "The game's file holds \(recorded)."
        ).font(.caption)
      } else if !isChangeable {
        Text("The game has not written this option yet.").font(.caption)
          .foregroundStyle(.secondary)
      }
      Text(setting.source.title).font(.caption2).foregroundStyle(.secondary)
      if !setting.help.isEmpty { Text(setting.help).font(.caption).foregroundStyle(.secondary) }
    }
  }

  @ViewBuilder private var control: some View {
    switch setting.kind {
    case .choices(let choices):
      Picker(setting.title, selection: $value) {
        ForEach(choices) { Text($0.title).tag($0.id) }
      }
    case .number where setting.prefersSlider:
      LabeledContent(setting.title, value: setting.displayText(value))
      Slider(value: $number, in: setting.range ?? 0...1)
    case .number, .resolution:
      LabeledContent(setting.title) {
        TextField(setting.title, text: $draft)
          .multilineTextAlignment(.trailing).frame(width: 120)
          .onSubmit(commit)
          .onAppear { draft = setting.displayText(value) }
          .onChange(of: value) { draft = setting.displayText(value) }
      }
    case .observed:
      LabeledContent(setting.title, value: recorded ?? "not written")
    }
  }

  private func commit() {
    value = draft
    draft = setting.displayText(value)
  }
}

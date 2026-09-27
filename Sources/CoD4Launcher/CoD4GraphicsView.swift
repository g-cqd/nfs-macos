import CoD4Core
import LauncherCore
import SwiftUI

struct CoD4GraphicsView: View {
  @Bindable var model: CoD4Model
  var body: some View {
    Form {
      Section("Display mode") {
        Picker("Aspect ratio", selection: $model.aspectRatio) {
          ForEach(model.aspectRatios, id: \.self) { Text($0.rawValue).tag($0) }
        }
        Picker("Resolution", selection: $model.selectedResolution) {
          ForEach(model.filteredResolutions) { Text($0.title).tag($0.id) }
        }
        Text(
          "Aspect ratio filters resolution presets. The game determines its projection from the chosen display mode."
        )
        .font(.caption).foregroundStyle(.secondary)
        Button("Maximum Quality for This Display", action: model.maximumQuality)
      }
      ForEach(CoD4Catalog.graphicsGroups, id: \.self) { group in
        Section(group) {
          ForEach(model.settings(in: group)) { setting in
            CoD4SettingRow(setting: setting, value: model.settingBinding(setting.id))
          }
        }
      }
    }.formStyle(.grouped)
  }
}

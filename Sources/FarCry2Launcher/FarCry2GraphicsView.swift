import FarCry2Core
import LauncherCore
import SwiftUI

struct FarCry2GraphicsView: View {
  @Bindable var model: FarCry2Model
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
          "The resolution is written to the game's render profile and quality entries. The game must offer this display mode."
        )
        .font(.caption).foregroundStyle(.secondary)
        Button("Maximum Quality for This Display", action: model.maximumQuality)
      }
      ForEach(FarCry2Catalog.graphicsGroups.filter { $0 != "Display" }, id: \.self) { group in
        Section(group) {
          ForEach(model.settings(in: group)) { setting in
            FarCry2SettingRow(setting: setting, value: model.settingBinding(setting.id))
          }
        }
      }
      Section("Display options") {
        ForEach(model.settings(in: "Display")) { setting in
          FarCry2SettingRow(setting: setting, value: model.settingBinding(setting.id))
        }
      }
      Section {
        Text(model.profileNotice).font(.caption).foregroundStyle(.secondary)
      }
    }.formStyle(.grouped)
  }
}

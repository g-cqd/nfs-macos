import LauncherCore
import SwiftUI

struct GraphicsView: View {
  @Bindable var model: LauncherModel

  var body: some View {
    Form {
      Section("Presets") {
        HStack {
          Button("Balanced", action: model.tunedGraphics)
          Button("Favor performance", action: model.lighterGraphics)
          Button("Maximum quality", action: model.maximumGraphics)
        }
        Text(
          "Maximum quality selects the main display’s maximum resolution, fullscreen, full render scale, 4× MSAA and maximum scene detail. All presets keep your frame rate limit."
        ).font(.caption)
          .foregroundStyle(.secondary)
      }
      Section("Share a setup") {
        HStack {
          Button("Import setup…", action: model.importSetup)
          Button("Export setup…", action: model.exportSetup)
        }
        Text(
          "Share graphics and controller mappings. Saved careers have their own import and export in Saves & backups."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      Section("Resolution") {
        Picker("Aspect ratio", selection: $model.aspectRatio) {
          ForEach(model.aspectRatios, id: \.self) { ratio in Text(ratio.rawValue).tag(ratio) }
        }
        Picker("Resolution preset", selection: $model.selectedResolution) {
          ForEach(model.resolutionPresets) { preset in Text(preset.title).tag(preset.id) }
        }
      }
      Section("Presentation") {
        ForEach(model.commonGraphics) { definition in
          SettingRow(definition: definition, model: model)
        }
      }
      Section("Fine tuning") {
        ForEach(GraphicsCatalog.groups, id: \.self) { group in
          DisclosureGroup(group) {
            ForEach(model.advancedGraphics(in: group)) { definition in
              SettingRow(definition: definition, model: model)
            }
          }
        }
      }
    }
    .formStyle(.grouped)
  }
}

import SwiftUI

struct FarCry2PlayView: View {
  @Bindable var model: FarCry2Model
  var body: some View {
    Form {
      Section {
        VStack(alignment: .leading, spacing: 8) {
          Text("FAR CRY 2").font(.largeTitle.weight(.bold))
          Text("Choose your setup and return to the savannah.")
        }.padding(.vertical, 8)
      }
      if model.needsRosetta {
        FarCry2RosettaView(model: model)
      } else if model.needsGameData {
        Section("Import your game") {
          Text(
            "Choose your installed Windows Far Cry 2 folder, the one that contains bin and Data_Win32. The starter checks it and keeps its own working copy and your saves outside the app."
          )
          Button("Import Game Folder…", action: model.importGame)
        }
      } else {
        Section("Picture") {
          LabeledContent("Resolution", value: model.resolutionSummary)
          LabeledContent("Renderer", value: model.renderSummary)
          Button("Maximum Quality for This Display", action: model.maximumQuality)
          Text(
            "Native pixels, 4× MSAA with alpha to coverage, the game's top texture level and full-resolution rendering. Detail levels are chosen in the game's own Video options (Ultra High)."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
        if let notice = model.shaderCacheNotice {
          Section("First launch") {
            Text(notice)
            Text("Details are under Shader cache.").font(.caption).foregroundStyle(.secondary)
          }
        }
        Section("Installation") {
          if let summary = model.installationSummary {
            LabeledContent("Recognised", value: summary)
          }
          Text(model.profileNotice).font(.caption).foregroundStyle(.secondary)
          Text(
            "The game runs in DirectX 9. DirectX 10 mode is not supported and is hidden from the game."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
      }
    }.formStyle(.grouped)
  }
}

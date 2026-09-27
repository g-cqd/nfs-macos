import CoD4Core
import SwiftUI

struct CoD4PlayView: View {
  @Bindable var model: CoD4Model
  var body: some View {
    Form {
      Section {
        VStack(alignment: .leading, spacing: 8) {
          Text("CALL OF DUTY 4").font(.largeTitle.weight(.bold))
          Text("MODERN WARFARE").font(.title3).foregroundStyle(.secondary)
          Text("Choose your profile, tune your setup, and return to the campaign.")
        }.padding(.vertical, 8)
      }
      if model.needsRosetta {
        CoD4RosettaView(model: model)
      } else if model.needsGameData {
        Section("Import your game") {
          Text(
            "Choose your installed Windows Call of Duty 4 game folder. The starter keeps its working copy and profiles outside the app."
          )
          Button("Import Game Folder…", action: model.importGame)
        }
      } else {
        Section("Session") {
          Picker("Mode", selection: Binding(get: { model.mode }, set: model.selectMode)) {
            ForEach(CoD4Mode.allCases) { Text($0.title).tag($0) }
          }
          Picker(
            "Player profile",
            selection: Binding(get: { model.selectedProfile }, set: model.selectProfile)
          ) {
            ForEach(model.playProfiles) { Text($0.name).tag($0.name) }
          }
          Text(
            "Campaign and multiplayer keep separate game settings. Multiplayer servers must support your installed game version."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
        Section("Picture") {
          LabeledContent("Resolution", value: model.resolutionSummary)
          LabeledContent("Renderer", value: model.renderSummary)
          Button("Maximum Quality for This Display", action: model.maximumQuality)
          Text(
            "Uses full display pixels, 4× MSAA, high-detail textures, shadows and effects. Confirm the selected display mode in the game."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
      }
    }.formStyle(.grouped)
  }
}

import SwiftUI

struct CoD4SetupView: View {
  @Bindable var model: CoD4Model
  var body: some View {
    Form {
      Section("Portable setup") {
        Text(
          "Import or export graphics, audio, gameplay preferences, and explicit keyboard bindings. Player progress is managed in Profiles & backups."
        )
        HStack {
          Button("Import Setup…", action: model.importSetup)
          Button("Export Setup…", action: model.exportSetup)
        }
      }
      Section("Game data") {
        Text(
          "Import your Windows game folder. The starter validates the game data and creates its own working copy."
        )
        Button("Import Game Folder…", action: model.importGame)
      }
      CoD4RosettaView(model: model)
    }.formStyle(.grouped)
  }
}

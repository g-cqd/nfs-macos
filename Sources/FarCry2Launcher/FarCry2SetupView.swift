import SwiftUI

struct FarCry2SetupView: View {
  @Bindable var model: FarCry2Model
  var body: some View {
    Form {
      Section("Portable setup") {
        Text(
          "Import or export graphics and renderer settings. Saves are managed under Saves & backups."
        )
        HStack {
          Button("Import Setup…", action: model.importSetup)
          Button("Export Setup…", action: model.exportSetup)
        }
      }
      Section("Game data") {
        Text(
          "Import your Windows game folder. The starter checks that it looks like a complete installation and creates its own working copy."
        )
        Button("Import Game Folder…", action: model.importGame)
      }
      FarCry2RosettaView(model: model)
    }.formStyle(.grouped)
  }
}

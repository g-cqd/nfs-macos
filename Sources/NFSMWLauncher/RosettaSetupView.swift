import SharedLauncher
import SwiftUI

struct RosettaSetupView: View {
  let model: LauncherModel

  var body: some View {
    Section("Set up this Mac") {
      Text("Install Rosetta to play")
        .font(.headline)
      Text(
        "This game needs Apple's Rosetta to run its Intel components. Continue in Apple's installation window, then return here. An internet connection may be required."
      )
      .foregroundStyle(.secondary)
      if let issue = model.rosetta.issue { Text(issue).foregroundStyle(.red) }
      HStack {
        Button("Install Rosetta…", action: model.installRosetta)
        Button("Refresh", action: model.refreshRosetta)
      }
      Text("The starter checks again when you return. Your game and saves stay unchanged.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }
}

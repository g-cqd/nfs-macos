import SwiftUI

struct FarCry2RosettaView: View {
  let model: FarCry2Model
  var body: some View {
    Section("Rosetta") {
      Text(
        model.rosetta.isAvailable
          ? "Rosetta is available." : "Install Rosetta to run this Intel game on Apple silicon.")
      if let issue = model.rosetta.issue { Text(issue).foregroundStyle(.red) }
      HStack {
        Button("Install Rosetta…", action: model.installRosetta).disabled(model.rosetta.isAvailable)
        Button("Refresh", action: model.refreshRosetta)
      }
      Text(
        "Installation opens Apple's installer. Return here afterward; the starter checks again when activated."
      )
      .font(.caption).foregroundStyle(.secondary)
    }
  }
}

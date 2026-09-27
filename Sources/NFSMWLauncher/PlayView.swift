import SharedLauncher
import SwiftUI

struct PlayView: View {
  let model: LauncherModel

  var body: some View {
    Form {
      if !model.rosetta.isAvailable { RosettaSetupView(model: model) }
      Section {
        VStack(alignment: .leading, spacing: 8) {
          Text("MOST WANTED").font(.largeTitle.bold().italic())
          Text("Pick up your career. Make the next race yours.").foregroundStyle(.secondary)
        }
        .padding(.vertical, 12)
      }
      Section("Game data") {
        Text(
          "Use your installed Most Wanted (2005) PC 1.3 folder. The app copies the required files and applies its compatibility fixes."
        )
        .font(.callout).foregroundStyle(.secondary)
        Button("Import game data…", action: model.importGameData)
      }
      Section("Next launch") {
        LabeledContent("Display", value: model.displaySummary)
        LabeledContent("Frame rate limit", value: model.frameRateSummary)
        LabeledContent("Image rendering", value: model.renderingSummary)
        Text(
          "Actual frame rate depends on the scene and your Mac. Choose Graphics to adjust the balance between detail and rendering load."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      Section("Controller") {
        Text(model.controllerStatus)
        Text(
          "Analog triggers control throttle and braking. Use Controller to change button labels, mappings or stick dead zones."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      Section("Career") {
        Text(model.careerSummary)
        Text(
          "Choose your player in the game. Save edits and backups are available while the game is closed."
        )
        .font(.caption).foregroundStyle(.secondary)
      }

    }
    .formStyle(.grouped)
  }
}

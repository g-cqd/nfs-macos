import SwiftUI

struct CoD4View: View {
  @Bindable var model: CoD4Model
  var body: some View {
    NavigationSplitView {
      List(selection: $model.tab) {
        Label("Play", systemImage: "play.fill").tag("Play")
        Section("Your experience") {
          Label("Graphics", systemImage: "display").tag("Graphics")
          Label("Audio & gameplay", systemImage: "speaker.wave.2").tag("Audio")
          Label("Controls", systemImage: "gamecontroller").tag("Controls")
        }
        Section("Your progress") {
          Label("Profiles & backups", systemImage: "person.crop.rectangle.stack").tag("Profiles")
          Label("Setup", systemImage: "gearshape").tag("Setup")
        }
      }
      .navigationSplitViewColumnWidth(min: 185, ideal: 205, max: 250)
      .navigationTitle("Modern Warfare")
    } detail: {
      VStack(spacing: 0) {
        Group {
          switch model.tab {
          case "Graphics": CoD4GraphicsView(model: model)
          case "Audio": CoD4AudioView(model: model)
          case "Controls": CoD4ControlsView(model: model)
          case "Profiles": CoD4ProfilesView(model: model)
          case "Setup": CoD4SetupView(model: model)
          default: CoD4PlayView(model: model)
          }
        }
        .disabled(model.isBusy)
        Divider()
        HStack {
          if model.isBusy { ProgressView().controlSize(.small) }
          Text(model.phase.message).font(.callout).foregroundStyle(
            model.errorMessage == nil ? .secondary : .primary)
          Spacer()
          if model.hasPendingChanges {
            Text("Unsaved changes").font(.caption).foregroundStyle(.secondary)
          }
          Button("Save Settings", action: model.apply).disabled(
            !model.canPlay || !model.hasPendingChanges)
          Button("Play", action: model.play).buttonStyle(.borderedProminent).disabled(
            !model.canPlay)
        }.padding()
      }
      .frame(minWidth: 660, minHeight: 600)
      .navigationTitle(model.tab == "Play" ? "Call of Duty 4" : model.tab)
      .toolbar {
        Button("Reload", systemImage: "arrow.clockwise", action: model.reload).disabled(
          model.isBusy)
        Button("Open Log", systemImage: "doc.text", action: model.showLog).disabled(model.isBusy)
      }
    }
    .confirmationDialog("Discard unsaved settings?", isPresented: $model.discardConfirmation) {
      Button("Discard Changes", role: .destructive, action: model.confirmDiscard)
      Button("Cancel", role: .cancel, action: model.cancelDiscard)
    } message: {
      Text("The selected profile or mode will load its own saved settings.")
    }
    .confirmationDialog("Remove this player profile?", isPresented: $model.removalConfirmation) {
      Button("Back Up and Remove", role: .destructive, action: model.removeProfile)
    } message: {
      Text("The profile will be archived in a restorable backup before removal.")
    }
    .confirmationDialog("Restore this profile backup?", isPresented: $model.restoreConfirmation) {
      Button("Restore Backup", role: .destructive, action: model.restoreProfile)
    } message: {
      Text("The current profile will be backed up before the selected backup replaces it.")
    }
  }
}

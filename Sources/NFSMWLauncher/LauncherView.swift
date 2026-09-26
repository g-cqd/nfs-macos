import SwiftUI

struct LauncherView: View {
  @Bindable var model: LauncherModel
  @FocusState private var playFocused: Bool

  var body: some View {
    NavigationSplitView {
      List(selection: $model.tab) {
        Label("Play", systemImage: "play.fill").tag("Play")
        Section("Your experience") {
          Label("Graphics", systemImage: "display").tag("Graphics")
          Label("Controller", systemImage: "gamecontroller").tag("Controller")
        }
        Section("Your career") {
          Label("Saves & backups", systemImage: "internaldrive").tag("Saves")
          Label("Cheats", systemImage: "wrench.and.screwdriver").tag("Cheats")
        }
      }
      .navigationSplitViewColumnWidth(min: 175, ideal: 190, max: 240)
      .navigationTitle("Most Wanted")
    } detail: {
      VStack(spacing: 0) {
        Group {
          switch model.tab {
          case "Graphics": GraphicsView(model: model)
          case "Controller": ControlsView(model: model)
          case "Saves": SavesView(model: model, editor: model.saveEditor)
          case "Cheats": CheatsView(model: model, editor: model.saveEditor)
          default: PlayView(model: model)
          }
        }
        .disabled(model.phase.isBusy)
        Divider()
        VStack(alignment: .leading, spacing: 8) {
          Text(model.phase.title).font(.headline)
          Text(model.phase.detail).font(.callout).foregroundStyle(.secondary).textSelection(
            .enabled)
          if let issue = model.settingsIssue { Text(issue).foregroundStyle(.red) }
          HStack {
            Menu("More") {
              Button("Open session log", action: model.openLog)
              Button("Open saves folder", action: model.openSaves)
              Button("Reload from disk", action: model.reload).disabled(model.phase.isBusy)
            }
            .fixedSize()
            Spacer()
            Text(model.hasPendingChanges ? "Changes apply before Play" : "Settings saved")
              .font(.caption).foregroundStyle(.secondary)
            Button("Save Settings", action: model.applySettings)
              .disabled(!model.canLaunch || !model.hasPendingChanges)
            Button("Play", action: model.playAgain).buttonStyle(.borderedProminent)
              .keyboardShortcut(.defaultAction).focused($playFocused).disabled(!model.canLaunch)
          }
        }
        .padding(20)
      }
      .navigationTitle(model.tab)
    }
    .confirmationDialog("Discard unapplied settings?", isPresented: $model.discardConfirmation) {
      Button("Discard and reload", role: .destructive, action: model.discardChanges)
    } message: {
      Text(
        "Your saved careers stay unchanged. Graphics and controller edits in this window will be discarded."
      )
    }
    .defaultFocus($playFocused, true)
    .frame(minWidth: 880, minHeight: 680)
  }
}

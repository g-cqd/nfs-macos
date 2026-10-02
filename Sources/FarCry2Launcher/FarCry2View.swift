import FarCry2Core
import SwiftUI

struct FarCry2View: View {
  @Bindable var model: FarCry2Model
  var body: some View {
    NavigationSplitView {
      List(selection: $model.tab) {
        Label("Play", systemImage: "play.fill").tag("Play")
        Section("Your experience") {
          Label("Graphics", systemImage: "display").tag("Graphics")
          Label("Shader cache", systemImage: "bolt.horizontal").tag("ShaderCache")
          Label("Game view", systemImage: "rectangle.on.rectangle").tag("Game view")
          Label("Mac & MetalFX", systemImage: "macbook.and.iphone").tag("Mac")
          Label("Game & controls", systemImage: "gamecontroller").tag("Game")
          Label("Cheats", systemImage: "wand.and.stars").tag("Cheats")
        }
        Section("Your progress") {
          Label("Saves & backups", systemImage: "externaldrive.badge.timemachine").tag("Saves")
          Label("Setup", systemImage: "gearshape").tag("Setup")
        }
      }
      .navigationSplitViewColumnWidth(min: 185, ideal: 205, max: 250)
      .navigationTitle("Far Cry 2")
    } detail: {
      VStack(spacing: 0) {
        Group {
          switch model.tab {
          case "Graphics": FarCry2GraphicsView(model: model)
          case "Game view": FarCry2GameView(model: model)
          case "Mac":
            FarCry2PanelView(
              model: model, groups: FarCry2Catalog.macGroups,
              notice:
                "Retina and keyboard options are Wine settings and apply the next time the game starts. Renderer options are written to mtld3d.conf next to the game's executable."
            )
          case "Game":
            FarCry2PanelView(
              model: model, groups: FarCry2Catalog.gameGroups,
              notice:
                "Gameplay and mouse options are the game's own profile values. Launch options are the game's command-line switches."
            )
          case "Cheats":
            FarCry2PanelView(
              model: model, groups: FarCry2Catalog.cheatGroups,
              notice:
                "Cheats are applied as console commands when the game starts. The command and variable names come from the game's engine; whether the retail build accepts them at launch is described in the Far Cry 2 documentation."
            )
          case "Saves": FarCry2SavesView(model: model)
          case "ShaderCache": FarCry2ShaderCacheView(model: model)
          case "Setup": FarCry2SetupView(model: model)
          default: FarCry2PlayView(model: model)
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
          if model.phase == .playing {
            Button(
              "Return to Game", systemImage: "arrow.uturn.backward", action: model.returnToGame)
          }
          Button("Save Settings", action: model.apply).disabled(
            !model.canPlay || !model.hasPendingChanges)
          Button("Play", action: model.play).buttonStyle(.borderedProminent).disabled(
            !model.canPlay)
        }.padding()
      }
      .frame(minWidth: 640, minHeight: 560)
      .navigationTitle(model.tab == "Play" ? "Far Cry 2" : model.tab)
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
      Text("The game's saved settings will be loaded again.")
    }
    .confirmationDialog("Restore this backup?", isPresented: $model.restoreConfirmation) {
      Button("Restore Backup", role: .destructive, action: model.restoreBackup)
    } message: {
      Text("Your current settings and saves are backed up first, then replaced.")
    }
    .confirmationDialog("Reset the shader cache?", isPresented: $model.shaderResetConfirmation) {
      Button("Reset Shader Cache", role: .destructive, action: model.resetShaderCache)
    } message: {
      Text("The saved shaders are deleted. The next launch compiles them again and may pause.")
    }
    .confirmationDialog("Remove this backup?", isPresented: $model.removalConfirmation) {
      Button("Remove Backup", role: .destructive, action: model.removeBackup)
    } message: {
      Text("Only this backup is deleted. Your current saves are not changed.")
    }
  }
}

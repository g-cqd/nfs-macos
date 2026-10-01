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

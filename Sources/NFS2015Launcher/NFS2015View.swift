import NFS2015Core
import SwiftUI

struct NFS2015PlayView: View {
  let model: NFS2015Model

  var body: some View {
    Form {
      if model.ownsWindowsFolder {
        Section("This app's Windows folder") {
          if let folder = model.installedAt { Text(folder).font(.callout).textSelection(.enabled) }
          if let version = model.clientVersion { Text("EA app \(version)").font(.caption) }
          HStack {
            Button(
              model.needsClientInstall ? "Install EA App…" : "Reinstall EA App…",
              action: model.chooseClientInstaller
            ).disabled(!model.canInstallClient)
            Button("Open EA App", action: model.openClient).disabled(!model.canOpenClient)
          }
          Text(
            """
            This app carries your own Need for Speed files and prepared this Windows folder for \
            them on first launch. Install the EA app from ea.com into it once, sign in to your \
            own EA account in the EA app, then press Play. This app never stores, copies or \
            works around your sign-in.
            """
          ).font(.caption).foregroundStyle(.secondary)
        }
      } else {
        Section("Your installation") {
          if let folder = model.installedAt {
            Text(folder).font(.callout).textSelection(.enabled)
          } else {
            Text("No Windows folder chosen yet.")
          }
          if let version = model.clientVersion { Text("EA app \(version)").font(.caption) }
          Button("Choose Windows Folder…", action: model.chooseInstallation)
            .disabled(model.isBusy)
          Text(
            """
            This app runs your own installation where it is. It never copies the game, never \
            duplicates your Windows folder, and never stores your EA sign-in.
            """
          ).font(.caption).foregroundStyle(.secondary)
        }
      }
      if let blocker = model.blocker {
        Section("Before you can play") { Text(blocker) }
      }
      Section("Rosetta") {
        Text(
          model.rosetta.isAvailable
            ? "Rosetta is available."
            : "Install Rosetta to run this Windows game on Apple silicon.")
        if let issue = model.rosetta.issue { Text(issue).foregroundStyle(.red) }
        HStack {
          Button("Install Rosetta…", action: model.installRosetta)
            .disabled(model.rosetta.isAvailable)
          Button("Refresh", action: model.refreshRosetta)
        }
      }
      Section("How a session starts") {
        Text(
          """
          The EA app opens first and must finish signing in. The app then asks it to launch \
          Need for Speed. Quitting the EA app ends the session.
          """
        ).font(.callout)
      }
    }.formStyle(.grouped)
  }
}

struct NFS2015View: View {
  @Bindable var model: NFS2015Model

  var body: some View {
    NavigationSplitView {
      List(selection: $model.tab) {
        Label("Play", systemImage: "play.fill").tag("Play")
        Label("Settings", systemImage: "slider.horizontal.3").tag("Settings")
      }
      .navigationSplitViewColumnWidth(min: 185, ideal: 205, max: 250)
      .navigationTitle("Need for Speed")
    } detail: {
      VStack(spacing: 0) {
        Group {
          switch model.tab {
          case "Settings": NFS2015SettingsView(model: model)
          default: NFS2015PlayView(model: model)
          }
        }
        .disabled(model.isBusy)
        Divider()
        HStack {
          if let fraction = model.preparationFraction {
            ProgressView(value: fraction).frame(width: 120)
          } else if model.isBusy {
            ProgressView().controlSize(.small)
          }
          Text(model.statusMessage).font(.callout)
            .foregroundStyle(model.errorMessage == nil ? .secondary : .primary)
          Spacer()
          if model.hasPendingChanges {
            Button("Discard", action: model.discard)
          }
          Button("Save Settings", action: model.apply)
            .disabled(!model.canEditSettings || !model.hasPendingChanges)
          Button("Play", action: model.play).buttonStyle(.borderedProminent)
            .disabled(!model.canPlay)
        }.padding()
      }
      .frame(minWidth: 660, minHeight: 560)
      .navigationTitle(model.tab == "Play" ? "Need for Speed" : "Settings")
      .toolbar {
        Button("Reload", systemImage: "arrow.clockwise", action: model.reload)
          .disabled(model.isBusy)
        Button("Open Log", systemImage: "doc.text", action: model.showLog).disabled(model.isBusy)
      }
    }
  }
}

@main
struct NFS2015App: App {
  @State private var model = NFS2015Model()

  var body: some Scene {
    Window("Need for Speed", id: "launcher") {
      NFS2015View(model: model)
        .task(id: model.request) { await model.run() }
    }
    .defaultSize(width: 900, height: 700)
  }
}

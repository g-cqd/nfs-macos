import NFS2015Core
import SwiftUI

struct NFS2015SettingsView: View {
  @Bindable var model: NFS2015Model
  @State private var showsExperimental = false
  @State private var confirmsRestore = false

  private static let pages: [NFS2015SettingGroup] = [.display, .quality, .controls, .audio]

  var body: some View {
    Form {
      if let notice = model.settingsNotice {
        Section { Text(notice).font(.callout) }
      }
      if model.showsSettingControls {
        Group {
          closeTheGame
          ForEach(Self.pages, id: \.self) { group in
            Section(group.title) {
              if group == .quality {
                Button("Maximum Quality", action: model.applyMaximumQuality)
                Text(
                  """
                  Sets all six detail levels to 3 and turns motion blur and film grain off. The \
                  resolution is not changed. Nothing is written until you press Save Settings.
                  """
                ).font(.caption).foregroundStyle(.secondary)
              }
              rows(in: group)
            }
          }
          experimental
          launchOptions
          recovery
        }
        .disabled(!model.canEditSettings)
        outcome
      }
      NFS2015MetalFXView(model: model)
      controller
    }
    .formStyle(.grouped)
    .confirmationDialog(
      "Restore the options file the game wrote?", isPresented: $confirmsRestore,
      titleVisibility: .visible
    ) {
      Button("Restore Game Defaults", role: .destructive, action: model.restoreGameDefaults)
    } message: {
      Text("Settings you changed since this app first saved, here or in the game, are lost.")
    }
  }

  private func rows(in group: NFS2015SettingGroup) -> some View {
    ForEach(model.settings(in: group)) { setting in
      NFS2015SettingRow(
        setting: setting, isChangeable: model.isChangeable(setting),
        recorded: model.recordedText(setting), value: model.binding(setting.id),
        number: model.numberBinding(setting.id))
    }
  }

  private var closeTheGame: some View {
    Section("On this Mac") {
      Text(
        """
        Quit the game before saving: it reads this file when it starts and rewrites it when it \
        exits, so a change made while it runs is lost. This app refuses to save while the game \
        is running, and keeps a copy of the file before its first change.
        """
      ).font(.callout)
      Text(
        """
        On a Retina display the game runs at the display's native size, such as 2560x1600, \
        because this app sets Wine's RetinaMode. Vertical sync may hold the frame rate at 60 on a \
        ProMotion display. MetalFX upscaling has its own section below. A PlayStation \
        controller that the game does not see is handled by the separate Enable Controller \
        Support button below.
        """
      ).font(.caption).foregroundStyle(.secondary)
    }
  }

  private var experimental: some View {
    Section {
      DisclosureGroup("Experimental settings", isExpanded: $showsExperimental) {
        Text(
          """
          These keys are in the game's file, but what their values do has not been confirmed. \
          Change one at a time, play, and note the result. Restore game defaults undoes all of \
          it.
          """
        ).font(.caption).foregroundStyle(.secondary)
        rows(in: .experimental)
      }
    }
  }

  /// A placeholder only: no launch option is passed to the game.
  private var launchOptions: some View {
    Section("Launch options (untested)") {
      Toggle("Pass extra launch options to the game", isOn: .constant(false)).disabled(true)
      Text(
        """
        Some launch options for other games are reported to scale rendering or cap the frame \
        rate. None has been tried with this game, so none is offered and none is passed.
        """
      ).font(.caption).foregroundStyle(.secondary)
    }
  }

  private var recovery: some View {
    Section("Recovery") {
      Button("Restore Game Defaults…") { confirmsRestore = true }
        .disabled(!model.canRestoreOriginal)
      Button("Undo Last Save", action: model.undoLastSave).disabled(!model.canUndoLastSave)
      Text(
        """
        Restore Game Defaults puts the options file back exactly as the game wrote it before this \
        app first changed it, which also drops changes you made in the game's own menus since. \
        Both copies are kept in this app's own folder.
        """
      ).font(.caption).foregroundStyle(.secondary)
    }
  }

  @ViewBuilder private var outcome: some View {
    if let refusal = model.refusal {
      Section("Nothing was written") { Text(refusal).font(.callout) }
    } else if !model.outcomeLines.isEmpty {
      Section("Result") {
        ForEach(model.outcomeLines, id: \.self) { Text($0).font(.callout) }
      }
    }
  }

  private var controller: some View {
    Section("Controller") {
      Text(
        """
        This game reads controllers through XInput only. If a connected pad is not detected, let \
        the app record the one Wine setting that presents it as an Xbox controller.
        """
      ).font(.caption).foregroundStyle(.secondary)
      Button("Enable Controller Support", action: model.enableController)
        .disabled(model.isBusy || model.blocker != nil)
    }
  }
}

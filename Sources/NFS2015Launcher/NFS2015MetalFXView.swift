import NFS2015Core
import SwiftUI

/// The MetalFX group of the settings page.
///
/// It is not part of the game's options file, so it works before the game has written one. What
/// it keeps is this app's own choice, which the next launch hands to DXMT for the game alone.
struct NFS2015MetalFXView: View {
  @Bindable var model: NFS2015Model

  var body: some View {
    Section(NFS2015MetalFX.heading) {
      Toggle(
        "Upscale with MetalFX (spatial), \(NFS2015MetalFX.statusLabel)",
        isOn: model.metalFXEnabledBinding())
      Text(NFS2015MetalFX.crashWarning).font(.callout)
      Picker("Scale factor", selection: model.metalFXFactorBinding()) {
        ForEach(NFS2015UpscaleFactor.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      .disabled(!model.metalFX.spatialUpscaling)
      Text(model.metalFXSummary).font(.callout)
      Text(
        """
        DXMT, the Direct3D 11 layer this game runs on, draws each frame as usual and then enlarges \
        the finished picture with MetalFX before it is shown. The game is not told: its \
        resolution, menus and mouse stay as they are. The size shown is the game's resolution \
        times the factor, so this can only help when the game runs below what the display can \
        show. It applies to the game from its next start and never to the EA app. It is off \
        unless you turn it on, and DXMT has no quality setting for it. It is experimental and \
        known to crash NFS16, as the note above the factor says.
        """
      ).font(.caption).foregroundStyle(.secondary)
      Text(
        """
        Temporal upscaling and frame generation are not offered: DXMT can only use them when a \
        game asks for NVIDIA DLSS, which this game does not, and Direct3D 11 gives DXMT no \
        motion vectors or camera jitter otherwise.
        """
      ).font(.caption).foregroundStyle(.secondary)
      HStack {
        Button("Save MetalFX", action: model.saveMetalFX)
          .disabled(!model.hasPendingMetalFX || !model.canEditMetalFX)
        Button("Discard", action: model.discardMetalFX).disabled(!model.hasPendingMetalFX)
        Button("Reset MetalFX", action: model.resetMetalFX).disabled(!model.canResetMetalFX)
      }
      result
    }
    .disabled(!model.canEditMetalFX)
  }

  @ViewBuilder private var result: some View {
    if let notice = model.metalFXNotice { Text(notice).font(.callout) }
    if let refusal = model.metalFXRefusal {
      Text("Nothing was changed: \(refusal)").font(.callout)
    } else if let line = model.metalFXOutcomeLine {
      Text(line).font(.callout)
    }
    if model.hasPendingMetalFX {
      Text("Not saved yet. The game starts with the saved choice until you press Save MetalFX.")
        .font(.caption)
    }
  }
}

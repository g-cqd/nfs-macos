import FarCry2Core
import SwiftUI

struct FarCry2ShaderCacheView: View {
  @Bindable var model: FarCry2Model
  var body: some View {
    Form {
      Section("Shader cache") {
        LabeledContent("Saved", value: model.shaderCacheSummary)
        if let origin = model.shaderCacheOrigin {
          Text(origin).font(.caption).foregroundStyle(.secondary)
        }
        if let notice = model.shaderCacheNotice {
          Text(notice).font(.callout)
        }
        Text(
          "Far Cry 2's shaders are compiled for your Mac while you play, because the game asks for them only when a scene needs them. The result is saved here, outside the app and the game copy, and the game starts from it next time. It survives app updates and a rebuilt Wine prefix. A new version of the renderer starts a new cache."
        )
        .font(.caption).foregroundStyle(.secondary)
        if model.shaderCache.otherBuilds > 0 {
          Text(
            "\(model.shaderCache.otherBuilds) cache(s) from earlier renderer versions are kept for now and are never used."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
      }
      Section("Another Mac or a fresh install") {
        HStack {
          Button("Export…", action: model.exportShaderCache).disabled(!model.canExportShaderCache)
          Button("Import…", action: model.importShaderCache).disabled(!model.canImportShaderCache)
        }
        Text(
          "Export the cache after you have played, and import it on another Mac or after reinstalling. It only works with the same renderer version. The file contains shader data the game generated on your Mac; keep it for your own use. This app never ships one."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      Section("Start over") {
        Button("Reset Shader Cache…") { model.shaderResetConfirmation = true }
          .disabled(!model.canResetShaderCache)
        Text("The next launch compiles shaders again and may pause while it does.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }.formStyle(.grouped)
  }
}

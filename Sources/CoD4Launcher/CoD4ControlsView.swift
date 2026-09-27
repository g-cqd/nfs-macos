import CoD4Core
import SwiftUI

struct CoD4ControlsView: View {
  @Bindable var model: CoD4Model
  var body: some View {
    Form {
      Section("Controller detection") {
        Text(model.controllerStatus)
        Button("Refresh Controllers", action: model.refreshControllers)
        Text(
          "macOS can detect a controller without the Windows game accepting it. Native gamepad input and rumble are unverified in this PC build. Use keyboard and mouse, or an external controller-to-keyboard mapping you configure separately."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      Section("Keyboard & mouse bindings") {
        Picker("Key or button", selection: $model.keySelection) {
          ForEach(CoD4Bindings.keys, id: \.self) { Text($0).tag($0) }
        }
        Picker("Action", selection: $model.bindingCommand) {
          ForEach(CoD4Bindings.actions) { Text($0.title).tag($0.id) }
        }
        Text(model.bindingDescription).font(.caption).foregroundStyle(.secondary)
        HStack {
          Button("Keep Existing Game Binding", action: model.clearBindingOverride)
          Button("Use Default PC Bindings", action: model.resetBindings)
        }
      }
      Section("Mouse") {
        ForEach(model.settings(in: "Mouse")) { setting in
          CoD4SettingRow(setting: setting, value: model.settingBinding(setting.id))
        }
      }
    }.formStyle(.grouped)
  }
}

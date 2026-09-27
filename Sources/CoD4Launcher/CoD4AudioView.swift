import SwiftUI

struct CoD4AudioView: View {
  @Bindable var model: CoD4Model
  var body: some View {
    Form {
      ForEach(["Audio", "Gameplay"], id: \.self) { group in
        Section(group) {
          ForEach(model.settings(in: group)) { setting in
            CoD4SettingRow(setting: setting, value: model.settingBinding(setting.id))
          }
        }
      }
    }.formStyle(.grouped)
  }
}

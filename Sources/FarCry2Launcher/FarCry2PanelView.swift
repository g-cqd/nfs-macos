import FarCry2Core
import SwiftUI

/// A tab made of catalog groups, in the order the catalog lists them.
struct FarCry2PanelView: View {
  @Bindable var model: FarCry2Model
  let groups: [String]
  var notice: String?

  var body: some View {
    Form {
      if let notice {
        Section { Text(notice).font(.callout).foregroundStyle(.secondary) }
      }
      ForEach(groups, id: \.self) { group in
        Section(group) {
          ForEach(model.settings(in: group)) { setting in
            FarCry2SettingRow(setting: setting, value: model.settingBinding(setting.id))
          }
        }
      }
      Section { Text(model.profileNotice).font(.caption).foregroundStyle(.secondary) }
    }.formStyle(.grouped)
  }
}

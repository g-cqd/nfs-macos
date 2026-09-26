import LauncherCore
import SwiftUI

struct ControlsView: View {
  @Bindable var model: LauncherModel

  var body: some View {
    Form {
      Section("Connected controllers") {
        Text(model.controllerStatus)
        Button("Refresh controllers", action: model.refreshControllers)
      }
      Section("Controller settings") {
        ForEach(model.basicControls) { definition in
          SettingRow(definition: definition, model: model)
        }
      }
      Section("Camera & input behavior") {
        DisclosureGroup("More controller options") {
          ForEach(model.advancedControls) { definition in
            SettingRow(definition: definition, model: model)
          }
        }
      }
      Section("Action mappings") {
        Picker("Profile", selection: $model.selectedMappingProfile) {
          ForEach(model.mappingProfiles, id: \.self) { profile in
            Text(profile.isEmpty ? "Defaults for new profiles" : profile).tag(profile)
          }
        }
        Text(
          "Mappings are stored per profile. Apply Settings saves all edited profiles. LT / L2 and RT / R2 retain analog values for throttle and braking. Right stick bindings can also move the orbit camera."
        )
        .font(.caption).foregroundStyle(.secondary)
        Button("Reset selected mappings", action: model.resetMappings)
      }
      ForEach(ControllerAction.groups, id: \.self) { group in
        Section {
          DisclosureGroup(group) {
            ForEach(model.actions(in: group)) { action in
              Picker(action.title, selection: model.commandBinding(action.id)) {
                ForEach(ControllerMappings.buttons) { button in
                  ControllerButtonLabel(button: model.controllerButton(button)).tag(button.id)
                }
              }
            }
          }
        }
      }
    }
    .formStyle(.grouped)
  }
}

import Foundation

package struct ControllerMappings: Codable, Equatable, Sendable {
  package var bindings: [String: String] = [:]
  package init() {}

  package func value(for action: String) -> String {
    bindings[action] ?? ControllerAction.all.first { $0.id == action }?.defaultBinding ?? "NONE"
  }

  package func validate() throws(LauncherError) {
    guard bindings.count <= ControllerAction.all.count else {
      throw .operation("Too many controller bindings.")
    }
    for (action, binding) in bindings {
      guard ControllerAction.all.contains(where: { $0.id == action }),
        Self.buttons.contains(where: { $0.id == binding })
      else { throw .operation("Unknown controller action or button: \(action).") }
    }
  }

  package init(text: String) throws(LauncherError) {
    let ini = try ConfigText(text)
    for action in ControllerAction.all {
      if let value = ini.value(section: "Events", key: action.id) {
        bindings[action.id] = value.isEmpty || value == "-1" ? "NONE" : value
      }
    }
    try validate()
  }

  package func applying(to text: String) throws(LauncherError) -> String {
    try validate()
    var ini = try ConfigText(text)
    for action in ControllerAction.all {
      ini.set(section: "Events", key: action.id, value: value(for: action.id))
    }
    return ini.text
  }

  package static let buttons: [SettingChoice] = [
    .init("NONE", "Unbound"),
    .init("XINPUT_GAMEPAD_A", "A / Cross"), .init("XINPUT_GAMEPAD_B", "B / Circle"),
    .init("XINPUT_GAMEPAD_X", "X / Square"), .init("XINPUT_GAMEPAD_Y", "Y / Triangle"),
    .init("XINPUT_GAMEPAD_LT", "LT / L2 (analog)"), .init("XINPUT_GAMEPAD_RT", "RT / R2 (analog)"),
    .init("XINPUT_GAMEPAD_LEFT_SHOULDER", "LB / L1"),
    .init("XINPUT_GAMEPAD_RIGHT_SHOULDER", "RB / R1"),
    .init("XINPUT_GAMEPAD_LEFT_THUMB", "Left stick click / L3"),
    .init("XINPUT_GAMEPAD_RIGHT_THUMB", "Right stick click / R3"),
    .init("XINPUT_GAMEPAD_START", "Menu / Options"), .init("XINPUT_GAMEPAD_BACK", "View / Share"),
    .init("XINPUT_GAMEPAD_DPAD_UP", "D-pad up"), .init("XINPUT_GAMEPAD_DPAD_DOWN", "D-pad down"),
    .init("XINPUT_GAMEPAD_DPAD_LEFT", "D-pad left"),
    .init("XINPUT_GAMEPAD_DPAD_RIGHT", "D-pad right"),
    .init("XINPUT_GAMEPAD_LS_UP", "Left stick up"),
    .init("XINPUT_GAMEPAD_LS_DOWN", "Left stick down"),
    .init("XINPUT_GAMEPAD_LS_LEFT", "Left stick left"),
    .init("XINPUT_GAMEPAD_LS_RIGHT", "Left stick right"),
    .init("XINPUT_GAMEPAD_RS_UP", "Right stick up"),
    .init("XINPUT_GAMEPAD_RS_DOWN", "Right stick down"),
    .init("XINPUT_GAMEPAD_RS_LEFT", "Right stick left"),
    .init("XINPUT_GAMEPAD_RS_RIGHT", "Right stick right"),
    .init("XINPUT_GAMEPAD_LS_X", "Left stick horizontal axis"),
    .init("XINPUT_GAMEPAD_LS_Y", "Left stick vertical axis"),
    .init("XINPUT_GAMEPAD_RS_X", "Right stick horizontal axis"),
    .init("XINPUT_GAMEPAD_RS_Y", "Right stick vertical axis"),
  ]
}

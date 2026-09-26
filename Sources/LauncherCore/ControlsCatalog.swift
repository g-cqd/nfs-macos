package enum ControlsCatalog {
  private static let toggle = [SettingChoice("0", "Off"), SettingChoice("1", "On")]
  private static let deadzones = ["0", "0.05", "0.1", "0.12", "0.15", "0.2", "0.25", "0.3", "0.4"]
    .map { SettingChoice($0, String(Int((Double($0) ?? 0) * 100)) + "%") }
  package static let settings: [SettingDefinition] = [
    .init(
      "icons", "Controller button labels", "Controller", .input, "Icons", "ControllerIconMode", "1",
      choices: [
        .init("0", "Xbox One / Series"), .init("1", "PlayStation 4 / 5"), .init("2", "Xbox 360"),
        .init("3", "PlayStation 3"),
      ],
      help:
        "Choose labels for your connected controller. Wine translates compatible Xbox and PlayStation pads to the same controls."
    ),
    .init(
      "leftDeadzone", "Left stick dead zone", "Controller", .input, "Deadzone", "PercentLS", "0.12",
      choices: deadzones,
      help:
        "Ignore small movements near the center. Increase this if a released stick causes drift."),
    .init(
      "rightDeadzone", "Right stick dead zone", "Controller", .input, "Deadzone", "PercentRS",
      "0.12", choices: deadzones),
    .init(
      "cameraDeadzone", "Orbit camera dead zone (%)", "Controller", .widescreen, "MISC",
      "RightStickDeadzone", "20", range: 0...50),
    .init(
      "triggerThreshold", "Trigger threshold for digital actions", "Controller", .input, "Deadzone",
      "Percent_AnalogTriggerDigital", "0.12", choices: deadzones,
      help: "Driving throttle and brake bindings retain continuous trigger values."),
    .init(
      "stickThreshold", "Stick threshold for digital actions", "Controller", .input, "Deadzone",
      "Percent_AnalogStickDigital", "0.50",
      choices: [.init("0.25", "25%"), .init("0.50", "50%"), .init("0.75", "75%")]),
    .init(
      "invertCamera", "Invert camera", "Controller", .widescreen, "CAMERA", "InvertLook", "0",
      choices: toggle),
    .init(
      "horizontalCamera", "Horizontal camera only", "Controller", .widescreen, "CAMERA",
      "OnlyAllowHorizontalStickMovement", "0", choices: toggle),
    .init(
      "cameraSensitivity", "Camera stick sensitivity", "Controller", .widescreen, "CAMERA",
      "StickLookSensitivity", "1",
      choices: [.init("0.5", "0.5×"), .init("1", "1×"), .init("1.5", "1.5×"), .init("2", "2×")]),
    .init(
      "mouseLook", "Mouse look in debug camera", "Controller", .input, "Input", "MouseLook", "1",
      choices: toggle),
    .init(
      "hideMouse", "Hide idle game cursor", "Controller", .input, "Input", "EnableMouseHiding", "1",
      choices: toggle),
  ]
}

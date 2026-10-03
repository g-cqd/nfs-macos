import Foundation

extension NFS2015Catalog {
  static let sensitivityHelp = """
    The game wrote 0, which probably means "use the default". Its real range is not recorded, so \
    this app only rejects negative and absurd numbers.
    """

  static let controls: [NFS2015Setting] = [
    .init(
      "input.deadZoneSteering", "Steering dead zone", .controls, "0", .number(0...0.5, decimals: 6),
      keys: ["GstInput.DeadZonePadSteering"], source: .reported,
      help: """
        For a connected game controller, which this game reads natively. The 0 to 0.5 limit is \
        this app's own. A controller Wine does not present as an Xbox pad needs the separate \
        Enable Controller Support button below.
        """),
    .init(
      "input.deadZoneThrottle", "Throttle dead zone", .controls, "0",
      .number(0...0.5, decimals: 6), keys: ["GstInput.DeadZonePadThrottle"], source: .reported),
    .init(
      "input.deadZoneBrake", "Brake dead zone", .controls, "0", .number(0...0.5, decimals: 6),
      keys: ["GstInput.DeadZonePadBrake"], source: .reported),
    .init(
      "input.sensitivitySteering", "Steering sensitivity", .controls, "0",
      .number(0...100, decimals: 6), keys: ["GstInput.SensitivityPadSteering"], source: .reported,
      help: sensitivityHelp),
    .init(
      "input.sensitivityThrottle", "Throttle sensitivity", .controls, "0",
      .number(0...100, decimals: 6), keys: ["GstInput.SensitivityPadThrottle"], source: .reported),
    .init(
      "input.sensitivityBrake", "Brake sensitivity", .controls, "0",
      .number(0...100, decimals: 6), keys: ["GstInput.SensitivityPadBrake"], source: .reported),
    .init(
      "input.vibration", "Vibration", .controls, "2",
      .choices([.init("0", "0"), .init("1", "1"), .init("2", "2")]),
      keys: ["GstInput.Vibration"], source: .reported,
      help: "The game wrote 2. What 0 and 1 mean is not recorded; try them in the game."),
    .init(
      "input.autoReverse", "Auto reverse in manual gears", .controls, "1", toggle,
      keys: ["GstInput.AutoReverseForManualGears"]),
  ]

  static let audio: [NFS2015Setting] = [
    .init(
      "audio.music", "Music volume", .audio, "1", unitRange, keys: ["GstAudio.MusicVolume"],
      source: .reported),
    .init(
      "audio.effects", "Sound effects volume", .audio, "1", unitRange,
      keys: ["GstAudio.SoundEffectVolume"], source: .reported),
    .init(
      "audio.speech", "Speech volume", .audio, "1", unitRange, keys: ["GstAudio.SpeechVolume"],
      source: .reported),
    .init(
      "audio.subtitles", "Subtitles", .audio, "0", toggle, keys: ["GstAudio.DisplaySubtitles"]),
    .init("audio.copVoice", "Police voice", .audio, "1", toggle, keys: ["GstAudio.CopVoice"]),
    .init(
      "audio.pursuitMusic", "Pursuit music", .audio, "1", toggle, keys: ["GstAudio.PursuitMusic"]),
  ]

  static let experimental: [NFS2015Setting] = [
    .init(
      "render.vsync", "Vertical sync", .experimental, "0", toggle, keys: ["GstRender.VSyncEnabled"],
      help: """
        The file holds this and Present interval, and which one the game obeys is not known. \
        Change one at a time and report what happens. On a ProMotion display the presented rate \
        may be held at 60.
        """),
    .init(
      "render.presentInterval", "Present interval", .experimental, "1",
      .choices([.init("0", "0"), .init("1", "1"), .init("2", "2")]),
      keys: ["GstRender.PresentInterval"], source: .reported,
      help: "The game wrote 1. Whether 0 or 2 is accepted, and what it does, is not recorded."),
    .init(
      "render.antiAliasing", "Post anti-aliasing", .experimental, "2", .observed,
      keys: ["GstRender.AntiAliasingPost"], source: .reported,
      help: """
        Shown, not changed: what each value means has not been recorded. Change it in the game's \
        own menu, quit, and reload here to see which value it wrote.
        """),
    .init(
      "render.ambientOcclusion", "Ambient occlusion", .experimental, "2", .observed,
      keys: ["GstRender.AmbientOcclusion"], source: .reported,
      help: "Shown, not changed, for the same reason as post anti-aliasing."),
    .init(
      "render.safeAreaWidth", "Safe area width", .experimental, "0.9",
      .number(0.3...1, decimals: 6), keys: ["GstRender.ScreenSafeAreaWidth"], source: .reported,
      help: "The share of the screen width that the interface keeps inside. Reported: 0.3 to 1."),
    .init(
      "render.safeAreaHeight", "Safe area height", .experimental, "0.9",
      .number(0.3...1, decimals: 6), keys: ["GstRender.ScreenSafeAreaHeight"], source: .reported,
      help: "The same for the height."),
  ]
}

import Foundation
import Testing

/// A synthetic options file in the shape the game writes: `Key Value` lines, ASCII, numbers only.
/// Every value is invented. No line comes from a player's file, and the key-binding lines are a
/// few made-up lines in the form the game uses, not a copy of any real set.
enum OptionsFixture {
  static let lines: [String] = [
    "GstAudio.CopVoice 1",
    "GstAudio.DisplaySubtitles 0",
    "GstAudio.DynamicsEnum 2",
    "GstAudio.MusicVolume 0.750000",
    "GstAudio.NewMessageSound 1",
    "GstAudio.Playlist -1",
    "GstAudio.PursuitMusic 1",
    "GstAudio.SoundEffectVolume 1.000000",
    "GstAudio.SpeechVolume 1.000000",
    "GstRender.AmbientOcclusion 2",
    "GstRender.AntiAliasingPost 2",
    "GstRender.Brightness 0.500000",
    "GstRender.EffectsQuality 2",
    "GstRender.FilmGrain 1",
    "GstRender.FullscreenEnabled 1",
    "GstRender.FullscreenRefreshRate 60.000000",
    "GstRender.MeshQuality 2",
    "GstRender.MotionBlurEnabled 1",
    "GstRender.PresentInterval 1",
    "GstRender.ResolutionHeight 1600",
    "GstRender.ResolutionWidth 2560",
    "GstRender.ScreenSafeAreaHasBeenSet 1",
    "GstRender.ScreenSafeAreaHeight 0.900000",
    "GstRender.ScreenSafeAreaWidth 0.900000",
    "GstRender.ShadowQuality 1",
    "GstRender.TerrainQuality 1",
    "GstRender.TextureQuality 3",
    "GstRender.UndergrowthQuality 1",
    "GstRender.VSyncEnabled 0",
    "GstInput.AutoReverseForManualGears 1",
    "GstInput.CustomControlsPad 0",
    "GstInput.DeadZoneJoystickBrake 0.000000",
    "GstInput.DeadZonePadBrake 0.000000",
    "GstInput.DeadZonePadSteering 0.100000",
    "GstInput.DeadZonePadThrottle 0.000000",
    "GstInput.SensitivityJoystickSteering 0.000000",
    "GstInput.SensitivityPadBrake 0.000000",
    "GstInput.SensitivityPadSteering 0.000000",
    "GstInput.SensitivityPadThrottle 0.000000",
    "GstInput.Vibration 2",
    "GstKeyBinding.default.ConceptExample.0.axis 24",
    "GstKeyBinding.default.ConceptExample.0.button 23",
    "GstKeyBinding.racevehicle.ConceptSample.5.type 3",
  ]

  /// The file as text, with the given line ending; the last line is terminated unless asked not.
  static func text(
    lineEnding: String = "\n", terminated: Bool = true, lines: [String] = OptionsFixture.lines
  ) -> String {
    lines.joined(separator: lineEnding) + (terminated ? lineEnding : "")
  }

  static func data(lineEnding: String = "\n", terminated: Bool = true) -> Data {
    Data(text(lineEnding: lineEnding, terminated: terminated).utf8)
  }

  /// The same file with one key's value replaced, line endings untouched.
  static func replacing(
    _ key: String, with value: String, in text: String = OptionsFixture.text()
  ) -> String {
    let marker = key + " "
    guard let start = text.range(of: marker) else { return text }
    let end =
      text[start.upperBound...].firstIndex(where: { $0 == "\n" || $0 == "\r\n" })
      ?? text.endIndex
    return text.replacingCharacters(in: start.upperBound..<end, with: value)
  }
}

/// A named variant of a file's text, so a failing parameterized case is easy to identify.
struct TextVariant: Sendable, CustomTestStringConvertible {
  let name: String
  let text: String
  var testDescription: String { name }

  init(_ name: String, _ text: String) {
    self.name = name
    self.text = text
  }
}

import LauncherCore

struct ControllerButtonPresentation {
  let title: String
  let symbol: String

  init(binding: SettingChoice, playStation: Bool) {
    let button = binding.id.replacingOccurrences(of: "XINPUT_GAMEPAD_", with: "")
    switch button {
    case "A": (title, symbol) = playStation ? ("Cross", "xmark.circle") : ("A", "a.circle")
    case "B": (title, symbol) = playStation ? ("Circle", "circle.circle") : ("B", "b.circle")
    case "X": (title, symbol) = playStation ? ("Square", "square.circle") : ("X", "x.circle")
    case "Y": (title, symbol) = playStation ? ("Triangle", "triangle.circle") : ("Y", "y.circle")
    case "LT":
      (title, symbol) =
        playStation
        ? ("L2 · analog", "l2.button.roundedtop.horizontal")
        : ("LT · analog", "lt.button.roundedtop.horizontal")
    case "RT":
      (title, symbol) =
        playStation
        ? ("R2 · analog", "r2.button.roundedtop.horizontal")
        : ("RT · analog", "rt.button.roundedtop.horizontal")
    case "LEFT_SHOULDER":
      (title, symbol) =
        playStation
        ? ("L1", "l1.button.roundedbottom.horizontal")
        : ("LB", "lb.button.roundedbottom.horizontal")
    case "RIGHT_SHOULDER":
      (title, symbol) =
        playStation
        ? ("R1", "r1.button.roundedbottom.horizontal")
        : ("RB", "rb.button.roundedbottom.horizontal")
    case "LEFT_THUMB":
      (title, symbol) = (
        playStation ? "L3 · left stick click" : "Left stick click", "l.joystick.press.down"
      )
    case "RIGHT_THUMB":
      (title, symbol) = (
        playStation ? "R3 · right stick click" : "Right stick click", "r.joystick.press.down"
      )
    case "START": (title, symbol) = (playStation ? "Options" : "Menu", "line.3.horizontal.circle")
    case "BACK": (title, symbol) = (playStation ? "Share" : "View", "rectangle.on.rectangle")
    case "DPAD_UP": (title, symbol) = ("D-pad up", "dpad.up.filled")
    case "DPAD_DOWN": (title, symbol) = ("D-pad down", "dpad.down.filled")
    case "DPAD_LEFT": (title, symbol) = ("D-pad left", "dpad.left.filled")
    case "DPAD_RIGHT": (title, symbol) = ("D-pad right", "dpad.right.filled")
    default:
      title = binding.title
      symbol =
        button.hasPrefix("LS_")
        ? "l.joystick" : button.hasPrefix("RS_") ? "r.joystick" : "minus.circle"
    }
  }
}

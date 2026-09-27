/// Safe keyboard and mouse commands; arbitrary console commands are never imported into setup files.
package enum CoD4Bindings {
  package struct Action: Identifiable, Sendable {
    package let id: String
    package let title: String
    package init(_ id: String, _ title: String) {
      self.id = id
      self.title = title
    }
  }
  package static let actions: [Action] = [
    .init("", "Unbound"), .init("+forward", "Forward"), .init("+back", "Backward"),
    .init("+moveleft", "Move left"), .init("+moveright", "Move right"),
    .init("+leanleft", "Lean left"), .init("+leanright", "Lean right"),
    .init("+breath_sprint", "Sprint / hold breath"), .init("+attack", "Fire"),
    .init("+toggleads_throw", "Aim / throw"), .init("+melee", "Melee"),
    .init("+frag", "Frag grenade"), .init("+smoke", "Special grenade"),
    .init("+activate", "Use"), .init("+reload", "Reload"), .init("weapnext", "Next weapon"),
    .init("+gostand", "Jump / stand"), .init("goprone", "Prone"), .init("gocrouch", "Crouch"),
    .init("+actionslot 1", "Night vision"), .init("+actionslot 2", "Action slot 2"),
    .init("+actionslot 3", "Action slot 3"), .init("+actionslot 4", "Action slot 4"),
    .init("+scores", "Scores"), .init("togglemenu", "Menu"), .init("pause", "Pause"),
    .init("toggle cl_paused", "Pause multiplayer"), .init("toggleconsole", "Console"),
    .init("screenshotJPEG", "Screenshot"), .init("chatmodepublic", "Public chat"),
    .init("chatmodeteam", "Team chat"), .init("mp_QuickMessage", "Quick message"),
    .init("+talk", "Voice chat"), .init("vote yes", "Vote yes"), .init("vote no", "Vote no"),
  ]
  package static let keys =
    Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789").map(String.init)
    + (1...12).map { "F\($0)" }
    + [
      "SPACE", "CTRL", "SHIFT", "ALT", "TAB", "ESCAPE", "PAUSE", "ENTER", "BACKSPACE",
      "UPARROW", "DOWNARROW", "LEFTARROW", "RIGHTARROW", "MOUSE1", "MOUSE2", "MOUSE3",
      "MOUSE4", "MOUSE5", "MWHEELUP", "MWHEELDOWN", "`", "~",
    ]
  package static let defaults: [String: String] = [
    "W": "+forward", "S": "+back", "A": "+moveleft", "D": "+moveright",
    "Q": "+leanleft", "E": "+leanright", "SHIFT": "+breath_sprint",
    "MOUSE1": "+attack", "MOUSE2": "+toggleads_throw", "V": "+melee",
    "N": "+actionslot 1", "7": "+actionslot 2", "5": "+actionslot 3", "6": "+actionslot 4",
    "1": "weapnext", "2": "weapnext", "MOUSE3": "+frag", "G": "+frag", "4": "+smoke",
    "F": "+activate", "R": "+reload", "TAB": "+scores", "SPACE": "+gostand",
    "CTRL": "goprone", "C": "gocrouch", "PAUSE": "pause", "ESCAPE": "togglemenu",
    "~": "toggleconsole", "`": "toggleconsole", "F12": "screenshotJPEG",
  ]
  package static func accepts(key: String, command: String) -> Bool {
    keys.contains(key) && actions.contains { $0.id == command }
  }
}

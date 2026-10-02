import Foundation

/// What a player does on the first start of a bundled app on a Mac, in the order they do it.
///
/// The EA app comes with the app, so there is nothing to download or install. The player waits,
/// signs in to their own EA account in EA's window, and plays. The two prompts that come from
/// outside this app are named so neither is a surprise.
struct NFS2015FirstRunGuide: Equatable {
  struct Step: Equatable {
    let title: String
    let detail: String
  }

  /// Whether macOS is running the app from a temporary read-only copy.
  ///
  /// macOS does that for an app that was downloaded or transferred and not yet moved or approved
  /// (App Translocation). The game files then cannot be cloned into the player's folder, so the
  /// first start copies all 14.6 GB and needs that much free space.
  let translocated: Bool

  init(bundle: URL = Bundle.main.bundleURL) {
    translocated = Self.isTranslocated(bundle)
  }

  static func isTranslocated(_ bundle: URL) -> Bool {
    bundle.standardizedFileURL.pathComponents.contains("AppTranslocation")
  }

  static let steps = [
    Step(
      title: "Wait for the first start",
      detail: """
        The app prepares its own Windows folder once, with the EA app and the game files that \
        come with it. This takes a few minutes and needs no internet.
        """),
    Step(
      title: "Sign in to EA",
      detail: """
        Press Open EA App and sign in with your own EA account in EA's window, then quit the EA \
        app. This app never sees, stores or copies your sign-in.
        """),
    Step(
      title: "Press Play",
      detail: """
        EA may ask you to activate the game on this Mac once, and macOS may ask whether the app \
        may use the microphone (for the game's voice chat). Answer as you prefer.
        """),
  ]

  /// Shown when the app is translocated; the fix is one move or one command.
  static let translocationNotice = """
    macOS is running this app from a temporary read-only copy, because it was downloaded or \
    transferred. The first start then copies all of the game files (about 15 GB) instead of \
    sharing them. To avoid that, quit, move the app to your Applications folder or run \
    xattr -dr com.apple.quarantine on it, and open it again.
    """

  static let installerNote = """
    The EA app is already installed here. Reinstall EA App… is only for a newer EA app than \
    the one that came with this app.
    """
}

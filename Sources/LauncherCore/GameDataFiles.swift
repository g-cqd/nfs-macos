/// Original game assets supplied by an installed PC copy; all other files come from the app.
package enum GameDataFiles {
  static func contains(_ path: String) -> Bool {
    let components = path.lowercased().split(separator: "/")
    guard let first = components.first else { return false }
    if components.count == 1 {
      return ["speed.exe", "bin.dat", "server.cfg", "server.dll"].contains(first)
    }
    return [
      "cars", "credits", "frontend", "global", "languages", "memcard", "movies", "nis",
      "sound", "subtitles", "tracks",
    ].contains(first)
  }
}

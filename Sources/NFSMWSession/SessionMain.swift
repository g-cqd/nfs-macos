import Darwin
import Foundation
import LauncherCore

@main
struct SessionMain {
  static func main() {
    do {
      let arguments = CommandLine.arguments
      guard [5, 7].contains(arguments.count),
        ["--prepare", "--play", "--configure", "--save", "--import-game"].contains(arguments[1]),
        arguments[3] == "--support"
      else {
        throw LauncherError.operation(
          "Usage: NFSMWSession <mode> <app> --support <player-folder> [--settings <json> | --save-request <json> | --game-data <folder>]"
        )
      }
      let paths = try AppPaths(
        bundle: URL(fileURLWithPath: arguments[2]),
        support: URL(fileURLWithPath: arguments[4]))
      var configuration: URL?
      if arguments.count == 7 {
        let flag =
          arguments[1] == "--import-game"
          ? "--game-data" : (arguments[1] == "--save" ? "--save-request" : "--settings")
        guard arguments[5] == flag else {
          throw LauncherError.operation("Unexpected request argument.")
        }
        configuration = URL(fileURLWithPath: arguments[6])
      }
      guard
        !["--configure", "--save", "--import-game"].contains(arguments[1]) || configuration != nil
      else {
        throw LauncherError.operation("The request is missing its settings or game-data folder.")
      }
      let result = try Session(paths: paths, output: .standardOutput).run(
        mode: arguments[1], configuration: configuration)
      exit(result)
    } catch let error as LauncherError {
      print(error.localizedDescription)
      exit(error == .alreadyRunning ? 73 : 1)
    } catch {
      print("Could not start Most Wanted: \(error.localizedDescription)")
      exit(1)
    }
  }
}

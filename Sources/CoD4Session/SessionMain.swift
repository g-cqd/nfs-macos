import CoD4Core
import Darwin
import Foundation
import LauncherCore

@main
struct SessionMain {
  static func main() {
    do {
      let options = try SessionOptions(arguments: Array(CommandLine.arguments.dropFirst()))
      let paths = try AppPaths(bundle: options.bundle, support: options.support, game: .cod4)
      exit(try CoD4Session(paths: paths, output: .standardOutput).run(options))
    } catch let error as LauncherError {
      print(error.localizedDescription)
      exit(error == .alreadyRunning ? 73 : 1)
    } catch {
      print("Could not complete the CoD4 operation: \(error.localizedDescription)")
      exit(1)
    }
  }
}

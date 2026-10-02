import Darwin
import FarCry2Core
import Foundation
import LauncherCore

@main
struct SessionMain {
  static func main() {
    do {
      let options = try SessionOptions(arguments: Array(CommandLine.arguments.dropFirst()))
      let paths = try AppPaths(bundle: options.bundle, support: options.support, game: .farcry2)
      exit(try FarCry2Session(paths: paths, output: .standardOutput).run(options))
    } catch let error as LauncherError {
      print(error.localizedDescription)
      exit(error == .alreadyRunning ? 73 : 1)
    } catch {
      print("Could not complete the Far Cry 2 operation: \(error.localizedDescription)")
      exit(1)
    }
  }
}

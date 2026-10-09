import Darwin
import Foundation
import LauncherCore

@main
struct SessionMain {
  static func main() {
    do {
      let options = try SessionOptions(arguments: Array(CommandLine.arguments.dropFirst()))
      exit(try BF3Session(options: options).run())
    } catch let error as LauncherError {
      print(error.localizedDescription)
      exit(error == .alreadyRunning ? 73 : 1)
    } catch {
      print("Could not complete the Battlefield 3 operation: \(error.localizedDescription)")
      exit(1)
    }
  }
}

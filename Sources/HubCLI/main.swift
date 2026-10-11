import Foundation
import HubCore

// gamehub-cli: command-line tools for the Game Hub. The families are `datastore` and `runtime`.
let arguments = Array(CommandLine.arguments.dropFirst())
let output: (String) -> Void = { FileHandle.standardOutput.write(Data($0.utf8)) }
let diagnostics: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
switch arguments.first {
case "datastore":
  exit(DatastoreCommand.run(Array(arguments.dropFirst()), output: output, diagnostics: diagnostics))
case "runtime":
  exit(RuntimeCommand.run(Array(arguments.dropFirst()), output: output, diagnostics: diagnostics))
default:
  diagnostics(DatastoreCommand.usage + "\n" + RuntimeCommand.usage)
  exit(1)
}

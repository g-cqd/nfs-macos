import Foundation
import HubCore

// gamehub-cli: command-line tools for the Game Hub. The only family so far is `datastore`.
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.first == "datastore" else {
  FileHandle.standardError.write(Data((DatastoreCommand.usage + "\n").utf8))
  exit(1)
}
let status = DatastoreCommand.run(
  Array(arguments.dropFirst()),
  output: { FileHandle.standardOutput.write(Data($0.utf8)) },
  diagnostics: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) })
exit(status)

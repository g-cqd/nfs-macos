import Foundation

/// The files and symbolic links of a runtime tree, as listed by its manifest and links file.
///
/// The manifest holds one `<sha256>  ./<relative path>` line per regular file; the links file one
/// `./<relative path> -> <target>` line per symbolic link. Paths are stored here without `./`.
package struct RuntimeFileList: Equatable, Sendable {
  package struct File: Equatable, Sendable {
    package let path: String
    package let sha256: String
  }

  package struct Link: Equatable, Sendable {
    package let path: String
    package let target: String
  }

  package let files: [File]
  package let links: [Link]

  /// Parses a manifest and a links file.
  /// - Throws: `.invalid` naming the line for a malformed line, a duplicate path, a path that is
  ///   absolute or holds `..`, or a link whose target would leave the tree.
  /// - Complexity: O(n) in the number of lines.
  package static func parse(manifest: String, links: String) throws(HubError) -> RuntimeFileList {
    var seen = Set<String>()
    var files: [File] = []
    for (index, line) in try lines(of: manifest, name: "manifest").enumerated() {
      let number = index + 1
      guard let separator = line.range(of: "  ") else {
        throw .invalid("manifest line \(number): expected '<sha256>  ./<path>'.")
      }
      let hash = String(line[..<separator.lowerBound])
      try Check.sha256(hash, field: "manifest line \(number)")
      let path = try relativePath(
        String(line[separator.upperBound...]), name: "manifest line \(number)")
      guard seen.insert(path).inserted else {
        throw .invalid("manifest line \(number): duplicate path \(path).")
      }
      files.append(File(path: path, sha256: hash))
    }
    guard !files.isEmpty else { throw .invalid("The manifest lists no files.") }

    var parsed: [(number: Int, link: Link)] = []
    for (index, line) in try lines(of: links, name: "links file").enumerated() {
      let number = index + 1
      let parts = line.components(separatedBy: " -> ")
      guard parts.count == 2 else {
        throw .invalid("links line \(number): expected './<path> -> <target>'.")
      }
      let path = try relativePath(parts[0], name: "links line \(number)")
      guard seen.insert(path).inserted else {
        throw .invalid("links line \(number): duplicate path \(path).")
      }
      let target = parts[1]
      guard !target.isEmpty, !target.hasPrefix("/"), !target.utf8.contains(0) else {
        throw .invalid("links line \(number): the target must be a relative path.")
      }
      parsed.append((number, Link(path: path, target: target)))
    }

    // A link may not sit under another link, and a target may not run through one: a chain of
    // links can climb out of the tree even when each target looks harmless on its own.
    let linkPaths = Set(parsed.map(\.link.path))
    for path in files.map(\.path) + parsed.map(\.link.path) {
      if let ancestor = ancestors(of: path).first(where: linkPaths.contains) {
        throw .invalid("\(path) lies under the link \(ancestor).")
      }
    }
    for (number, link) in parsed
    where !staysInside(link: link.path, target: link.target, linkPaths: linkPaths) {
      throw .invalid(
        "links line \(number): the target \(link.target) leaves the runtime tree or runs through a link."
      )
    }
    return RuntimeFileList(files: files, links: parsed.map(\.link))
  }

  /// The lines of `text`, rejecting blank lines; one trailing newline is allowed.
  private static func lines(of text: String, name: String) throws(HubError) -> [String] {
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if lines.last == "" { lines.removeLast() }
    for (index, line) in lines.enumerated() where line.isEmpty {
      throw .invalid("\(name) line \(index + 1) is blank.")
    }
    return lines
  }

  /// `./a/b` as `a/b`, rejecting anything that is not a plain relative path.
  private static func relativePath(_ raw: String, name: String) throws(HubError) -> String {
    guard raw.hasPrefix("./"), !raw.utf8.contains(0) else {
      throw .invalid("\(name): the path \(raw) must start with './'.")
    }
    let path = String(raw.dropFirst(2))
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !components.isEmpty,
      !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    else {
      throw .invalid("\(name): the path \(raw) is not a plain relative path.")
    }
    return path
  }

  /// `a/b/c` as `a` and `a/b`.
  private static func ancestors(of path: String) -> [String] {
    let components = path.split(separator: "/")
    return (1..<max(components.count, 1)).map { components.prefix($0).joined(separator: "/") }
  }

  /// Whether `target`, read from the folder of `link`, stays inside the tree without passing
  /// through a listed link before its last component.
  private static func staysInside(link: String, target: String, linkPaths: Set<String>) -> Bool {
    var stack = link.split(separator: "/").dropLast().map(String.init)
    let components = target.split(separator: "/").map(String.init)
    for (index, component) in components.enumerated() {
      switch component {
      case ".": continue
      case "..":
        guard stack.popLast() != nil else { return false }
      default:
        stack.append(component)
        if index < components.count - 1, linkPaths.contains(stack.joined(separator: "/")) {
          return false
        }
      }
    }
    return true
  }
}

import Foundation

package enum ProfileName {
  package static func isValid(_ name: String) -> Bool {
    !name.isEmpty && name.utf8.count <= 64 && name != "." && name != ".."
      && name == name.trimmingCharacters(in: .whitespaces)
      && !name.hasPrefix(".") && !name.hasSuffix(".")
      && name.unicodeScalars.allSatisfy {
        $0.value >= 32 && $0.value < 127 && !"/\\:*?\"<>|".unicodeScalars.contains($0)
      }
  }
}

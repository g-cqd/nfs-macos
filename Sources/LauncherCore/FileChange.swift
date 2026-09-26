import Foundation

package struct FileChange {
  package let url: URL
  package let bytes: Data?
  package init(url: URL, bytes: Data?) {
    self.url = url
    self.bytes = bytes
  }
}

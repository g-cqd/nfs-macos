import Darwin
import Foundation

/// How a child process is created.
///
/// `.foundation` is every existing launch (Rosetta-based Wine): it goes through `Process` and is
/// byte-for-byte what the app did before this type existed. `.arm64Wow64` is the native arm64
/// Wine route: the child is made with `posix_spawn` so that spawn attributes Foundation cannot
/// set, in particular the 4 KiB page size, can be requested.
package enum SpawnProfile: Equatable, Sendable {
  case foundation
  case arm64Wow64(fourKilobytePages: Bool)

  /// The name a bundle's `runtime-profile.json` uses for the native arm64 route.
  package static let arm64Wow64Name = "arm64-wow64"

  package var requestsFourKilobytePages: Bool {
    if case .arm64Wow64(let fourKilobytePages) = self { return fourKilobytePages }
    return false
  }

  /// Native arm64 launches never go through Rosetta, so its availability is not a precondition.
  package var needsRosetta: Bool { self == .foundation }

  /// Reads the bundle's runtime profile marker; a bundle without one is a Rosetta bundle.
  package static func load(from resources: URL) throws(LauncherError) -> SpawnProfile {
    let marker = resources.appendingPathComponent("runtime-profile.json")
    guard FileManager.default.fileExists(atPath: marker.path) else { return .foundation }
    struct Marker: Decodable {
      let profile: String
      let fourKilobytePages: Bool?
    }
    let data = try BoundedFile.read(marker, limit: 4096)
    guard let decoded = try? JSONDecoder().decode(Marker.self, from: data) else {
      throw .operation("The bundle's runtime profile is malformed.")
    }
    switch decoded.profile {
    case arm64Wow64Name: return .arm64Wow64(fourKilobytePages: decoded.fourKilobytePages ?? true)
    default: throw .operation("The bundle declares an unknown runtime profile: \(decoded.profile).")
    }
  }
}

/// The `posix_spawnattr_set_4k_page_size_np` entry point, resolved at run time.
///
/// The function exists from macOS 26. The package supports macOS 15, so the symbol is looked up
/// instead of linked, and an older system reports that the request is unsupported rather than
/// failing to load or crashing. Tests substitute their own instance.
package struct FourKilobytePageSupport: Sendable {
  package let isAvailable: Bool
  private let applyToAttributes: @Sendable (UnsafeMutablePointer<posix_spawnattr_t?>) -> Int32

  package init(
    isAvailable: Bool,
    apply: @escaping @Sendable (UnsafeMutablePointer<posix_spawnattr_t?>) -> Int32
  ) {
    self.isAvailable = isAvailable
    self.applyToAttributes = apply
  }

  /// Sets the attribute; returns 0 or an errno value.
  package func apply(to attributes: UnsafeMutablePointer<posix_spawnattr_t?>) -> Int32 {
    isAvailable ? applyToAttributes(attributes) : ENOTSUP
  }

  /// The system's own implementation, or an unavailable stand-in before macOS 26.
  package static let system: FourKilobytePageSupport = {
    typealias Setter = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>) -> Int32
    if #available(macOS 26.0, *),
      let symbol = dlsym(
        UnsafeMutableRawPointer(bitPattern: -2), "posix_spawnattr_set_4k_page_size_np")
    {  // RTLD_DEFAULT
      let setter = unsafeBitCast(symbol, to: Setter.self)
      return FourKilobytePageSupport(isAvailable: true) { setter($0) }
    }
    return FourKilobytePageSupport(isAvailable: false) { _ in ENOTSUP }
  }()
}

/// A child started with `posix_spawn`; the caller must `wait()` for it or `terminate()` it.
package final class SpawnedProcess: Sendable {
  package let processIdentifier: pid_t
  package init(processIdentifier: pid_t) { self.processIdentifier = processIdentifier }

  /// Blocks until the child exits.
  /// - Returns: The exit status, or the signal number when the child was killed by a signal,
  ///   which is what `Process.terminationStatus` reports.
  package func wait() -> Int32 {
    var status: Int32 = 0
    while waitpid(processIdentifier, &status, 0) == -1 {
      if errno == EINTR { continue }
      return -1
    }
    let signal = status & 0x7f
    if signal == 0 { return (status >> 8) & 0xff }
    return signal
  }

  package func terminate() { kill(processIdentifier, SIGTERM) }
}

/// A shell-free child process invocation made with `posix_spawn`.
///
/// Mirrors `ProcessCommand` (same working directory, environment and output handling) and adds
/// spawn attributes. The environment is exactly the given one; nothing is inherited.
package struct SpawnCommand {
  package let executable: URL
  package let arguments: [String]
  package let directory: URL
  package let environment: [String: String]
  package let requestsFourKilobytePages: Bool
  private let support: FourKilobytePageSupport

  package init(
    executable: URL, arguments: [String], directory: URL, environment: [String: String],
    requestsFourKilobytePages: Bool = false,
    support: FourKilobytePageSupport = .system
  ) {
    self.executable = executable
    self.arguments = arguments
    self.directory = directory
    self.environment = environment
    self.requestsFourKilobytePages = requestsFourKilobytePages
    self.support = support
  }

  /// Starts the child and returns it still running.
  ///
  /// Standard input is `/dev/null`; standard output and error are `output`. No other descriptor
  /// is inherited. Throws before spawning when a 4 KiB page size is requested but unavailable.
  package func start(output: FileHandle) throws(LauncherError) -> SpawnedProcess {
    let name = executable.lastPathComponent
    if requestsFourKilobytePages && !support.isAvailable {
      throw .operation(
        "A 4 KiB page size is unsupported on this Mac (macOS 26 or later is required); "
          + "\(name) was not started.")
    }
    var attributes: posix_spawnattr_t? = nil
    var actions: posix_spawn_file_actions_t? = nil
    guard posix_spawnattr_init(&attributes) == 0 else {
      throw .operation("Could not prepare \(name).")
    }
    defer { posix_spawnattr_destroy(&attributes) }
    guard posix_spawn_file_actions_init(&actions) == 0 else {
      throw .operation("Could not prepare \(name).")
    }
    defer { posix_spawn_file_actions_destroy(&actions) }

    var defaults = sigset_t()
    var mask = sigset_t()
    sigfillset(&defaults)
    sigemptyset(&mask)
    posix_spawnattr_setsigdefault(&attributes, &defaults)
    posix_spawnattr_setsigmask(&attributes, &mask)
    let flags = POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT
    guard posix_spawnattr_setflags(&attributes, Int16(flags)) == 0 else {
      throw .operation("Could not prepare \(name).")
    }
    if requestsFourKilobytePages {
      let code = support.apply(to: &attributes)
      guard code == 0 else {
        throw .operation(
          "Could not request a 4 KiB page size for \(name): \(String(cString: strerror(code))).")
      }
    }
    // `FileHandle.nullDevice` has no descriptor of its own, so it is opened by path.
    let redirected =
      output.fileDescriptor >= 0
      ? [
        posix_spawn_file_actions_adddup2(&actions, output.fileDescriptor, 1),
        posix_spawn_file_actions_adddup2(&actions, output.fileDescriptor, 2),
      ]
      : [
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0),
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0),
      ]
    guard
      posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0) == 0,
      redirected.allSatisfy({ $0 == 0 }),
      posix_spawn_file_actions_addchdir_np(&actions, directory.path) == 0
    else { throw .operation("Could not prepare \(name).") }

    let argv = [executable.path] + arguments
    let envp = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    var pid: pid_t = 0
    let code = Self.withCStrings(argv) { argv in
      Self.withCStrings(envp) { envp in
        posix_spawn(&pid, executable.path, &actions, &attributes, argv, envp)
      }
    }
    guard code == 0 else {
      throw .operation("Could not start \(name): \(String(cString: strerror(code))).")
    }
    return SpawnedProcess(processIdentifier: pid)
  }

  /// Runs on a synchronous helper process, never on the launcher's UI or cooperative executor.
  /// - Returns: The child's actual exit status.
  package func run(output: FileHandle, onStart: (Int32) throws(LauncherError) -> Void = { _ in })
    throws(LauncherError) -> Int32
  {
    let process = try start(output: output)
    do { try onStart(process.processIdentifier) } catch {
      // Keep session ownership until the child exits even if its record could not be written.
      _ = process.wait()
      throw error
    }
    return process.wait()
  }

  private static func withCStrings<R>(
    _ strings: [String],
    _ body: ([UnsafeMutablePointer<CChar>?]) -> R
  ) -> R {
    var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    pointers.append(nil)
    defer { for pointer in pointers { free(pointer) } }
    return body(pointers)
  }
}

import Foundation

/// Creates an explicit environment without inheriting diagnostic or library injection settings.
package enum LaunchEnvironment {
  package static func make(paths: AppPaths, prefix: URL, home: URL, temporary: URL) -> [String:
    String]
  {
    [
      "HOME": home.path,
      "USER": home.lastPathComponent,
      "LOGNAME": home.lastPathComponent,
      "TMPDIR": temporary.path,
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
      "LANG": "en_US.UTF-8",
      "WINEPREFIX": prefix.path,
      "WINEDEBUG": "-all",
      "WINEDLLOVERRIDES": "dinput8=n,b;mscoree,mshtml=",
      "ROSETTA_X87_PATH": paths.sidecar.path,
      "WINEMSYNC": "1",
      "WINE_COMPATDB": "v=3\nname=nfsmw-bundle;exe=*;d3d9=mtld3d;dxgi=wined3d",
      "MTL_HUD_ENABLED": "0",
      "RUST_LOG": "warn,mtld3d::perf=off",
    ]
  }
}

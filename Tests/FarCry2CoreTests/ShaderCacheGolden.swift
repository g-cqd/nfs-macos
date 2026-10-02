import Foundation

/// Cache files written by the real `mtld3d_core::shader_cache` writers (mtld3d b22073b, container format 20,
/// shader schema 79) from invented fixed-function entries such as `vertex float4 f0(){return 0;}`.
/// They hold no game data. Chunk checksums are genuine xxh3 values, so these also pin `XXH3`.
enum ShaderCacheGolden {
  /// Three Single chunks; 229 bytes.
  static let singles =
    Data(
      base64Encoded:
        "TVRMRDNEU0gUAAAATwAAAAAAAAAAEAAAAAAAAC8AAAAdSLJ0fMnlCyi1L/0AWDEBAC2pxkJZaF/JAHZlcnRleCBm"
        + "bG9hdDQgZjAoKXtyZXR1cm4gMDt9AQAAAAEQAAAAAAAALwAAAH0+kUcVhal0KLUv/QBYMQEALanGQlloX8kAdmVy"
        + "dGV4IGZsb2F0NCBmMSgpe3JldHVybiAxO30AAAAAAhAAAAAAAAAvAAAAUhVK6jcN5ZwotS/9AFgxAQAtqcZCWWhf"
        + "yQB2ZXJ0ZXggZmxvYXQ0IGYyKCl7cmV0dXJuIDI7fQ=="
    ) ?? Data()

  /// One Bundle chunk of four records, one key shared with `singles`; 139 bytes.
  static let bundle =
    Data(
      base64Encoded:
        "TVRMRDNEU0gUAAAATwAAAP8AAAAAAAAAAAAAAGMAAAC6d303zXHkOCi1L/0AaNUCADQEAAIQACYAAAAtqcZCWWhf"
        + "yQB2ZXJ0ZXggZmxvYXQ0IGYyKCl7cmV0dXJuIDI7fQEAAAADMzM7fQAAAAAENDQFNTU7fQkgkDM9mxi5F7ObQPgw"
        + "u0w0wQFHCA=="
    ) ?? Data()

  /// A Bundle followed by two Singles; 287 bytes.
  static let mixed =
    Data(
      base64Encoded:
        "TVRMRDNEU0gUAAAATwAAAP8AAAAAAAAAAAAAAGUAAABAuOiDmGlUkSi1L/0AaOUCAFQEAAoQACgAAAAtqcZCWWhf"
        + "yQB2ZXJ0ZXggZmxvYXQ0IGYxMCgpe3JldHVybiAxMDt9AQAAAAsxMTt9AAAAAAwyMg0zMzt9CSCQMz2GHLkZs4ZI"
        + "+DGLm2yCA44QAAAAABQQAAAAAAAAMQAAAPmuZGXFweTDKLUv/QBYQQEALanGQlloX8kAdmVydGV4IGZsb2F0NCBm"
        + "MjAoKXtyZXR1cm4gMjA7fQEAAAAVEAAAAAAAADEAAAD5Be8tWxxuTSi1L/0AWEEBAC2pxkJZaF/JAHZlcnRleCBm"
        + "bG9hdDQgZjIxKCl7cmV0dXJuIDIxO30="
    ) ?? Data()

  /// Header only; 16 bytes.
  static let empty =
    Data(
      base64Encoded:
        "TVRMRDNEU0gUAAAATwAAAA=="
    ) ?? Data()

  /// `singles` with its last chunk cut inside the frame; 185 bytes.
  static let torn =
    Data(
      base64Encoded:
        "TVRMRDNEU0gUAAAATwAAAAAAAAAAEAAAAAAAAC8AAAAdSLJ0fMnlCyi1L/0AWDEBAC2pxkJZaF/JAHZlcnRleCBm"
        + "bG9hdDQgZjAoKXtyZXR1cm4gMDt9AQAAAAEQAAAAAAAALwAAAH0+kUcVhal0KLUv/QBYMQEALanGQlloX8kAdmVy"
        + "dGV4IGZsb2F0NCBmMSgpe3JldHVybiAxO30AAAAAAhAAAAAAAAAvAAAAUhVK6jcN5ZwotS8="
    ) ?? Data()

  /// Valid chunks under schema 78; 158 bytes.
  static let staleSchema =
    Data(
      base64Encoded:
        "TVRMRDNEU0gUAAAATgAAAAAAAAAAEAAAAAAAAC8AAAAdSLJ0fMnlCyi1L/0AWDEBAC2pxkJZaF/JAHZlcnRleCBm"
        + "bG9hdDQgZjAoKXtyZXR1cm4gMDt9AQAAAAEQAAAAAAAALwAAAH0+kUcVhal0KLUv/QBYMQEALanGQlloX8kAdmVy"
        + "dGV4IGZsb2F0NCBmMSgpe3JldHVybiAxO30="
    ) ?? Data()

  /// `singles` chunks then `bundle` chunks under one header; 352 bytes.
  static let concatChunks =
    Data(
      base64Encoded:
        "TVRMRDNEU0gUAAAATwAAAAAAAAAAEAAAAAAAAC8AAAAdSLJ0fMnlCyi1L/0AWDEBAC2pxkJZaF/JAHZlcnRleCBm"
        + "bG9hdDQgZjAoKXtyZXR1cm4gMDt9AQAAAAEQAAAAAAAALwAAAH0+kUcVhal0KLUv/QBYMQEALanGQlloX8kAdmVy"
        + "dGV4IGZsb2F0NCBmMSgpe3JldHVybiAxO30AAAAAAhAAAAAAAAAvAAAAUhVK6jcN5ZwotS/9AFgxAQAtqcZCWWhf"
        + "yQB2ZXJ0ZXggZmxvYXQ0IGYyKCl7cmV0dXJuIDI7ff8AAAAAAAAAAAAAAGMAAAC6d303zXHkOCi1L/0AaNUCADQE"
        + "AAIQACYAAAAtqcZCWWhfyQB2ZXJ0ZXggZmxvYXQ0IGYyKCl7cmV0dXJuIDI7fQEAAAADMzM7fQAAAAAENDQFNTU7"
        + "fQkgkDM9mxi5F7ObQPgwu0w0wQFHCA=="
    ) ?? Data()

  /// `singles` then the whole `bundle` file, leaving a second header mid-file; 368 bytes.
  static let concatWhole =
    Data(
      base64Encoded:
        "TVRMRDNEU0gUAAAATwAAAAAAAAAAEAAAAAAAAC8AAAAdSLJ0fMnlCyi1L/0AWDEBAC2pxkJZaF/JAHZlcnRleCBm"
        + "bG9hdDQgZjAoKXtyZXR1cm4gMDt9AQAAAAEQAAAAAAAALwAAAH0+kUcVhal0KLUv/QBYMQEALanGQlloX8kAdmVy"
        + "dGV4IGZsb2F0NCBmMSgpe3JldHVybiAxO30AAAAAAhAAAAAAAAAvAAAAUhVK6jcN5ZwotS/9AFgxAQAtqcZCWWhf"
        + "yQB2ZXJ0ZXggZmxvYXQ0IGYyKCl7cmV0dXJuIDI7fU1UTEQzRFNIFAAAAE8AAAD/AAAAAAAAAAAAAABjAAAAund9"
        + "N81x5DgotS/9AGjVAgA0BAACEAAmAAAALanGQlloX8kAdmVydGV4IGZsb2F0NCBmMigpe3JldHVybiAyO30BAAAA"
        + "AzMzO30AAAAABDQ0BTU1O30JIJAzPZsYuRezm0D4MLtMNMEBRwg="
    ) ?? Data()
}

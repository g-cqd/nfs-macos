import Foundation
import Testing

@testable import FarCry2Core

struct XXH3Tests {
  /// Input byte `i` is `(i * 131 + 17) & 0xff`; hashes come from `xxhash_rust::xxh3::xxh3_64`
  /// (0.8.19, the crate mtld3d checksums its cache chunks with). Every length class of the algorithm
  /// is covered: 0, 1-3, 4-8, 9-16, 17-128, 129-240, and the multi-block long path with its
  /// block, stripe and final-stripe boundaries.
  private static let vectors: [(length: Int, hash: UInt64)] = [
    (0, 0x2d06_8005_38d3_94c2),
    (1, 0xf319_fe2b_dfcd_febd),
    (2, 0x6c2c_a74c_a555_b69d),
    (3, 0xa107_bb65_b715_c89b),
    (4, 0x509f_0567_aa8a_3123),
    (5, 0x6e8b_b692_f318_05e8),
    (7, 0x7d56_f02b_162b_ee3c),
    (8, 0xb143_3dc3_9b7f_946e),
    (9, 0xfe25_4244_0b36_ddc7),
    (12, 0x7574_e41f_1948_c66e),
    (16, 0x7151_89ff_3dcd_cff6),
    (17, 0x7d33_163b_8af0_179c),
    (24, 0x6e89_277f_5efa_0932),
    (31, 0x91f3_e7dd_d073_abe6),
    (32, 0x909c_a0c7_65b1_753c),
    (33, 0x60f5_a6ac_1c8b_4a59),
    (48, 0x1ac6_3c0f_e49c_22b1),
    (64, 0x0991_d97c_d58d_d82d),
    (65, 0x8e4f_57a1_07b1_76db),
    (96, 0x8ada_f9d6_e4f4_721f),
    (97, 0xc1e9_58e8_5564_8d78),
    (100, 0xb940_6bca_5041_745d),
    (128, 0xee84_7f7f_cef4_ddbc),
    (129, 0x7e3e_7b75_0239_d4fc),
    (130, 0xabea_afe1_0757_1d84),
    (160, 0x0f2a_db08_915e_a24e),
    (200, 0xd571_57e6_be12_4c50),
    (239, 0x1d79_1534_5124_5f8c),
    (240, 0x4408_9a14_4aad_e02d),
    (241, 0xed93_572e_52ac_ac83),
    (255, 0xeced_e890_dd88_244b),
    (256, 0x5356_e487_4280_5b6a),
    (300, 0xf123_93c6_8094_5217),
    (301, 0x6692_0103_05bc_c329),
    (480, 0x1b4d_f3f5_c641_8cf0),
    (511, 0x11b9_8aa4_1f9c_aa6c),
    (512, 0xed6b_fa5c_6aa6_bf07),
    (513, 0x5857_e21e_aae7_b27e),
    (1000, 0x7dee_33ba_6091_4446),
    (1023, 0x90e9_c9b2_131a_cc97),
    (1024, 0xf0c5_763f_adfa_cd25),
    (1025, 0xd9b8_e93e_f3fb_e416),
    (1088, 0xfef3_2e3d_61ec_8a30),
    (1089, 0x716c_5edd_ec9a_d697),
    (2047, 0xbfa8_67f0_53a5_5871),
    (2048, 0xa5aa_5f57_cf12_9fab),
    (2049, 0xb6d0_a639_bd77_0002),
    (3000, 0xd2ff_8326_cc4d_0acb),
    (4096, 0xb6ea_5413_81e0_f6f9),
    (8192, 0x45c5_eab1_55d6_7bc1),
    (10000, 0x6475_5ca1_6aff_c818),
    (65536, 0x562e_723d_515f_e70e),
    (100000, 0xce2e_97cd_0b3b_0a41),
  ]

  private static func input(_ length: Int) -> [UInt8] {
    (0..<length).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ 17) }
  }

  @Test(arguments: vectors)
  func `matches the reference hash for the length`(length: Int, expected: UInt64) {
    #expect(XXH3.hash64(Self.input(length)) == expected, "length \(length)")
  }

  @Test
  func `the empty input has the published value`() {
    #expect(XXH3.hash64([]) == 0x2d06_8005_38d3_94c2)
  }

  @Test
  func `changing one byte changes the hash`() {
    var bytes = Self.input(5000)
    let original = XXH3.hash64(bytes)
    bytes[4999] ^= 1
    #expect(XXH3.hash64(bytes) != original)
  }
}

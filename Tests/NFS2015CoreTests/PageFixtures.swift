import Foundation
import Testing

@testable import NFS2015Core

/// Fixtures for the lines patch 0006 and patch 0007 add.
enum PageFixtures {
  /// Captured from the real runtime (`runtime/wine-0007`, 2026-10-08) running the patch's own fixture
  /// program `crash-context.exe page`, which writes through a non-canonical pointer: the fault line
  /// and the whole block, with the page, checksum, thread, return and code-window lines. A test
  /// program, not the game.
  static let realLines = """
    wine: Unhandled page fault on write access to 85BC35850173FF31 at address 000000014000166F (thread 00d4), starting debugger...
    wine-crash: begin pid=00d0 tid=00d4 code=c0000005 flags=00000000 address=000000014000166F
    wine-crash: access=1 target=85BC35850173FF31
    wine-crash: rip=000000014000166F rsp=000000000031FC60 rbp=0000000000000002 eflags=00000246 mxcsr=00001f80
    wine-crash: rax=1111111111111111 rbx=2222222222222222 rcx=85BC35850173FF31 rdx=3333333333333333
    wine-crash: rsi=4444444444444444 rdi=5555555555555555 r8=0808080808080808 r9=0909090909090909
    wine-crash: r10=1010101010101010 r11=1111000011110000 r12=1212121212121212 r13=1313131313131313
    wine-crash: r14=1414141414141414 r15=1515151515151515 cs=002b ss=0023 ds=0023 es=0023 fs=0000 gs=0023
    wine-crash: pc 000000014000166F state=1000 protect=20 type=1000000 region=0000000140001000+0000000000002000 module=crash-context.exe
    wine-crash: pc-bytes[16]=48 89 01 ff 15 28 6c 00 00 89 c2 48 8d 0d 90 29
    wine-crash: target 85BC35850173FF31 not queryable (non-canonical or outside the address space)
    wine-crash: stack[000000000031FC60]: 0000000000000000 0000000000000000 0000000000000000 0000000000000000 000000000031FCF0 0000000000000000 000000000003BB38 0000000000000000
    wine-crash: tf state=0 guest_flags=0 steps=0
    wine-crash: vq[0000000140001000] alloc=0000000140000000 aprot=80 base=0000000140001000 size=0000000000002000 state=1000 prot=20 type=1000000
    wine-crash: vq[0000000140000000] alloc=0000000140000000 aprot=80 base=0000000140000000 size=0000000000001000 state=1000 prot=2 type=1000000
    wine-crash: vq[0000000140002000] alloc=0000000140000000 aprot=80 base=0000000140002000 size=0000000000001000 state=1000 prot=20 type=1000000
    wine-crash: pagesum 0000000140001000 fnv1a64=061b710bc5e5a8e7 zero16=0/256
    wine-crash: threads=1 teb=000000007FFC0000
    wine-crash: ret[15]=00006FFFFFC1369A ntdll.dll+0x5369a
    wine-crash: ret[17]=00006FFFFFBDC718 ntdll.dll+0x1c718
    wine-crash: ret[23]=00006FFFFF9F0BE0 kernel32.dll+0x10be0
    wine-crash: ret[35]=00006FFFFFBDBF5C ntdll.dll+0x1bf5c
    wine-crash: ret[37]=00006FFFFFC0206C ntdll.dll+0x4206c
    wine-crash: ret[39]=00006FFFFEB3FFD9 ucrtbase.dll+0x6ffd9
    wine-crash: window pc=000000014000166F span=-100..+100
    wine-crash: code[0000000140001560]: 00 00 00 c7 44 24 28 00 00 00 00 c7 44 24 20 01 00 00 00 41 b9 00 00 00 00 41 b8 00 00 00 00 48
    wine-crash: code[0000000140001580]: 89 f2 b9 00 00 00 00 ff 15 f3 6c 00 00 85 c0 0f 84 dd 00 00 00 ba ff ff ff ff 48 8b 8c 24 80 01
    wine-crash: code[00000001400015A0]: 00 00 ff 15 38 6d 00 00 48 8d 54 24 5c 48 8b 8c 24 80 01 00 00 ff 15 dd 6c 00 00 8b 54 24 5c 48
    wine-crash: code[00000001400015C0]: 8d 0d 63 2a 00 00 e8 e5 13 00 00 b8 00 00 00 00 48 81 c4 10 02 00 00 5b 5e 5f 41 5c 41 5d 41 5e
    wine-crash: code[00000001400015E0]: 41 5f c3 48 b8 11 11 11 11 11 11 11 11 48 bb 22 22 22 22 22 22 22 22 48 ba 33 33 33 33 33 33 33
    wine-crash: code[0000000140001600]: 33 48 be 44 44 44 44 44 44 44 44 48 bf 55 55 55 55 55 55 55 55 49 b8 08 08 08 08 08 08 08 08 49
    wine-crash: code[0000000140001620]: b9 09 09 09 09 09 09 09 09 49 ba 10 10 10 10 10 10 10 10 49 bb 00 00 11 11 00 00 11 11 49 bc 12
    wine-crash: code[0000000140001640]: 12 12 12 12 12 12 12 49 bd 13 13 13 13 13 13 13 13 49 be 14 14 14 14 14 14 14 14 49 bf 15 15 15
    wine-crash: code[0000000140001660]: 15 15 15 15 15 48 b9 31 ff 73 01 85 35 bc 85 48 89 01 ff 15 28 6c 00 00 89 c2 48 8d 0d 90 29 00
    wine-crash: code[0000000140001680]: 00 e8 2a 13 00 00 b8 01 00 00 00 e9 40 ff ff ff 48 83 ec 28 48 8b 05 65 19 00 00 48 8b 00 48 85
    wine-crash: code[00000001400016A0]: c0 74 2a 66 90 66 66 2e 0f 1f 84 00 00 00 00 00 ff d0 48 8b 05 47 19 00 00 48 8d 50 08 48 8b 40
    wine-crash: code[00000001400016C0]: 08 48 89 15 38 19 00 00 48 85 c0 75 e3 48 83 c4 28 c3 0f 1f 00 66 66 2e 0f 1f 84 00 00 00 00 00
    wine-crash: code[00000001400016E0]: 56 53 48 83 ec 28 48 8b 15 13 2d 00 00 48 8b 02 89 c1 83 f8 ff 74 39 85 c9 74 20 89 c8 83 e9 01
    wine-crash: code[0000000140001700]: 48 8d 1c c2 48 29 c8 48 8d 74 c2 f8 0f 1f 40 00 ff 13 48 83 eb 08 48 39 f3 75 f5 48 8d 0d 6e ff
    wine-crash: code[0000000140001720]: ff ff 48 83 c4 28 5b 5e e9 33 fd ff ff 0f 1f 00 31 c0 0f 1f 00 66 66 2e 0f 1f 84 00 00 00 00 00
    wine-crash: code[0000000140001740]: 44 8d 40 01 89 c1 4c 89 c0 4a 83 3c c2 00 75 f0 eb a5 0f 1f 00 66 66 2e 0f 1f 84 00 00 00 00 00
    wine-crash: code[0000000140001760]: 8b 05 ca 58 00 00 85 c0 74 06 c3 0f 1f 44 00 00 c7 05 b6 58 00 00 01 00 00 00 e9 61 ff ff ff 90
    wine-crash: end
    """.split(separator: "\n").map(String.init)

  static var block: [String] { Array(realLines.dropFirst()) }

  /// Captured the same way from `exec-page-stale.exe trace` with `WINE_TRACE_PAGE=50000000-50010000`.
  static let traceLines = """
    wine-trace: window=50000000-50010000 pid=128
    wine-trace: op=alloc tid=12c addr=50000000 size=1000 prot=4 old=3000 status=0 ret=6fffff54555a
    wine-trace: op=write tid=12c addr=50000000 size=6 prot=0 old=0 status=0 ret=6fffff549cdf fnv=ffa3ae7f
    wine-trace: op=flush tid=12c addr=50000000 size=6 prot=0 old=0 status=0 ret=6fffff549cf9 fnv=ffa3ae7f
    wine-trace: op=protect tid=12c addr=50000000 size=1000 prot=20 old=4 status=0 ret=6fffff545d2a
    wine-trace: op=flush tid=12c addr=50000000 size=6 prot=0 old=0 status=0 ret=6fffff4f1d42 fnv=ffa3ae7f
    wine-trace: op=free tid=12c addr=50000000 size=0 prot=0 old=8000 status=0 ret=6fffff545af2
    wine-trace: op=map tid=12c addr=50000000 size=1000 prot=40 old=0 status=0 ret=6fffff50d248
    wine-trace: op=unmap tid=12c addr=50000000 size=1 prot=0 old=0 status=0 ret=6fffff53c2d9
    """.split(separator: "\n").map(String.init)

  /// Lines written from the format strings of patch 0006 for shapes the real capture does not
  /// show: registers near the instruction pointer, register windows, an unreadable range, a page
  /// that cannot be queried or read, and an unknown thread count. No runtime printed these.
  static let extraLines = [
    "wine-crash: vq[0000000001B31000] not queryable",
    "wine-crash: window r12=0000000001B300E3 span=-40..+40",
    "wine-crash: code[0000000001B300A0]: a2 31 ff 73 01 85 35 bc 85 e8 ac 52 48 8d 15 ba 00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f",
    "wine-crash: code[0000000001B300C0..0000000001B300FF]: unreadable",
    "wine-crash: near-pc: r12=pc-0x76 rbp=pc+0x10 rcx=pc+0",
  ]

  /// A block with every kind of line, for the report: the real 0006 block with a private RWX
  /// instruction-pointer page and the extra lines before `end`.
  static var richBlock: [String] {
    var lines = block.filter { $0 != "wine-crash: end" }.map { line -> String in
      line.hasPrefix("wine-crash: pc 0000")
        ? "wine-crash: pc 0000000001B30159 state=1000 protect=40 type=20000 region=0000000001B30000+0000000000001000 module=none"
        : line
    }
    lines += extraLines + ["wine-crash: end"]
    return lines
  }
}

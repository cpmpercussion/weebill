// weebill-cli — command line driver for the conformance harness.
//
//   weebill-cli dec <in.c2bits> <out.raw>
//   weebill-cli enc <in.raw> <out.c2bits>     (M3, not implemented yet)
//
// File conventions per vectors/README.md: raw audio is 16-bit signed
// little-endian PCM at 8 kHz, headerless; bitstreams are consecutive 8-byte
// 3200-mode frames (bitstream.md §5).

import Foundation
import Weebill

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("weebill-cli: " + message + "\n").utf8))
    exit(1)
}

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: weebill-cli dec <in.c2bits> <out.raw>
           weebill-cli enc <in.raw> <out.c2bits>

    dec  decode a 3200-mode bitstream (8 bytes per 20 ms frame) to
         headerless 16-bit signed little-endian PCM at 8 kHz.

    """.utf8))
    exit(2)
}

/// Decodes a whole bitstream file, frame by frame (bitstream.md §5:
/// consecutive 8-byte frames, no sync or header at this layer).
func decodeFile(input: String, output: String, seed: UInt64?) {
    guard let data = FileManager.default.contents(atPath: input) else {
        fail("cannot read \(input)")
    }
    let bytes = [UInt8](data)
    let frameBytes = Codec2_3200.frameBytes
    if bytes.count % frameBytes != 0 {
        FileHandle.standardError.write(Data(
            "weebill-cli: warning: \(input) is not a whole number of \(frameBytes)-byte frames; ignoring \(bytes.count % frameBytes) trailing byte(s)\n".utf8))
    }
    let frames = bytes.count / frameBytes

    let codec = seed.map { Codec2_3200(phaseSeed: $0) } ?? Codec2_3200()
    var pcm = [Int16]()
    pcm.reserveCapacity(frames * Codec2_3200.frameSamples)
    for n in 0..<frames {
        let start = n * frameBytes
        pcm.append(contentsOf: codec.decode(Array(bytes[start..<(start + frameBytes)])))
    }

    // 16-bit signed little-endian.
    var out = Data(capacity: pcm.count * 2)
    for sample in pcm {
        let u = UInt16(bitPattern: sample)
        out.append(UInt8(u & 0xff))
        out.append(UInt8(u >> 8))
    }
    do {
        try out.write(to: URL(fileURLWithPath: output))
    } catch {
        fail("cannot write \(output): \(error)")
    }
}

/// Encodes headerless 16-bit signed little-endian 8 kHz PCM to a 3200-mode
/// bitstream, 160 samples -> 8 bytes per frame (bitstream.md §1, §5).
/// A trailing partial frame is discarded.
func encodeFile(input: String, output: String) {
    guard let data = FileManager.default.contents(atPath: input) else {
        fail("cannot read \(input)")
    }
    var pcm = [Int16]()
    pcm.reserveCapacity(data.count / 2)
    for i in stride(from: 0, to: data.count - 1, by: 2) {
        pcm.append(Int16(bitPattern: UInt16(data[i]) | (UInt16(data[i + 1]) << 8)))
    }
    let n = Codec2_3200.frameSamples
    if pcm.count % n != 0 {
        FileHandle.standardError.write(Data(
            "weebill-cli: warning: \(input) is not a whole number of \(n)-sample frames; ignoring \(pcm.count % n) trailing sample(s)\n".utf8))
    }

    let codec = Codec2_3200()
    var out = Data(capacity: (pcm.count / n) * Codec2_3200.frameBytes)
    for f in 0..<(pcm.count / n) {
        out.append(contentsOf: codec.encode(Array(pcm[(f * n)..<((f + 1) * n)])))
    }
    do {
        try out.write(to: URL(fileURLWithPath: output))
    } catch {
        fail("cannot write \(output): \(error)")
    }
}

var args = CommandLine.arguments
// Optional --seed <n>: overrides the unvoiced-phase PRNG seed
// (algorithm.md §7.3, a decoder-side rendering choice).
var seed: UInt64? = nil
if let i = args.firstIndex(of: "--seed"), i + 1 < args.count {
    seed = UInt64(args[i + 1])
    args.removeSubrange(i...(i + 1))
}
guard args.count == 4 else { usage() }

switch args[1] {
case "dec":
    decodeFile(input: args[2], output: args[3], seed: seed)
case "enc":
    encodeFile(input: args[2], output: args[3])
default:
    usage()
}

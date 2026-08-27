// c2fuzz — the large out-of-band M4 runs (decode fuzz sweep + sustained
// real-time factor), reported rather than run on every `swift test`.
//
// Covers conformance.md D1c at scale and the brief's M4 performance goal
// ("sustained real-time factor well under 1.0").

import Foundation
import Weebill

// Unbuffered, so progress survives an abort mid-run.
setvbuf(stdout, nil, _IONBF, 0)

/// Left-pads to a fixed width. (Note: `%s` in `String(format:)` takes a C
/// string, not a Swift String — passing a Swift String there is undefined
/// behaviour, so all label formatting is done here instead.)
func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

let vectorDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "../codec2-3200-spec/vectors"

/// Deterministic PRNG (xorshift64), so the whole run is reproducible.
struct Rng {
    var state: UInt64
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
    mutating func frame() -> [UInt8] {
        (0..<8).map { _ in UInt8(next() & 0xff) }
    }
}

func readRaw(_ path: String) -> [Int16] {
    guard let d = FileManager.default.contents(atPath: path) else { return [] }
    var out = [Int16]()
    out.reserveCapacity(d.count / 2)
    for i in stride(from: 0, to: d.count - 1, by: 2) {
        out.append(Int16(bitPattern: UInt16(d[i]) | (UInt16(d[i + 1]) << 8)))
    }
    return out
}

func readBytes(_ path: String) -> [UInt8] {
    guard let d = FileManager.default.contents(atPath: path) else { return [] }
    return [UInt8](d)
}

// MARK: - Decode fuzz

func fuzzDecode() {
    print("=== decode fuzz (release) ===")
    var totalFrames = 0
    var railed = 0
    var nonFinite = 0
    var peak = 0

    func run(_ label: String, _ frames: [[UInt8]], fresh: Bool = false) {
        let shared = Codec2_3200()
        var localPeak = 0
        for f in frames {
            let codec = fresh ? Codec2_3200() : shared
            let pcm = codec.decode(f)
            precondition(pcm.count == 160, "\(label): wrong frame length")
            for v in pcm {
                precondition(v >= -32767 && v <= 32767, "\(label): out of int16 range")
                let a = abs(Int(v))
                localPeak = max(localPeak, a)
                if a >= 32767 { railed += 1 }
            }
            nonFinite += codec.nonFiniteSampleCount
            totalFrames += 1
        }
        peak = max(peak, localPeak)
        print("  \(pad(label, 34)) \(pad(String(frames.count), 8)) frames  peak \(localPeak)")
    }

    // 1. Uniform random frames.
    var rng = Rng(state: 0x1234_5678_9ABC_DEF0)
    run("uniform random", (0..<100_000).map { _ in rng.frame() })

    // 2. Every single-bit flip of every frame of a real speech bitstream.
    let speech = readBytes("\(vectorDir)/speech_arctic_bdl.c2bits")
    if !speech.isEmpty {
        var flips = [[UInt8]]()
        for frameIndex in 0..<(speech.count / 8) {
            let base = Array(speech[(frameIndex * 8)..<(frameIndex * 8 + 8)])
            for bit in 0..<64 {
                var m = base
                m[bit / 8] ^= UInt8(1 << (7 - (bit % 8)))
                flips.append(m)
            }
        }
        run("single-bit flips of bdl frames", flips)
    }

    // 3. Structured extremes, cycled and in isolation.
    var extremes: [[UInt8]] = [
        [UInt8](repeating: 0x00, count: 8),
        [UInt8](repeating: 0xff, count: 8),
        [UInt8](repeating: 0xaa, count: 8),
        [UInt8](repeating: 0x55, count: 8),
        [0xff, 0x00, 0xff, 0x00, 0xff, 0x00, 0xff, 0x00],
        [0x00, 0xff, 0x00, 0xff, 0x00, 0xff, 0x00, 0xff]
    ]
    for bit in 0..<64 {
        var b = [UInt8](repeating: 0, count: 8)
        b[bit / 8] = UInt8(1 << (7 - (bit % 8)))
        extremes.append(b)
        extremes.append(b.map { ~$0 })
    }
    var cycled = [[UInt8]]()
    for _ in 0..<200 { cycled.append(contentsOf: extremes) }
    run("structured extremes (cycled)", cycled)
    run("structured extremes (fresh codec)", extremes, fresh: true)

    // 4. Random frames each into a fresh decoder (first-frame paths).
    var rng2 = Rng(state: 0xDEAD_BEEF_CAFE_0001)
    run("random, fresh codec each frame", (0..<20_000).map { _ in rng2.frame() }, fresh: true)

    print("  ---")
    print("  total frames        : \(totalFrames)")
    print("  NaN/Inf samples     : \(nonFinite)")
    print("  samples at rail     : \(railed) of \(totalFrames * 160)")
    print("  overall peak        : \(peak)")
    precondition(nonFinite == 0, "decoder produced NaN/Inf")
}

// MARK: - Encode fuzz

func fuzzEncode() {
    print("\n=== encode robustness (release) ===")
    let cases: [(String, (Int) -> Int16)] = [
        ("silence", { _ in 0 }),
        ("+full scale DC", { _ in 32767 }),
        ("-full scale DC", { _ in -32767 }),
        ("int16 min DC", { _ in Int16.min }),
        ("clipped square 200 Hz", { n in (n / 20) % 2 == 0 ? 32767 : -32767 }),
        ("alternating rail", { n in n % 2 == 0 ? 32767 : -32767 }),
        ("impulse train 100 Hz", { n in n % 80 == 0 ? 32767 : 0 }),
        ("ramp sawtooth", { n in Int16(clamping: (n * 37) % 65536 - 32768) }),
        ("DC-offset sine", { n in Int16(clamping: 16000 + Int(8000.0 * sin(Double(n) * 0.05))) })
    ]
    for (name, gen) in cases {
        let encoder = Codec2_3200()
        let decoder = Codec2_3200()
        var peak = 0
        for f in 0..<500 {
            let pcm = (0..<160).map { gen(f * 160 + $0) }
            let frame = encoder.encode(pcm)
            precondition(frame.count == 8, "\(name): frame not 8 bytes")
            let out = decoder.decode(frame)
            precondition(out.count == 160)
            for v in out {
                precondition(v >= -32767 && v <= 32767, "\(name): out of range")
                peak = max(peak, abs(Int(v)))
            }
        }
        precondition(decoder.nonFiniteSampleCount == 0, "\(name): NaN/Inf")
        print("  \(pad(name, 24)) 500 frames ok, round-trip peak \(peak)")
    }

    // Random PCM.
    var rng = Rng(state: 0xFEED_FACE_0000_0001)
    let encoder = Codec2_3200()
    let decoder = Codec2_3200()
    for _ in 0..<2000 {
        let pcm = (0..<160).map { _ in Int16(bitPattern: UInt16(rng.next() & 0xffff)) }
        let frame = encoder.encode(pcm)
        precondition(frame.count == 8)
        _ = decoder.decode(frame)
    }
    precondition(decoder.nonFiniteSampleCount == 0)
    print("  random PCM               2000 frames ok")
}

// MARK: - Sustained real-time factor

func measureRTF() {
    print("\n=== sustained real-time factor (release) ===")
    let pcm = readRaw("\(vectorDir)/speech_arctic_bdl.raw")
    let bits = readBytes("\(vectorDir)/speech_arctic_bdl.c2bits")
    guard !pcm.isEmpty, !bits.isEmpty else {
        print("  vectors not found at \(vectorDir); skipping")
        return
    }

    // >= 60 s of audio = 3000 frames, looped over the vector.
    let frames = 5000                       // 100 s
    let audioSeconds = Double(frames) * 0.02

    let encoder = Codec2_3200()
    var encodeSink: UInt8 = 0
    let encodeStart = Date()
    for f in 0..<frames {
        let i = f % (pcm.count / 160)
        let out = encoder.encode(Array(pcm[(i * 160)..<(i * 160 + 160)]))
        encodeSink ^= out[0]
    }
    let encodeElapsed = Date().timeIntervalSince(encodeStart)

    let decoder = Codec2_3200()
    var decodeSink: Int16 = 0
    let decodeStart = Date()
    for f in 0..<frames {
        let i = f % (bits.count / 8)
        let out = decoder.decode(Array(bits[(i * 8)..<(i * 8 + 8)]))
        decodeSink ^= out[0]
    }
    let decodeElapsed = Date().timeIntervalSince(decodeStart)

    print(String(format: "  audio processed : %.1f s (%d frames) each way", audioSeconds, frames))
    print(String(format: "  encode          : %.3f s  -> RTF %.5f  (%.0fx real time)",
                 encodeElapsed, encodeElapsed / audioSeconds, audioSeconds / encodeElapsed))
    print(String(format: "  decode          : %.3f s  -> RTF %.5f  (%.0fx real time)",
                 decodeElapsed, decodeElapsed / audioSeconds, audioSeconds / decodeElapsed))
    print(String(format: "  encode+decode   : RTF %.5f",
                 (encodeElapsed + decodeElapsed) / audioSeconds))
    if encodeSink == 0xff && decodeSink == 1 { print("") }   // keep the work live
}

// MARK: - Memory growth

func measureMemory() {
    print("\n=== memory growth (release) ===")
    let pcm = readRaw("\(vectorDir)/speech_arctic_bdl.raw")
    let bits = readBytes("\(vectorDir)/speech_arctic_bdl.c2bits")
    guard !pcm.isEmpty, !bits.isEmpty else { print("  vectors not found; skipping"); return }

    func resident() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size
                                           / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return r == KERN_SUCCESS ? Int(info.resident_size) : 0
    }

    let codec = Codec2_3200()
    func work(_ n: Int) {
        for f in 0..<n {
            _ = codec.decode(Array(bits[((f % (bits.count / 8)) * 8)..<((f % (bits.count / 8)) * 8 + 8)]))
            let j = f % (pcm.count / 160)
            _ = codec.encode(Array(pcm[(j * 160)..<(j * 160 + 160)]))
        }
    }
    work(5_000)
    let before = resident()
    work(200_000)
    let after = resident()
    print(String(format: "  after warm-up   : %.2f MB", Double(before) / 1048576))
    print(String(format: "  after 200k more : %.2f MB", Double(after) / 1048576))
    print(String(format: "  growth          : %.3f MB", Double(after - before) / 1048576))
}

fuzzDecode()
fuzzEncode()
measureRTF()
measureMemory()
print("\nAll M4 checks passed.")

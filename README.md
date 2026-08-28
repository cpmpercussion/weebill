# Weebill

An independent speech codec in Swift, implementing the **Codec 2 3200
bit/s** bitstream format and interoperable with the reference codec. It
was written from specification only, as the clean side of a documented
clean-room process (see [NOTICE](NOTICE)). Weebill is not affiliated with
or endorsed by the Codec 2 project; "Codec 2" appears in this repository
only to identify the format it interoperates with. The package is named
for Australia's smallest bird.

Codec 2 3200 is a harmonic sinusoidal vocoder: 8 kHz mono 16-bit PCM in,
**64 bits per 20 ms frame** out — 160 samples become 8 bytes.

- No third-party dependencies. Swift standard library and Accelerate/vDSP
  only.
- Codebook tables are compiled in; nothing is read from disk at runtime.
- macOS 12+, iOS 15+, tvOS 15+, watchOS 8+.

### Why does this exist?

The codec2 3200bps encoding format is commonly used in amateur radio, particularly for communications using the M17 protocol, which can be used both on physical radio hardware and from computers over internet connections.
The codec2 source library is licensed under LGPL-2.1, which complicates its use in the Apple App Store and potentially other app stores.
Weebill is a pure-Swift codec written from an independent specification of the 3200bps mode, published separately at [codec2-3200-spec](https://github.com/cpmpercussion/codec2-3200-spec), and is interoperable with the codec2 3200bps format, enabling communication using the M17 voice protocol.
AI tools were used in the production of this library: one agent authored the specification with reference to the LGPL-licensed source, and a separate agent implemented Weebill from that specification alone.

The lead developer of codec2, David Rowe (VK5DGR), is aware and supportive of this project, while noting that neither he nor FreeDV claims or bears any responsibility for this library.
The project is aligned with the goals of codec2, an open voice codec unencumbered by commercial patents, and with the purpose of the amateur radio service itself, which the ITU defines as self-training, intercommunication, and technical investigations.

While this library has been primarily created to support my self-training, intercommunication, and technical investigations, others are welcome to use or improve it for their own projects.

--Charles (VK1CPM)

## Usage

```swift
import Weebill

let codec = Codec2_3200()

// 160 samples (20 ms @ 8 kHz) -> 8 bytes
let frame: [UInt8] = codec.encode(pcm)

// 8 bytes -> 160 samples
let samples: [Int16] = codec.decode(frame)
```

Both directions are **stateful**: the encoder keeps a 40 ms sliding
analysis buffer and pitch-tracker state, and the decoder keeps the previous
frame's model parameters plus a synthesis overlap buffer. Use **one
instance per stream**, feed it frames in order, and do not share an
instance across concurrent frames. `reset()` returns an instance to its
initial state so it can be reused for a new stream.

```swift
public final class Codec2_3200 {
    public init()
    public init(phaseSeed: UInt64)          // fixes the unvoiced-phase PRNG
    public func encode(_ pcm: [Int16]) -> [UInt8]   // exactly 160 samples in
    public func decode(_ frame: [UInt8]) -> [Int16] // exactly 8 bytes in
    public func reset()
    public static let frameBytes: Int       // 8
    public static let frameSamples: Int     // 160
}
```

Harmonic phases are not transmitted; the decoder synthesises them, and
unvoiced harmonics get random phases. Output is therefore not
waveform-identical between runs unless you pin `phaseSeed`, and never
waveform-identical to the input. Judge it by spectral distortion and by
ear, not by sample-wise comparison.

## Command line

```
swift build -c release

.build/release/weebill-cli enc <in.raw> <out.c2bits>
.build/release/weebill-cli dec <in.c2bits> <out.raw>   [--seed <n>]
```

`.raw` is headerless 16-bit signed little-endian PCM at 8 kHz mono;
`.c2bits` is consecutive 8-byte frames with no header, sync or padding.
A trailing partial frame is discarded with a warning on stderr.

## Lower-level API

The layers below the codec are public so the bitstream can be inspected
and the quantisers reused:

| Type | Purpose |
|---|---|
| `Codec2Frame` | the 64-bit frame's field indices; `packed()` / `unpack(_:)` |
| `grayEncode` / `grayDecode`, `BitWriter`, `BitReader` | Gray coding and MSB-first bit packing |
| `WoQuantiser`, `EnergyQuantiser`, `LSPDQuantiser` | the three quantiser laws |
| `Codec2Constants` | pitch range, energy range, LPC order, sample rate |
| `LPC`, `LSP` | autocorrelation, Levinson–Durbin, LPC↔LSP conversion |
| `DFT512` | 512-point DFT with the spec's exact scaling conventions |
| `Codec2Encoder`, `Codec2Decoder` | the two halves, usable independently |
| `dlspCodebooks`, `nlpFIR48` | the compiled-in interface tables |

All parameter indices in this API are **natural binary**. Gray coding is
applied only at the pack/unpack boundary — that is the format's most
common interoperability mistake.

## Tests

```
swift test
```

The suite covers the specification's known-answer vectors (quantiser laws,
Gray packing, a field-level dump of a real bitstream), the inverse-DFT
identity the synthesis stage depends on, decode and encode against the
reference test vectors, robustness fuzzing, and state-isolation checks.

## Regenerating the codebooks

```
Scripts/generate-codebooks.sh /path/to/codec2-3200-spec/codebooks
```

Rewrites `Sources/Weebill/Codebooks.swift` from the specification's CSV
tables. The generated file is checked in; there is no runtime file access.

## Licence

BSD 2-Clause; see [LICENSE](LICENSE). Read [NOTICE](NOTICE) for the
clean-room methodology, the AI-implementer disclosure, and the status of
the compiled-in interface tables.

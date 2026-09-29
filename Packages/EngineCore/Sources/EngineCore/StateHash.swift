// State hashing — a stable digest over authoritative state for the determinism contract (R-ENG-4.4;
// ADR 0002 decision 4/5).
//
// The determinism contract is: given the same hand seed(s) and the same ordered action log, replay
// produces an identical *final state hash* on every run and platform (ADR 0002 decision 5). The host
// stores one hash per applied action in the log (`LogEntry.resultingStateHash`, design.md §2.7), and
// `parlor-sim` and the save/restore round-trip assert equality across runs (R-QA-2.1, R-QA-4.1).
//
// Two properties make the hash trustworthy:
//
//   • a *canonical* encoding of the hashed value — deterministic key ordering and no wall-clock fields,
//     so nothing incidental (dictionary/`Set` iteration order, timestamps) can leak into the digest
//     (ADR 0002 decision 4; tech.md rule 8), and
//   • a *stable* digest algorithm — the ADR names SHA-256. It is implemented here in pure Swift over
//     `UInt32`/`UInt64` arithmetic rather than via CryptoKit, because EngineCore is the pure layer and
//     must stay Linux-portable for a future server (tech.md rule 1); a platform crypto framework would
//     tie the digest to Apple platforms. The result is byte-for-byte the standard SHA-256, so it is
//     stable and cross-platform.

import Foundation

// MARK: - StateHash

/// A stable 256-bit digest of authoritative game state (ADR 0002 decision 4).
///
/// Produced from the canonical `Codable` encoding of a value with deterministic key ordering and no
/// timestamps, so the same logical state always hashes identically across runs and platforms
/// (R-ENG-4.4). Stored per log entry (design.md §2.7) and compared for the determinism/replay and
/// save-round-trip checks (R-QA-2.1, R-QA-4.1). The `hex` string form is what a save file records.
public struct StateHash: Hashable, Codable, Sendable, CustomStringConvertible {
    /// The 32 raw digest bytes (SHA-256 output).
    public let bytes: [UInt8]

    /// Wrap raw digest bytes directly.
    public init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// Lowercase hex encoding of the digest, e.g. `"e3b0c442…"`. This is the stable string form recorded
    /// in the action log and save file (design.md §2.7).
    public var hex: String {
        var out = ""
        out.reserveCapacity(bytes.count * 2)
        for b in bytes {
            out.append(StateHash.hexDigits[Int(b >> 4)])
            out.append(StateHash.hexDigits[Int(b & 0x0F)])
        }
        return out
    }

    public var description: String { hex }

    private static let hexDigits: [Character] = Array("0123456789abcdef")
}

// MARK: - Codable (encode as hex string)

extension StateHash {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let hex = try container.decode(String.self)
        guard hex.count.isMultiple(of: 2) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "StateHash hex must have an even length")
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "StateHash contains non-hex characters")
            }
            bytes.append(byte)
            index = next
        }
        self.init(bytes: bytes)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

// MARK: - Hashing entry points

extension StateHash {
    /// Hash raw bytes with SHA-256 (ADR 0002 decision 4).
    public static func of(_ data: [UInt8]) -> StateHash {
        StateHash(bytes: SHA256.digest(data))
    }

    /// Hash `Data` with SHA-256.
    public static func of(_ data: Data) -> StateHash {
        StateHash(bytes: SHA256.digest([UInt8](data)))
    }

    /// Hash a value by first producing its *canonical* encoding, then SHA-256 (ADR 0002 decision 4/5).
    ///
    /// Canonical means the JSON encoding uses sorted keys and no wall-clock fields (the caller's type
    /// must already exclude timestamps — those live only in log metadata, tech.md rule 8), so equal
    /// logical states hash identically regardless of in-memory dictionary/`Set` ordering (R-ENG-4.4).
    public static func canonical<Value: Encodable>(_ value: Value) throws -> StateHash {
        let encoder = JSONEncoder()
        // Deterministic key ordering is the crux of the canonical encoding (ADR 0002 decision 4).
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return of(data)
    }
}

// MARK: - SHA-256 (pure Swift, Linux-portable)

/// A dependency-free SHA-256 implementation (FIPS 180-4). Pure `UInt32` arithmetic so the pure layer
/// stays Linux-portable (tech.md rule 1); the output is the standard SHA-256 digest, so hashes are
/// stable and identical on every platform (ADR 0002 decision 4).
enum SHA256 {
    /// The 64 round constants (first 32 bits of the fractional parts of the cube roots of the first 64
    /// primes) — the standard SHA-256 `K` table.
    private static let k: [UInt32] = [
        0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5, 0x3956_c25b, 0x59f1_11f1, 0x923f_82a4,
        0xab1c_5ed5, 0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3, 0x72be_5d74, 0x80de_b1fe,
        0x9bdc_06a7, 0xc19b_f174, 0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc, 0x2de9_2c6f,
        0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da, 0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7,
        0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967, 0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc,
        0x5338_0d13, 0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85, 0xa2bf_e8a1, 0xa81a_664b,
        0xc24b_8b70, 0xc76c_51a3, 0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070, 0x19a4_c116,
        0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5, 0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3,
        0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208, 0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7,
        0xc671_78f2,
    ]

    /// Right-rotate a 32-bit word by `n` bits.
    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x >> n) | (x << (32 - n))
    }

    /// Compute the 32-byte SHA-256 digest of `message`.
    static func digest(_ message: [UInt8]) -> [UInt8] {
        // Initial hash values: first 32 bits of the fractional parts of the square roots of the first
        // eight primes.
        var h0: UInt32 = 0x6a09_e667
        var h1: UInt32 = 0xbb67_ae85
        var h2: UInt32 = 0x3c6e_f372
        var h3: UInt32 = 0xa54f_f53a
        var h4: UInt32 = 0x510e_527f
        var h5: UInt32 = 0x9b05_688c
        var h6: UInt32 = 0x1f83_d9ab
        var h7: UInt32 = 0x5be0_cd19

        // Pre-processing: append 0x80, then zero pad to 56 mod 64, then the 64-bit big-endian bit length.
        var padded = message
        let bitLength = UInt64(message.count) &* 8
        padded.append(0x80)
        while padded.count % 64 != 56 {
            padded.append(0)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            padded.append(UInt8((bitLength >> UInt64(shift)) & 0xFF))
        }

        // Process each 64-byte block.
        var w = [UInt32](repeating: 0, count: 64)
        var blockStart = 0
        while blockStart < padded.count {
            for t in 0..<16 {
                let i = blockStart + t * 4
                w[t] =
                    (UInt32(padded[i]) << 24)
                    | (UInt32(padded[i + 1]) << 16)
                    | (UInt32(padded[i + 2]) << 8)
                    | UInt32(padded[i + 3])
            }
            for t in 16..<64 {
                let s0 = rotr(w[t - 15], 7) ^ rotr(w[t - 15], 18) ^ (w[t - 15] >> 3)
                let s1 = rotr(w[t - 2], 17) ^ rotr(w[t - 2], 19) ^ (w[t - 2] >> 10)
                w[t] = w[t - 16] &+ s0 &+ w[t - 7] &+ s1
            }

            var a = h0
            var b = h1
            var c = h2
            var d = h3
            var e = h4
            var f = h5
            var g = h6
            var h = h7

            for t in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let temp1 = h &+ s1 &+ ch &+ k[t] &+ w[t]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ maj

                h = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ temp2
            }

            h0 = h0 &+ a
            h1 = h1 &+ b
            h2 = h2 &+ c
            h3 = h3 &+ d
            h4 = h4 &+ e
            h5 = h5 &+ f
            h6 = h6 &+ g
            h7 = h7 &+ h

            blockStart += 64
        }

        var out: [UInt8] = []
        out.reserveCapacity(32)
        for word in [h0, h1, h2, h3, h4, h5, h6, h7] {
            out.append(UInt8((word >> 24) & 0xFF))
            out.append(UInt8((word >> 16) & 0xFF))
            out.append(UInt8((word >> 8) & 0xFF))
            out.append(UInt8(word & 0xFF))
        }
        return out
    }
}

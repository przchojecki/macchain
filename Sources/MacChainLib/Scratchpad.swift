import Foundation
import CryptoKit
import CommonCrypto

/// AES-based scratchpad for MacChain edge generation.
/// Fills a buffer by chaining AES-128 ECB encryptions using hardware AES on Apple Silicon.
public final class Scratchpad {
    public let size: Int
    public private(set) var buffer: UnsafeMutableRawPointer
    private let blockCount: Int

    public init(size: Int = MacChainParams.default.scratchpadSize) {
        self.size = size
        self.blockCount = size / 16
        self.buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
    }

    deinit {
        buffer.deallocate()
    }

    /// Fill the scratchpad using chained AES-128 encryption.
    /// Derives AES key and IV from SHA-256(blockHeader || nonce).
    public func fill(blockHeader: Data, nonce: UInt64) {
        // Compute header hash
        var input = blockHeader
        withUnsafeBytes(of: nonce.littleEndian) { input.append(contentsOf: $0) }
        let headerHash = Data(SHA256.hash(data: input))

        let aesKey = Array(headerHash[0..<16])
        var state = Array(headerHash[16..<32])

        // Chain AES-128 ECB encryptions to fill scratchpad
        var outLen: Int = 0
        for i in 0..<blockCount {
            // AES-128 ECB encrypt: state = AES_ENC(state, aesKey)
            var encrypted = [UInt8](repeating: 0, count: 16 + kCCBlockSizeAES128)
            outLen = 0
            CCCrypt(
                CCOperation(kCCEncrypt),
                CCAlgorithm(kCCAlgorithmAES),
                CCOptions(kCCOptionECBMode),
                aesKey, 16,
                nil,
                state, 16,
                &encrypted, encrypted.count,
                &outLen
            )
            state = Array(encrypted[0..<16])
            buffer.advanced(by: i * 16).copyMemory(from: &state, byteCount: 16)
        }
    }

    /// Read 16 bytes from the scratchpad at a given byte offset.
    @inline(__always)
    public func read16(at byteOffset: Int) -> SIMD2<UInt64> {
        let ptr = buffer.advanced(by: byteOffset).assumingMemoryBound(to: UInt64.self)
        return SIMD2(ptr[0], ptr[1])
    }

    /// Write 16 bytes to the scratchpad at a given byte offset.
    @inline(__always)
    public func write16(at byteOffset: Int, value: UnsafeRawPointer) {
        buffer.advanced(by: byteOffset).copyMemory(from: value, byteCount: 16)
    }

    /// Read a chunk of bytes from the scratchpad.
    public func readBytes(at offset: Int, count: Int) -> UnsafeRawBufferPointer {
        UnsafeRawBufferPointer(start: buffer.advanced(by: offset), count: count)
    }
}

// MARK: - AES single-block encrypt helper

/// AES-128 ECB encrypt a single 16-byte block. Uses CommonCrypto which
/// dispatches to hardware AES on ARM.
@inline(__always)
public func aesEncryptBlock(_ plaintext: inout [UInt8], key: [UInt8]) -> [UInt8] {
    var encrypted = [UInt8](repeating: 0, count: 32)
    var outLen = 0
    CCCrypt(
        CCOperation(kCCEncrypt),
        CCAlgorithm(kCCAlgorithmAES),
        CCOptions(kCCOptionECBMode),
        key, 16,
        nil,
        plaintext, 16,
        &encrypted, 32,
        &outLen
    )
    return Array(encrypted[0..<16])
}

import Foundation

// MARK: - Default Graph Parameters

public struct MacChainParams {
    public var scratchpadSize: Int
    public var numEdges: Int
    public var numNodes: Int
    public var nodeMask: UInt32
    public var matrixDim: Int
    public var trimRounds: Int

    public init(
        scratchpadSize: Int,
        numEdges: Int,
        numNodes: Int,
        nodeMask: UInt32,
        matrixDim: Int,
        trimRounds: Int
    ) {
        self.scratchpadSize = scratchpadSize
        self.numEdges = numEdges
        self.numNodes = numNodes
        self.nodeMask = nodeMask
        self.matrixDim = matrixDim
        self.trimRounds = trimRounds
    }

    public static let `default` = MacChainParams(
        scratchpadSize: 16_777_216,     // 16 MB
        numEdges: 1 << 24,              // 16,777,216
        numNodes: 1 << 23,              // 8,388,608 per partition
        nodeMask: 0x7F_FFFF,            // 23-bit mask
        matrixDim: 16,                  // 16x16 float32
        trimRounds: 80
    )

    public var scratchpadBlocks: Int {
        scratchpadSize / 16
    }
}

// MARK: - Cycle Length

public let kCycleLength = 8

// MARK: - Difficulty Constants

public let kBlocksPerAdjustment: UInt64 = 2016
public let kTargetBlockTimeSeconds: Double = 600.0 // 10 minutes
public let kBlocksPerEpoch: UInt64 = 4096

// MARK: - Edge

public struct Edge: Equatable, Hashable {
    public let u: UInt32
    public let v: UInt32

    public init(u: UInt32, v: UInt32) {
        self.u = u
        self.v = v
    }
}

// MARK: - Block Header

public struct BlockHeader {
    public var prevHash: Data    // 32 bytes
    public var merkleRoot: Data  // 32 bytes
    public var timestamp: UInt32
    public var bits: UInt32      // compact difficulty target
    public var version: UInt32

    public init(
        prevHash: Data = Data(repeating: 0, count: 32),
        merkleRoot: Data = Data(repeating: 0, count: 32),
        timestamp: UInt32 = 0,
        bits: UInt32 = 0x1f_00ffff,
        version: UInt32 = 1
    ) {
        self.prevHash = prevHash
        self.merkleRoot = merkleRoot
        self.timestamp = timestamp
        self.bits = bits
        self.version = version
    }

    public func serialized() -> Data {
        var data = Data(capacity: 80)
        data.append(withUnsafeBytes(of: version.littleEndian) { Data($0) })
        data.append(prevHash.prefix(32))
        if prevHash.count < 32 {
            data.append(Data(repeating: 0, count: 32 - prevHash.count))
        }
        data.append(merkleRoot.prefix(32))
        if merkleRoot.count < 32 {
            data.append(Data(repeating: 0, count: 32 - merkleRoot.count))
        }
        data.append(withUnsafeBytes(of: timestamp.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: bits.littleEndian) { Data($0) })
        // Pad to 80 bytes
        if data.count < 80 {
            data.append(Data(repeating: 0, count: 80 - data.count))
        }
        return data.prefix(80)
    }
}

// MARK: - Mining Result

public enum MiningResult {
    case found(MacChainProof)
    case notFound
    case cancelled
}

// MARK: - Proof

public struct MacChainProof: Equatable {
    public let blockHeader: Data       // 80 bytes serialized
    public let nonce: UInt64
    public let cycleEdges: [UInt32]    // 8 edge indices

    public init(blockHeader: Data, nonce: UInt64, cycleEdges: [UInt32]) {
        self.blockHeader = blockHeader
        self.nonce = nonce
        self.cycleEdges = cycleEdges
    }

    public func serialized() -> Data {
        var data = Data(capacity: 124)
        data.append(blockHeader.prefix(80))
        if blockHeader.count < 80 {
            data.append(Data(repeating: 0, count: 80 - blockHeader.count))
        }
        data.append(withUnsafeBytes(of: nonce.littleEndian) { Data($0) })
        for edge in cycleEdges.prefix(kCycleLength) {
            data.append(withUnsafeBytes(of: edge.littleEndian) { Data($0) })
        }
        return data
    }

    public static func deserialize(from data: Data) -> MacChainProof? {
        guard data.count >= 120 else { return nil } // 80 + 8 + 32
        let header = data[0..<80]
        let nonce = data[80..<88].withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
        var edges: [UInt32] = []
        for i in 0..<kCycleLength {
            let offset = 88 + i * 4
            guard offset + 4 <= data.count else { return nil }
            let edge = data[offset..<(offset + 4)].withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
            edges.append(edge)
        }
        return MacChainProof(blockHeader: Data(header), nonce: nonce, cycleEdges: edges)
    }
}

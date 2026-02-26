import Foundation
import CommonCrypto

/// Phase 1: Edge generation using AES + AMX dependent computation chain.
/// Each edge depends on the previous state, preventing parallelization.
public final class EdgeGenerator {
    public let params: MacChainParams
    public let scratchpad: Scratchpad

    public init(params: MacChainParams = .default) {
        self.params = params
        self.scratchpad = Scratchpad(size: params.scratchpadSize)
    }

    /// Generate all edges for a given block header and nonce.
    /// Returns array of Edge structs and stores raw (u,v) pairs in the provided buffer if non-nil.
    public func generateEdges(
        blockHeader: Data,
        nonce: UInt64,
        edgeBuffer: UnsafeMutablePointer<UInt32>? = nil
    ) -> [Edge] {
        // Step 1: Fill scratchpad via AES chain
        scratchpad.fill(blockHeader: blockHeader, nonce: nonce)

        // Initial state = last 16 bytes written to scratchpad
        let lastBlockOffset = (params.scratchpadBlocks - 1) * 16
        var state = [UInt8](repeating: 0, count: 16)
        scratchpad.buffer.advanced(by: lastBlockOffset).copyBytes(to: &state, count: 16)

        let dim = params.matrixDim
        let matElements = dim * dim
        let matBytes = matElements * MemoryLayout<Float>.size  // bytes for one matrix
        let maxIdx = params.scratchpadSize - matBytes * 2       // room for two matrices

        var edges = [Edge]()
        edges.reserveCapacity(params.numEdges)

        // Preallocate matrix buffers
        let matA = UnsafeMutablePointer<Float>.allocate(capacity: matElements)
        let matB = UnsafeMutablePointer<Float>.allocate(capacity: matElements)
        let matC = UnsafeMutablePointer<Float>.allocate(capacity: matElements)
        defer {
            matA.deallocate()
            matB.deallocate()
            matC.deallocate()
        }

        var aesKey = state  // key evolves with state

        for e in 0..<params.numEdges {
            // 1. Compute scratchpad offset from current state
            let stateU32 = state.withUnsafeBytes { $0.load(as: UInt32.self) }
            let idx = Int(stateU32 % UInt32(maxIdx))
            // Align to 4-byte boundary for float reads
            let alignedIdx = idx & ~3

            // 2. Load two matrices from scratchpad
            let ptrA = scratchpad.buffer.advanced(by: alignedIdx)
            let ptrB = scratchpad.buffer.advanced(by: alignedIdx + matBytes)
            matA.initialize(from: ptrA.assumingMemoryBound(to: Float.self), count: matElements)
            matB.initialize(from: ptrB.assumingMemoryBound(to: Float.self), count: matElements)

            // 3. Matrix multiply via AMX
            AMXBridge.matmul(a: matA, b: matB, c: matC, dim: dim)

            // 4. XOR-fold matrix C into 128 bits
            var folded = AMXBridge.xorFoldMatrix(matC, dim: dim)

            // 5. Mix with AES: state = AES_ENC(folded, state)
            state = aesEncryptBlock(&folded, key: state)

            // 6. Write back to scratchpad (creates dependency chain)
            scratchpad.buffer.advanced(by: alignedIdx).copyMemory(from: &state, byteCount: 16)

            // 7. Extract edge endpoints
            let u = state.withUnsafeBytes {
                $0.load(fromByteOffset: 0, as: UInt32.self)
            } & params.nodeMask

            let v = state.withUnsafeBytes {
                $0.load(fromByteOffset: 4, as: UInt32.self)
            } & params.nodeMask

            edges.append(Edge(u: u, v: v))

            // Write to edge buffer for GPU if provided
            if let buf = edgeBuffer {
                buf[e * 2] = u
                buf[e * 2 + 1] = v
            }

            // Update key for next iteration
            aesKey = state
        }

        return edges
    }

    /// Generate a single edge at a given index by replaying the chain.
    /// Used for verification — must compute all edges 0..<index to get the state.
    public func generateSingleEdge(
        blockHeader: Data,
        nonce: UInt64,
        edgeIndex: Int
    ) -> Edge {
        scratchpad.fill(blockHeader: blockHeader, nonce: nonce)

        let lastBlockOffset = (params.scratchpadBlocks - 1) * 16
        var state = [UInt8](repeating: 0, count: 16)
        scratchpad.buffer.advanced(by: lastBlockOffset).copyBytes(to: &state, count: 16)

        let dim = params.matrixDim
        let matElements = dim * dim
        let matBytes = matElements * MemoryLayout<Float>.size
        let maxIdx = params.scratchpadSize - matBytes * 2

        let matA = UnsafeMutablePointer<Float>.allocate(capacity: matElements)
        let matB = UnsafeMutablePointer<Float>.allocate(capacity: matElements)
        let matC = UnsafeMutablePointer<Float>.allocate(capacity: matElements)
        defer {
            matA.deallocate()
            matB.deallocate()
            matC.deallocate()
        }

        for e in 0...edgeIndex {
            let stateU32 = state.withUnsafeBytes { $0.load(as: UInt32.self) }
            let idx = Int(stateU32 % UInt32(maxIdx))
            let alignedIdx = idx & ~3

            let ptrA = scratchpad.buffer.advanced(by: alignedIdx)
            let ptrB = scratchpad.buffer.advanced(by: alignedIdx + matBytes)
            matA.initialize(from: ptrA.assumingMemoryBound(to: Float.self), count: matElements)
            matB.initialize(from: ptrB.assumingMemoryBound(to: Float.self), count: matElements)

            AMXBridge.matmul(a: matA, b: matB, c: matC, dim: dim)
            var folded = AMXBridge.xorFoldMatrix(matC, dim: dim)
            state = aesEncryptBlock(&folded, key: state)
            scratchpad.buffer.advanced(by: alignedIdx).copyMemory(from: &state, byteCount: 16)
        }

        let u = state.withUnsafeBytes {
            $0.load(fromByteOffset: 0, as: UInt32.self)
        } & params.nodeMask

        let v = state.withUnsafeBytes {
            $0.load(fromByteOffset: 4, as: UInt32.self)
        } & params.nodeMask

        return Edge(u: u, v: v)
    }

    /// Batch-generate specific edges by replaying the full chain once
    /// and collecting only the requested indices. More efficient than
    /// calling generateSingleEdge repeatedly.
    public func generateEdges(
        blockHeader: Data,
        nonce: UInt64,
        atIndices indices: [Int]
    ) -> [Int: Edge] {
        let maxIndex = indices.max() ?? 0
        let indexSet = Set(indices)

        scratchpad.fill(blockHeader: blockHeader, nonce: nonce)

        let lastBlockOffset = (params.scratchpadBlocks - 1) * 16
        var state = [UInt8](repeating: 0, count: 16)
        scratchpad.buffer.advanced(by: lastBlockOffset).copyBytes(to: &state, count: 16)

        let dim = params.matrixDim
        let matElements = dim * dim
        let matBytes = matElements * MemoryLayout<Float>.size
        let maxIdx = params.scratchpadSize - matBytes * 2

        let matA = UnsafeMutablePointer<Float>.allocate(capacity: matElements)
        let matB = UnsafeMutablePointer<Float>.allocate(capacity: matElements)
        let matC = UnsafeMutablePointer<Float>.allocate(capacity: matElements)
        defer {
            matA.deallocate()
            matB.deallocate()
            matC.deallocate()
        }

        var result = [Int: Edge]()

        for e in 0...maxIndex {
            let stateU32 = state.withUnsafeBytes { $0.load(as: UInt32.self) }
            let idx = Int(stateU32 % UInt32(maxIdx))
            let alignedIdx = idx & ~3

            let ptrA = scratchpad.buffer.advanced(by: alignedIdx)
            let ptrB = scratchpad.buffer.advanced(by: alignedIdx + matBytes)
            matA.initialize(from: ptrA.assumingMemoryBound(to: Float.self), count: matElements)
            matB.initialize(from: ptrB.assumingMemoryBound(to: Float.self), count: matElements)

            AMXBridge.matmul(a: matA, b: matB, c: matC, dim: dim)
            var folded = AMXBridge.xorFoldMatrix(matC, dim: dim)
            state = aesEncryptBlock(&folded, key: state)
            scratchpad.buffer.advanced(by: alignedIdx).copyMemory(from: &state, byteCount: 16)

            if indexSet.contains(e) {
                let u = state.withUnsafeBytes {
                    $0.load(fromByteOffset: 0, as: UInt32.self)
                } & params.nodeMask

                let v = state.withUnsafeBytes {
                    $0.load(fromByteOffset: 4, as: UInt32.self)
                } & params.nodeMask

                result[e] = Edge(u: u, v: v)
            }
        }

        return result
    }
}

// MARK: - UnsafeMutableRawPointer helper

private extension UnsafeMutableRawPointer {
    func copyBytes(to destination: inout [UInt8], count: Int) {
        destination.withUnsafeMutableBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: UInt8.self, capacity: count) { dest in
                self.copyMemory(from: self, byteCount: 0) // no-op, just for type
            }
        }
        // Direct copy
        for i in 0..<count {
            destination[i] = self.load(fromByteOffset: i, as: UInt8.self)
        }
    }
}

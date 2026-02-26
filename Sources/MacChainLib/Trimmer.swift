import Foundation
import Metal

/// Phase 2: GPU-based edge trimming using Metal compute shaders.
/// Iteratively removes degree-1 nodes from the bipartite graph.
public final class Trimmer {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let degreeCountPipeline: MTLComputePipelineState
    private let trimUPipeline: MTLComputePipelineState
    private let trimVPipeline: MTLComputePipelineState
    private let params: MacChainParams

    public init(params: MacChainParams = .default) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw TrimmerError.noMetalDevice
        }
        self.device = device

        guard let queue = device.makeCommandQueue() else {
            throw TrimmerError.noCommandQueue
        }
        self.commandQueue = queue
        self.params = params

        // Compile Metal shaders from source
        let library = try Trimmer.loadShaderLibrary(device: device)

        guard let degreeCountFn = library.makeFunction(name: "degree_count"),
              let trimUFn = library.makeFunction(name: "trim_u"),
              let trimVFn = library.makeFunction(name: "trim_v") else {
            throw TrimmerError.functionNotFound
        }

        self.degreeCountPipeline = try device.makeComputePipelineState(function: degreeCountFn)
        self.trimUPipeline = try device.makeComputePipelineState(function: trimUFn)
        self.trimVPipeline = try device.makeComputePipelineState(function: trimVFn)
    }

    /// Run edge trimming on the provided edges.
    /// Returns indices of surviving edges.
    public func trim(edges: [Edge]) throws -> [Int] {
        let numEdges = edges.count

        // Allocate shared buffers (CPU + GPU zero-copy via UMA)
        let edgePairSize = numEdges * 2 * MemoryLayout<UInt32>.size
        let bitmapWords = (numEdges + 31) / 32
        let bitmapSize = bitmapWords * MemoryLayout<UInt32>.size
        let degreeSize = params.numNodes * MemoryLayout<UInt32>.size

        guard let edgePairBuf = device.makeBuffer(length: edgePairSize, options: .storageModeShared),
              let bitmapBuf = device.makeBuffer(length: bitmapSize, options: .storageModeShared),
              let degreeUBuf = device.makeBuffer(length: degreeSize, options: .storageModeShared),
              let degreeVBuf = device.makeBuffer(length: degreeSize, options: .storageModeShared) else {
            throw TrimmerError.bufferAllocationFailed
        }

        // Fill edge pairs buffer
        let edgePtr = edgePairBuf.contents().assumingMemoryBound(to: UInt32.self)
        for (i, edge) in edges.enumerated() {
            edgePtr[i * 2] = edge.u
            edgePtr[i * 2 + 1] = edge.v
        }

        // Initialize bitmap: all edges alive (all bits set)
        let bitmapPtr = bitmapBuf.contents().assumingMemoryBound(to: UInt32.self)
        for i in 0..<bitmapWords {
            bitmapPtr[i] = 0xFFFF_FFFF
        }
        // Clear trailing bits in last word
        let trailingBits = numEdges % 32
        if trailingBits > 0 {
            bitmapPtr[bitmapWords - 1] = (1 << trailingBits) - 1
        }

        // Zero degree arrays
        memset(degreeUBuf.contents(), 0, degreeSize)
        memset(degreeVBuf.contents(), 0, degreeSize)

        // Phase 2a: Count initial degrees
        try dispatchDegreeCount(
            edgePairBuf: edgePairBuf,
            degreeUBuf: degreeUBuf,
            degreeVBuf: degreeVBuf,
            numEdges: numEdges
        )

        // Phase 2b: Iterative trimming
        for _ in 0..<params.trimRounds {
            try dispatchTrim(
                pipeline: trimUPipeline,
                edgePairBuf: edgePairBuf,
                degreeUBuf: degreeUBuf,
                degreeVBuf: degreeVBuf,
                bitmapBuf: bitmapBuf,
                numEdges: numEdges
            )
            try dispatchTrim(
                pipeline: trimVPipeline,
                edgePairBuf: edgePairBuf,
                degreeUBuf: degreeUBuf,
                degreeVBuf: degreeVBuf,
                bitmapBuf: bitmapBuf,
                numEdges: numEdges
            )
        }

        // Collect surviving edge indices
        let finalBitmap = bitmapBuf.contents().assumingMemoryBound(to: UInt32.self)
        var surviving = [Int]()
        surviving.reserveCapacity(numEdges / 100) // ~1% survive
        for i in 0..<numEdges {
            let word = finalBitmap[i / 32]
            let bit = UInt32(1) << (i % 32)
            if word & bit != 0 {
                surviving.append(i)
            }
        }

        return surviving
    }

    /// Trim using a pre-filled MTLBuffer of edge pairs (for zero-copy from edge gen).
    public func trim(edgePairBuffer: MTLBuffer, numEdges: Int) throws -> [Int] {
        let bitmapWords = (numEdges + 31) / 32
        let bitmapSize = bitmapWords * MemoryLayout<UInt32>.size
        let degreeSize = params.numNodes * MemoryLayout<UInt32>.size

        guard let bitmapBuf = device.makeBuffer(length: bitmapSize, options: .storageModeShared),
              let degreeUBuf = device.makeBuffer(length: degreeSize, options: .storageModeShared),
              let degreeVBuf = device.makeBuffer(length: degreeSize, options: .storageModeShared) else {
            throw TrimmerError.bufferAllocationFailed
        }

        // Initialize bitmap
        let bitmapPtr = bitmapBuf.contents().assumingMemoryBound(to: UInt32.self)
        for i in 0..<bitmapWords {
            bitmapPtr[i] = 0xFFFF_FFFF
        }
        let trailingBits = numEdges % 32
        if trailingBits > 0 {
            bitmapPtr[bitmapWords - 1] = (1 << trailingBits) - 1
        }

        memset(degreeUBuf.contents(), 0, degreeSize)
        memset(degreeVBuf.contents(), 0, degreeSize)

        try dispatchDegreeCount(
            edgePairBuf: edgePairBuffer,
            degreeUBuf: degreeUBuf,
            degreeVBuf: degreeVBuf,
            numEdges: numEdges
        )

        for _ in 0..<params.trimRounds {
            try dispatchTrim(
                pipeline: trimUPipeline,
                edgePairBuf: edgePairBuffer,
                degreeUBuf: degreeUBuf,
                degreeVBuf: degreeVBuf,
                bitmapBuf: bitmapBuf,
                numEdges: numEdges
            )
            try dispatchTrim(
                pipeline: trimVPipeline,
                edgePairBuf: edgePairBuffer,
                degreeUBuf: degreeUBuf,
                degreeVBuf: degreeVBuf,
                bitmapBuf: bitmapBuf,
                numEdges: numEdges
            )
        }

        let finalBitmap = bitmapBuf.contents().assumingMemoryBound(to: UInt32.self)
        var surviving = [Int]()
        surviving.reserveCapacity(numEdges / 100)
        for i in 0..<numEdges {
            let word = finalBitmap[i / 32]
            let bit = UInt32(1) << (i % 32)
            if word & bit != 0 {
                surviving.append(i)
            }
        }

        return surviving
    }

    // MARK: - Private

    private func dispatchDegreeCount(
        edgePairBuf: MTLBuffer,
        degreeUBuf: MTLBuffer,
        degreeVBuf: MTLBuffer,
        numEdges: Int
    ) throws {
        guard let cmdBuf = commandQueue.makeCommandBuffer(),
              let encoder = cmdBuf.makeComputeCommandEncoder() else {
            throw TrimmerError.encodingFailed
        }

        encoder.setComputePipelineState(degreeCountPipeline)
        encoder.setBuffer(edgePairBuf, offset: 0, index: 0)
        encoder.setBuffer(degreeUBuf, offset: 0, index: 1)
        encoder.setBuffer(degreeVBuf, offset: 0, index: 2)

        let threadgroupSize = min(256, degreeCountPipeline.maxTotalThreadsPerThreadgroup)
        let gridSize = MTLSize(width: numEdges, height: 1, depth: 1)
        let tgSize = MTLSize(width: threadgroupSize, height: 1, depth: 1)
        encoder.dispatchThreads(gridSize, threadsPerThreadgroup: tgSize)

        encoder.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        if let error = cmdBuf.error {
            throw TrimmerError.gpuError(error)
        }
    }

    private func dispatchTrim(
        pipeline: MTLComputePipelineState,
        edgePairBuf: MTLBuffer,
        degreeUBuf: MTLBuffer,
        degreeVBuf: MTLBuffer,
        bitmapBuf: MTLBuffer,
        numEdges: Int
    ) throws {
        guard let cmdBuf = commandQueue.makeCommandBuffer(),
              let encoder = cmdBuf.makeComputeCommandEncoder() else {
            throw TrimmerError.encodingFailed
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(edgePairBuf, offset: 0, index: 0)
        encoder.setBuffer(degreeUBuf, offset: 0, index: 1)
        encoder.setBuffer(degreeVBuf, offset: 0, index: 2)
        encoder.setBuffer(bitmapBuf, offset: 0, index: 3)  // read-only alias
        encoder.setBuffer(bitmapBuf, offset: 0, index: 4)  // atomic write

        let threadgroupSize = min(256, pipeline.maxTotalThreadsPerThreadgroup)
        let gridSize = MTLSize(width: numEdges, height: 1, depth: 1)
        let tgSize = MTLSize(width: threadgroupSize, height: 1, depth: 1)
        encoder.dispatchThreads(gridSize, threadsPerThreadgroup: tgSize)

        encoder.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        if let error = cmdBuf.error {
            throw TrimmerError.gpuError(error)
        }
    }

    /// Load Metal shader library from embedded source strings.
    private static func loadShaderLibrary(device: MTLDevice) throws -> MTLLibrary {
        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        // ---- DegreeCount ----
        kernel void degree_count(
            device const uint32_t *edge_pairs   [[buffer(0)]],
            device atomic_uint    *degree_u     [[buffer(1)]],
            device atomic_uint    *degree_v     [[buffer(2)]],
            uint tid [[thread_position_in_grid]]
        ) {
            uint u = edge_pairs[tid * 2];
            uint v = edge_pairs[tid * 2 + 1];
            atomic_fetch_add_explicit(&degree_u[u], 1, memory_order_relaxed);
            atomic_fetch_add_explicit(&degree_v[v], 1, memory_order_relaxed);
        }

        // ---- Helpers ----
        inline bool is_alive(device const uint32_t *bitmap, uint idx) {
            uint word = bitmap[idx / 32];
            uint bit = 1u << (idx % 32);
            return (word & bit) != 0;
        }

        inline void kill_edge(device atomic_uint *bitmap, uint idx) {
            uint word_idx = idx / 32;
            uint bit = 1u << (idx % 32);
            atomic_fetch_and_explicit(&bitmap[word_idx], ~bit, memory_order_relaxed);
        }

        // ---- TrimU ----
        kernel void trim_u(
            device const uint32_t *edge_pairs   [[buffer(0)]],
            device atomic_uint    *degree_u     [[buffer(1)]],
            device atomic_uint    *degree_v     [[buffer(2)]],
            device const uint32_t *edge_bitmap_r [[buffer(3)]],
            device atomic_uint    *edge_bitmap  [[buffer(4)]],
            uint tid [[thread_position_in_grid]]
        ) {
            if (!is_alive(edge_bitmap_r, tid)) return;
            uint u = edge_pairs[tid * 2];
            uint deg = atomic_load_explicit(&degree_u[u], memory_order_relaxed);
            if (deg <= 1) {
                kill_edge(edge_bitmap, tid);
                atomic_fetch_sub_explicit(&degree_u[u], 1, memory_order_relaxed);
                uint v = edge_pairs[tid * 2 + 1];
                atomic_fetch_sub_explicit(&degree_v[v], 1, memory_order_relaxed);
            }
        }

        // ---- TrimV ----
        kernel void trim_v(
            device const uint32_t *edge_pairs   [[buffer(0)]],
            device atomic_uint    *degree_u     [[buffer(1)]],
            device atomic_uint    *degree_v     [[buffer(2)]],
            device const uint32_t *edge_bitmap_r [[buffer(3)]],
            device atomic_uint    *edge_bitmap  [[buffer(4)]],
            uint tid [[thread_position_in_grid]]
        ) {
            if (!is_alive(edge_bitmap_r, tid)) return;
            uint v = edge_pairs[tid * 2 + 1];
            uint deg = atomic_load_explicit(&degree_v[v], memory_order_relaxed);
            if (deg <= 1) {
                kill_edge(edge_bitmap, tid);
                uint u = edge_pairs[tid * 2];
                atomic_fetch_sub_explicit(&degree_u[u], 1, memory_order_relaxed);
                atomic_fetch_sub_explicit(&degree_v[v], 1, memory_order_relaxed);
            }
        }
        """

        return try device.makeLibrary(source: shaderSource, options: nil)
    }
}

// MARK: - Errors

public enum TrimmerError: Error, LocalizedError {
    case noMetalDevice
    case noCommandQueue
    case functionNotFound
    case bufferAllocationFailed
    case encodingFailed
    case gpuError(Error)

    public var errorDescription: String? {
        switch self {
        case .noMetalDevice: return "No Metal-capable GPU found"
        case .noCommandQueue: return "Failed to create Metal command queue"
        case .functionNotFound: return "Metal shader function not found"
        case .bufferAllocationFailed: return "Failed to allocate Metal buffer"
        case .encodingFailed: return "Failed to create Metal command encoder"
        case .gpuError(let e): return "GPU error: \(e.localizedDescription)"
        }
    }
}

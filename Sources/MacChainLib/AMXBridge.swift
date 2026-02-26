import Foundation
import Accelerate

/// Bridge to Apple's AMX coprocessor via the Accelerate framework.
/// On Apple Silicon, cblas_sgemm dispatches to AMX for matrix multiplication.
public enum AMXBridge {

    /// Multiply two square float32 matrices: C = A × B.
    /// `dim` is the side length (8, 16, or 32).
    /// All matrices are stored in row-major order.
    public static func matmul(
        a: UnsafePointer<Float>,
        b: UnsafePointer<Float>,
        c: UnsafeMutablePointer<Float>,
        dim: Int
    ) {
        let n = Int32(dim)
        // C = 1.0 * A * B + 0.0 * C
        cblas_sgemm(
            CblasRowMajor,   // row-major layout
            CblasNoTrans,    // don't transpose A
            CblasNoTrans,    // don't transpose B
            n, n, n,         // M, N, K
            1.0,             // alpha
            a, n,            // A, leading dim A
            b, n,            // B, leading dim B
            0.0,             // beta
            c, n             // C, leading dim C
        )
    }

    /// XOR-fold a matrix (dim × dim float32) into 16 bytes (128 bits).
    /// Treats each row as a chunk of (dim * 4) bytes and XORs all rows together,
    /// then folds the result down to 16 bytes.
    public static func xorFoldMatrix(
        _ matrix: UnsafePointer<Float>,
        dim: Int
    ) -> [UInt8] {
        let totalBytes = dim * dim * MemoryLayout<Float>.size
        let rawPtr = UnsafeRawPointer(matrix)

        // XOR all bytes into a 16-byte accumulator
        var result = [UInt8](repeating: 0, count: 16)
        for i in 0..<totalBytes {
            result[i % 16] ^= rawPtr.load(fromByteOffset: i, as: UInt8.self)
        }
        return result
    }

    /// Load float32 values from raw bytes (scratchpad memory).
    /// Interprets `count` bytes as Float32 array.
    @inline(__always)
    public static func loadFloats(from ptr: UnsafeRawPointer, count: Int) -> UnsafeMutablePointer<Float> {
        let floatCount = count / MemoryLayout<Float>.size
        let floats = UnsafeMutablePointer<Float>.allocate(capacity: floatCount)
        floats.initialize(from: ptr.assumingMemoryBound(to: Float.self), count: floatCount)
        return floats
    }
}

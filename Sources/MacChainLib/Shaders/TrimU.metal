#include <metal_stdlib>
using namespace metal;

/// Helper: check if edge at index `idx` is alive in the bitmap.
inline bool is_alive(device const uint32_t *bitmap, uint idx) {
    uint word = bitmap[idx / 32];
    uint bit = 1u << (idx % 32);
    return (word & bit) != 0;
}

/// Helper: kill edge at index `idx` in the bitmap.
inline void kill_edge(device atomic_uint *bitmap, uint idx) {
    uint word_idx = idx / 32;
    uint bit = 1u << (idx % 32);
    atomic_fetch_and_explicit(&bitmap[word_idx], ~bit, memory_order_relaxed);
}

/// Trim edges from the U side: eliminate edges where degree_u[u] <= 1.
kernel void trim_u(
    device const uint32_t *edge_pairs   [[buffer(0)]],  // interleaved [u0, v0, u1, v1, ...]
    device atomic_uint    *degree_u     [[buffer(1)]],
    device atomic_uint    *degree_v     [[buffer(2)]],
    device const uint32_t *edge_bitmap_r [[buffer(3)]],  // read-only alias
    device atomic_uint    *edge_bitmap  [[buffer(4)]],   // atomic write
    uint tid [[thread_position_in_grid]]
) {
    if (!is_alive(edge_bitmap_r, tid)) return;

    uint u = edge_pairs[tid * 2];
    // Read degree non-atomically for speed — slight races are acceptable
    // since we do multiple rounds
    uint deg = atomic_load_explicit(&degree_u[u], memory_order_relaxed);
    if (deg <= 1) {
        kill_edge(edge_bitmap, tid);
        atomic_fetch_sub_explicit(&degree_u[u], 1, memory_order_relaxed);
        uint v = edge_pairs[tid * 2 + 1];
        atomic_fetch_sub_explicit(&degree_v[v], 1, memory_order_relaxed);
    }
}

#include <metal_stdlib>
using namespace metal;

/// Count the initial degree of each node in both partitions.
/// Each edge (u, v) increments degree_u[u] and degree_v[v].
kernel void degree_count(
    device const uint32_t *edge_pairs   [[buffer(0)]],  // interleaved [u0, v0, u1, v1, ...]
    device atomic_uint    *degree_u     [[buffer(1)]],
    device atomic_uint    *degree_v     [[buffer(2)]],
    uint tid [[thread_position_in_grid]],
    uint grid_size [[threads_per_grid]]
) {
    // Each thread handles one edge
    uint u = edge_pairs[tid * 2];
    uint v = edge_pairs[tid * 2 + 1];

    atomic_fetch_add_explicit(&degree_u[u], 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&degree_v[v], 1, memory_order_relaxed);
}

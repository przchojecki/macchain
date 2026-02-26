# MacChain

**A Mac-first proof-of-work blockchain designed for Apple Silicon.**

MacChain is a modified Cuckoo Cycle proof-of-work blockchain that exploits the unique hardware characteristics of Apple Silicon — unified memory, hardware AES, the AMX matrix coprocessor, and Metal GPU compute — to create a mining algorithm that runs optimally on consumer Macs and is economically impractical to target with ASICs.

---

## Table of Contents

1. [Design Philosophy](#design-philosophy)
2. [Hardware Assumptions](#hardware-assumptions)
3. [Algorithm Overview](#algorithm-overview)
4. [Phase 1: Edge Generation (CPU — AES + AMX)](#phase-1-edge-generation)
5. [Phase 2: Edge Trimming (GPU — Metal Compute)](#phase-2-edge-trimming)
6. [Phase 3: Cycle Detection (CPU)](#phase-3-cycle-detection)
7. [Proof Format](#proof-format)
8. [Verification](#verification)
9. [Difficulty Adjustment](#difficulty-adjustment)
10. [Epoch System](#epoch-system)
11. [Security Analysis](#security-analysis)
12. [Performance Targets](#performance-targets)
13. [Build & Run](#build--run)
14. [Project Structure](#project-structure)
15. [References](#references)

---

## Design Philosophy

Traditional Cuckoo Cycle uses SipHash for edge generation — a lightweight, ASIC-friendly operation. MacChain replaces this with a multi-phase pipeline that chains three distinct hardware subsystems available on Apple Silicon, all operating on shared unified memory:

1. **AES hardware** — Fills a scratchpad using chained AES rounds (ARM Crypto Extensions).
2. **AMX matrix coprocessor** — Performs dependent matrix multiplications sourced from the scratchpad.
3. **Metal GPU** — Runs massively parallel edge trimming with zero-copy access to the same memory.

An ASIC targeting MacChain would need to replicate all three subsystems *and* a unified memory fabric connecting them. At that point, the ASIC is effectively an Apple Silicon clone and offers no economic advantage.

### Goals

- **Mac-first mining.** Any M1 or later Mac can mine competitively by launching an app. No external hardware, no configuration.
- **ASIC resistance through hardware diversity.** No single specialized circuit can accelerate the entire pipeline.
- **Concise proofs.** An 8-cycle proof is ~256 bytes. Verification takes milliseconds.
- **Simplicity.** The full miner should be implementable in under 2,000 lines of Swift + Metal.

### Non-goals

- Cross-platform parity. Linux/Windows/x86 implementations will work but run 2–4× slower. This is by design.
- GPU-only mining. The algorithm intentionally requires CPU-side work (AMX) that cannot be offloaded to the GPU.

---

## Hardware Assumptions

MacChain targets Apple Silicon M1 and later. The relevant hardware features:

| Feature | Specification | Role in MacChain |
|---|---|---|
| ARM Crypto Extensions | AES encode/decode, ~1 cycle/round | Scratchpad generation |
| AMX coprocessor | 16×16 float matrix multiply, ~10 ns | Edge endpoint mixing |
| Unified Memory (UMA) | Shared CPU/GPU address space, zero-copy | Trimming handoff |
| System-Level Cache (SLC) | ~32 MB shared L3 | Scratchpad fits here |
| Metal GPU Compute | Thousands of shader cores | Parallel edge trimming |
| Memory bandwidth | 100–800 GB/s depending on chip | Sustains trimming throughput |

**Minimum supported hardware:** Apple M1, 8 GB unified memory, macOS 13 Ventura or later.

---

## Algorithm Overview

```
                    ┌─────────────────────────┐
                    │     Block Header         │
                    │  (prev_hash + nonce)     │
                    └────────────┬────────────┘
                                 │
                    ┌────────────▼────────────┐
                    │  PHASE 1: Edge Gen       │
                    │  CPU (AES + AMX)         │
                    │                          │
                    │  Fills 16 MB scratchpad  │
                    │  via AES chain, then     │
                    │  generates 2^24 edges    │
                    │  using AMX matmul +      │
                    │  dependent scratchpad    │
                    │  reads.                  │
                    └────────────┬────────────┘
                                 │ (zero-copy, UMA)
                    ┌────────────▼────────────┐
                    │  PHASE 2: Trimming       │
                    │  GPU (Metal Compute)     │
                    │                          │
                    │  Iterative degree-1      │
                    │  node elimination on     │
                    │  bipartite graph.        │
                    │  ~80 rounds until <1%    │
                    │  of edges survive.       │
                    └────────────┬────────────┘
                                 │ (zero-copy, UMA)
                    ┌────────────▼────────────┐
                    │  PHASE 3: Cycle Search   │
                    │  CPU                     │
                    │                          │
                    │  Find an 8-cycle in the  │
                    │  trimmed graph.          │
                    └────────────┬────────────┘
                                 │
                    ┌────────────▼────────────┐
                    │  PROOF                   │
                    │  8 edge nonces           │
                    │  (~256 bytes)            │
                    └─────────────────────────┘
```

---

## Phase 1: Edge Generation

### 1.1 Scratchpad Initialization (AES Chain)

Derive a 128-bit AES key and IV from the block header using SHA-256:

```
header_hash = SHA256(block_header || nonce)
aes_key     = header_hash[0..15]
aes_iv      = header_hash[16..31]
```

Fill a **16 MB scratchpad** by chaining AES-128 encryptions:

```
state = aes_iv
for i in 0 ..< 1_048_576:       // 16 MB / 16 bytes per block
    state = AES_ENC(state, aes_key)
    scratchpad[i * 16 ..< (i+1) * 16] = state
```

This runs in ~2 ms on M-series chips using hardware AES. The scratchpad fits in the SLC (System-Level Cache), keeping subsequent dependent reads fast.

### 1.2 Edge Endpoint Computation (AMX + Dependent Reads)

For each edge index `e` in `0 ..< NUM_EDGES`:

```
1. Compute a scratchpad offset from current state:
     idx = (state[0..3] as uint32) % (SCRATCHPAD_SIZE - 512)

2. Load two 16×16 float matrices from the scratchpad:
     mat_a = load_4x4x16f(scratchpad[idx .. idx+256])
     mat_b = load_4x4x16f(scratchpad[idx+256 .. idx+512])

3. Multiply via AMX:
     mat_c = amx_matmul(mat_a, mat_b)

4. Fold mat_c into 128 bits:
     folded = xor_fold_matrix(mat_c)    // XOR all 16-byte rows

5. Mix with AES:
     state = AES_ENC(folded, state)

6. Write back to scratchpad (makes future reads depend on past computation):
     scratchpad[idx .. idx+16] = state

7. Extract edge endpoints:
     u = state[0..3] as uint32  &  NODE_MASK    // node in partition U
     v = state[4..7] as uint32  &  NODE_MASK    // node in partition V
```

### 1.3 Parameters

| Parameter | Value | Notes |
|---|---|---|
| `SCRATCHPAD_SIZE` | 16 MB (16,777,216 bytes) | Fits Apple SLC, expensive as ASIC SRAM |
| `NUM_EDGES` | 2^24 (16,777,216) | Number of edges in the bipartite graph |
| `NUM_NODES` | 2^23 (8,388,608) per partition | 2^24 total nodes across both sides |
| `NODE_MASK` | 0x7FFFFF | Masks to 23 bits |
| `MATRIX_DIM` | 16×16 float32 | Matches AMX native tile size |

---

## Phase 2: Edge Trimming

Edge trimming eliminates nodes with degree ≤ 1, since they cannot participate in any cycle. This is done iteratively on the GPU via Metal compute shaders, exploiting zero-copy UMA access to the edge array written in Phase 1.

### 2.1 Data Structures (Shared Memory)

```
edge_alive   : MTLBuffer, bitfield of NUM_EDGES bits     (~2 MB)
degree_u     : MTLBuffer, uint16[NUM_NODES]               (~16 MB)
degree_v     : MTLBuffer, uint16[NUM_NODES]               (~16 MB)
edges        : MTLBuffer, (uint32, uint32)[NUM_EDGES]     (~128 MB)
```

All buffers are allocated with `MTLResourceStorageModeShared` — accessible to both CPU and GPU with no copies.

### 2.2 Trimming Rounds

Each round dispatches two Metal compute passes (one per partition):

**Pass A — Trim from U side:**
```metal
kernel void trim_u(
    device uint32_t  *edge_pairs   [[buffer(0)]],
    device uint16_t  *degree_u     [[buffer(1)]],
    device uint32_t  *edge_bitmap  [[buffer(2)]],
    uint tid [[thread_position_in_grid]]
) {
    if (!is_alive(edge_bitmap, tid)) return;
    uint u = edge_pairs[tid * 2];
    if (degree_u[u] <= 1) {
        kill_edge(edge_bitmap, tid);
        atomic_fetch_sub_explicit(&degree_u[u], 1, memory_order_relaxed);
        uint v = edge_pairs[tid * 2 + 1];
        atomic_fetch_sub_explicit(&degree_v[v], 1, memory_order_relaxed);
    }
}
```

**Pass B — Trim from V side:** (symmetric, checks `degree_v[v] <= 1`)

Repeat for `TRIM_ROUNDS` iterations. Empirically, 80 rounds eliminate ~99% of edges for a graph of this size.

### 2.3 Trimming Parameters

| Parameter | Value |
|---|---|
| `TRIM_ROUNDS` | 80 |
| Threadgroup size | 256 |
| Grid size | `NUM_EDGES / 256` threadgroups |

After trimming, the CPU reads back `edge_bitmap` (zero-copy — just a pointer) to collect surviving edges for Phase 3.

---

## Phase 3: Cycle Detection

Find an **8-cycle** in the trimmed bipartite graph.

### 3.1 Algorithm

After trimming, typically ~100,000–200,000 edges survive. Build an adjacency list from surviving edges, then search for 8-cycles using a DFS/BFS hybrid:

```
1. Build adjacency lists for the sparse trimmed graph.
2. For each surviving node u:
     a. BFS/DFS from u, tracking the path.
     b. If we revisit u at exactly depth 8, record the cycle.
     c. Early termination: skip nodes with degree < 2.
3. Return the first valid 8-cycle found, or report failure.
```

This phase is CPU-bound and benefits from Apple's high single-thread performance, large reorder buffer, and aggressive prefetching.

### 3.2 Why 8-Cycle?

| Cycle length | Proof size | Find probability | Verification cost |
|---|---|---|---|
| 42 (Cuckatoo) | ~336 bytes | Very low per attempt | Moderate |
| 8 (MacChain) | ~256 bytes | Higher per attempt | Very fast |

Shorter cycles are easier to find per graph, so difficulty is controlled by adjusting the edge/node ratio and a hash-based target (see [Difficulty Adjustment](#difficulty-adjustment)).

---

## Proof Format

A valid proof consists of:

```
MacChainProof {
    block_header : [u8; 80]        // Standard block header
    nonce        : uint64           // Nonce used in Phase 1
    cycle_edges  : [uint32; 8]     // Indices of the 8 edges forming the cycle
}
```

**Total proof size: ~124 bytes** (80 + 8 + 32 + 4 bytes overhead).

The `cycle_edges` array contains the original edge indices (before trimming) of the 8 edges that form a valid cycle.

---

## Verification

A verifier checks a proof as follows:

```
1. Recompute edge endpoints:
     For each edge index in cycle_edges:
       - Run the Phase 1 edge generation for ONLY that edge index.
       - This requires initializing the scratchpad and computing
         the dependency chain up to that edge.
       - OPTIMIZATION: edges are batched and the scratchpad is
         computed once per verification.

2. Check cycle validity:
     - The 8 edges must form a closed cycle in the bipartite graph.
     - Formally: edges (u0,v0), (u1,v1), ..., (u7,v7) must satisfy
       v0 == v1 (or u-side connection), forming an alternating cycle.
     - No duplicate edges. No duplicate nodes.

3. Check difficulty target:
     - SHA256(proof_bytes) <= target
```

**Verification cost:** ~5–20 ms on any modern CPU. The bottleneck is recomputing 8 edges through the AES+AMX pipeline. A lightweight verifier can use software AES and scalar matrix multiply — it's slower but only 8 edges, not 16 million.

---

## Difficulty Adjustment

MacChain uses a **dual difficulty** system:

### Primary: Hash Target

```
SHA256(serialize(proof)) <= target
```

The miner varies the nonce in the block header. Each nonce produces a completely different graph (different scratchpad, different edges). The target adjusts every 2016 blocks to maintain a 10-minute average block time (configurable).

### Secondary: Graph Hardness

The probability of an 8-cycle existing in a random bipartite graph with `E` edges and `N` nodes per side is governed by the edge-to-node ratio `E/N`. At `E/N = 2.0` (our default), roughly 1 in 3 graphs contains at least one 8-cycle. This ratio is fixed within an epoch but can shift across epochs (see below).

---

## Epoch System

Every **4096 blocks**, a new epoch begins. The epoch seed is:

```
epoch_seed = SHA256(block_hash[epoch_start - 1])
```

The epoch seed determines:

| Parameter | Range | Effect |
|---|---|---|
| `SCRATCHPAD_SIZE` | 12–20 MB | Varies cache pressure |
| `NUM_EDGES` | 2^23 – 2^25 | Varies graph density |
| `MATRIX_DIM` | 8, 16, or 32 | Varies AMX workload |
| `TRIM_ROUNDS` | 60–100 | Varies GPU work |

Parameter derivation:

```
params = expand(epoch_seed)
SCRATCHPAD_SIZE = 12MB + (params[0] % 9) * 1MB     // 12–20 MB
NUM_EDGES       = 1 << (23 + (params[1] % 3))      // 2^23, 2^24, or 2^25
MATRIX_DIM      = 8 << (params[2] % 3)             // 8, 16, or 32
TRIM_ROUNDS     = 60 + (params[3] % 41)            // 60–100
NUM_NODES       = NUM_EDGES / 2                     // maintain E/N = 2.0
```

This prevents ASICs from being tuned to a single fixed geometry.

---

## Security Analysis

### ASIC Resistance

| Attack vector | Mitigation |
|---|---|
| Custom AES pipeline | AES alone is insufficient — must also do AMX matmul and memory-latency-bound reads |
| Custom matrix multiplier | Must be general enough to handle 8×8, 16×16, and 32×32 tiles (epoch-dependent) |
| Large SRAM for scratchpad | 12–20 MB of SRAM is very expensive on-die; epoch variation prevents optimizing for one size |
| Skip trimming, brute-force cycles | Trimming reduces the graph by ~99%; skipping it makes cycle search intractable |
| FPGA | FPGAs lack efficient AES and matrix units; will be slower than M1 |

### Graph-Theoretic Security

- An 8-cycle in a random bipartite graph with `E/N = 2.0` is non-trivial to find without performing honest trimming.
- The proof-of-work is the combination of: (a) finding a nonce whose graph contains an 8-cycle, and (b) the hash of the proof meeting the target.
- Faking a proof requires computing at minimum the 8 specific edges, which requires the full scratchpad and AMX pipeline.

### Shortcut Resistance

The dependent-read chain in Phase 1 (each edge computation reads from a scratchpad location determined by the previous computation) prevents:

- **Parallelization of edge generation.** Each edge depends on the state left by the previous edge.
- **Partial computation.** You cannot compute edge `e` without computing edges `0` through `e-1`.
- **Memory trade-offs.** The scratchpad is both read and written during edge generation; you cannot discard or recompute parts of it.

---

## Performance Targets

| Metric | M1 (base) | M1 Pro | M1 Max/Ultra | M4 Pro |
|---|---|---|---|---|
| Phase 1 (edge gen) | ~800 ms | ~700 ms | ~600 ms | ~400 ms |
| Phase 2 (trimming) | ~200 ms | ~150 ms | ~80 ms | ~60 ms |
| Phase 3 (cycle search) | ~50 ms | ~40 ms | ~30 ms | ~20 ms |
| **Total per graph** | **~1.05 s** | **~0.89 s** | **~0.71 s** | **~0.48 s** |
| Verification | ~15 ms | ~12 ms | ~10 ms | ~8 ms |

These are estimates. Actual performance will be benchmarked during implementation.

On x86 (without AMX, with AES-NI): expect ~2–4× slower edge generation due to software matrix multiply.

---

## Build & Run

### Requirements

- macOS 13 Ventura or later
- Apple Silicon (M1 or later)
- Xcode 15+ or Swift 5.9+ toolchain

### Build

```bash
swift build -c release
```

### Run Miner

```bash
# Solo mining (testnet)
.build/release/macchain mine --threads 4

# Benchmark mode (no network, just measures graphs/second)
.build/release/macchain bench

# Verify a proof
.build/release/macchain verify --proof <hex-encoded-proof>
```

### Run Tests

```bash
swift test
```

---

## Project Structure

```
macchain/
├── README.md                    # This file
├── Package.swift                # Swift package manifest
├── Sources/
│   ├── MacChain/
│   │   ├── main.swift           # CLI entry point
│   │   ├── Miner.swift          # Mining loop orchestration
│   │   ├── EdgeGen.swift        # Phase 1: AES + AMX edge generation
│   │   ├── Scratchpad.swift     # Scratchpad allocation and AES fill
│   │   ├── AMXBridge.swift      # Swift-to-AMX interop (via Accelerate)
│   │   ├── Trimmer.swift        # Phase 2: Metal GPU trimming controller
│   │   ├── TrimShader.metal     # Metal compute shaders for trimming
│   │   ├── CycleFinder.swift    # Phase 3: 8-cycle detection
│   │   ├── Verifier.swift       # Proof verification
│   │   ├── Proof.swift          # Proof data structures and serialization
│   │   ├── EpochParams.swift    # Epoch-based parameter derivation
│   │   ├── Difficulty.swift     # Difficulty adjustment logic
│   │   └── Types.swift          # Shared types and constants
│   └── MacChainBenchmark/
│       └── Benchmark.swift      # Performance benchmarking harness
├── Tests/
│   ├── EdgeGenTests.swift       # Scratchpad + edge generation correctness
│   ├── TrimmerTests.swift       # Trimming round correctness
│   ├── CycleFinderTests.swift   # Cycle detection on known graphs
│   ├── VerifierTests.swift      # End-to-end proof verification
│   └── EpochTests.swift         # Parameter derivation determinism
└── Shaders/
    ├── TrimU.metal              # U-side trimming kernel
    ├── TrimV.metal              # V-side trimming kernel
    └── DegreeCount.metal        # Initial degree counting kernel
```

---

## References

- Tromp, J. (2015). *Cuckoo Cycle: a memory bound graph-theoretic proof-of-work.* [https://eprint.iacr.org/2014/059](https://eprint.iacr.org/2014/059)
- Howard, J. et al. (2022). *RandomX: ASIC-resistant proof-of-work.* [https://github.com/tevador/RandomX](https://github.com/tevador/RandomX)
- Johnson, D. (2021). *Apple AMX reverse engineering.* [https://github.com/corsix/amx](https://github.com/corsix/amx)
- Apple Inc. *Metal Shading Language Specification.* [https://developer.apple.com/metal/Metal-Shading-Language-Specification.pdf](https://developer.apple.com/metal/Metal-Shading-Language-Specification.pdf)
- Apple Inc. *Accelerate Framework — BLAS.* [https://developer.apple.com/documentation/accelerate/blas](https://developer.apple.com/documentation/accelerate/blas)

---

## License

MIT

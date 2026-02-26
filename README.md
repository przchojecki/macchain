# MacChain

MacChain is a Mac-first proof-of-work prototype built for Apple Silicon.

It combines CPU AES, AMX-style matrix mixing, and Metal GPU trimming into a single mining pipeline that is optimized for unified-memory Macs.

## Why This Exists

Traditional Cuckoo Cycle variants are efficient to accelerate with specialized hardware. MacChain explores a different profile:

- CPU-bound dependent memory work (AES + matrix transforms)
- GPU-bound graph trimming (Metal compute)
- fast CPU verification with compact proofs

The goal is to keep commodity Apple Silicon competitive while preserving short proofs and fast verification.

## Current Components

- `MacChainLib` (core library)
- `macchain` (CLI: `mine`, `bench`, `verify`)
- `macchain-bench` (benchmark executable)
- Metal shaders for trimming (`TrimU`, `TrimV`, `DegreeCount`)

## Mining Pipeline

### Phase 1: Edge Generation (CPU)

- Derive seed material from block header + nonce
- Fill/update a scratchpad using AES-dependent state transitions
- Generate bipartite graph edges (`u`, `v`) from evolving state
- Mix state through matrix operations to increase dependency depth

Output: dense edge set for one nonce.

### Phase 2: Trimming (GPU via Metal)

- Build per-partition degree maps
- Iteratively remove edges connected to degree-1 nodes
- Repeat for configured trim rounds (default: 80)

Output: sparse surviving edge set.

### Phase 3: Cycle Search (CPU)

- Build adjacency from surviving edges
- Search for an 8-cycle in the bipartite graph
- If found, emit proof with cycle edge indices + header/nonce context

Output: `MacChainProof`.

## Verification Pipeline

`Verifier` checks:

- proof serialization integrity
- graph/cycle validity
- optional difficulty target satisfaction

This keeps verification much cheaper than full mining.

## Build

### 1) Standard SwiftPM

```bash
swift build
swift test
```

### 2) Standalone Script (fallback)

```bash
bash build.sh
```

Produces:

- `.build/release/libMacChainLib.dylib`
- `.build/release/macchain`
- `.build/release/macchain-bench`

## CLI Usage

```bash
# Mine
.build/release/macchain mine --max-attempts 100000

# Benchmark
.build/release/macchain bench --graphs 5

# Verify proof
.build/release/macchain verify --proof <hex>

# Help
.build/release/macchain --help
```

## CI

GitHub Actions runs on every push to `main` and every pull request:

- SwiftPM build + test (`swift build`, `swift test`)
- standalone build script (`bash build.sh`)
- CLI smoke check (`macchain --help`)

Workflow file: `.github/workflows/ci.yml`

## Releases

Release workflow triggers on tags matching `v*` and publishes:

- `macchain-<tag>-macos-arm64.tar.gz`
- `macchain-<tag>-macos-arm64.sha256`

Create a release by tagging and pushing:

```bash
git tag v0.1.0
git push origin v0.1.0
```

Workflow file: `.github/workflows/release.yml`

## Project Layout

```text
Sources/
  MacChain/
  MacChainBenchmark/
  MacChainLib/
    Shaders/
Tests/
  MacChainTests/
build.sh
Package.swift
```

## Status

This repository is an implementation prototype, not a production consensus system.

Current focus:

- correctness of edge generation, trimming, and cycle verification
- benchmarkability on Apple Silicon
- clean module boundaries for future network/consensus integration

For deeper algorithm notes and rationale, see `macchain.md`.

# MacChain

MacChain is a Mac-first proof-of-work blockchain designed specifically for Apple Silicon. Instead of treating the Mac as a generic CPU target, the chain and miner are co-designed around the hardware profile of modern M-series machines: fast on-chip memory, strong AES throughput, matrix-heavy CPU compute, and integrated Metal GPU acceleration.

What makes MacChain unique is its hybrid mining pipeline: CPU-dependent memory work (AES + matrix mixing) feeds directly into GPU graph trimming, followed by compact cycle proofs that are fast to verify. This makes it especially good for AI agents to mine, because agents can script the full loop (`bench` -> `mine` -> `verify`), tune parameters automatically, and validate results quickly in a deterministic CLI workflow without specialized hardware.

## Blockchain Architecture

MacChain uses a Nakamoto-style Proof-of-Work consensus model with UTXO accounting. Miners build blocks containing transactions and a PoW proof (`MacChainProof`) bound to the 80-byte block header; full nodes validate header/proof consistency, Merkle root correctness, timestamp bounds, transaction state transitions, coinbase subsidy limits, and script/signature authorization before accepting a block. Fork choice is heaviest-chain by cumulative work (`totalWork`) with deterministic tie-breaks, so competing branches can be reconstructed and re-evaluated from persisted block data.

Transaction validity is enforced against the active tip UTXO set, including double-spend prevention, input/output value conservation, and Ed25519 unlocking against locking scripts. Networking is a message-framed P2P relay with version/verack handshake, tip exchange, block/tx propagation, and on-demand parent backfill (`getBlock`) when orphans or higher tips are observed. Chainstate is disk-backed (`--data-dir`) and rebuilds deterministically on restart, while difficulty adjustment and work scoring are integrated into block acceptance to keep consensus rules consistent across live validation and storage replay.

On the mining side, MacChain follows the Cuckoo/Cuckatoo design family by searching for fixed-length cycles in a large bipartite graph, but adapts execution to Apple Silicon hardware characteristics. Each nonce drives deterministic edge generation, iterative trimming removes edges that cannot participate in a valid cycle, and miners prove discovery of an 8-cycle as compact evidence of work. This keeps verification lightweight while preserving the core memory-hard graph-search properties that make Cuckoo-style PoW resistant to naive compute-only optimization.

## Why This Exists

Traditional Cuckoo Cycle variants are efficient to accelerate with specialized hardware. MacChain explores a different profile:

- CPU-bound dependent memory work (AES + matrix transforms)
- GPU-bound graph trimming (Metal compute)
- fast CPU verification with compact proofs

The goal is to keep commodity Apple Silicon competitive while preserving short proofs and fast verification.

## Current Components

- `MacChainLib` (core library)
- `macchain` (CLI: `mine`, `bench`, `verify`, `node`)
- `macchain-bench` (benchmark executable)
- chain/transaction primitives (`Transaction`, `Block`)
- chainstate + mempool actors (`ChainState`, `Mempool`)
- file-backed block store + tip metadata (`--data-dir`, restart rebuild)
- Ed25519 transaction scripts (`TxScript`) + input signature checks
- P2P node service skeleton (`P2PNodeService`)
- UTXO state-transition checks (coinbase, input existence, spend/value rules)
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
- edge-index bounds and duplicate protection
- single 8-cycle graph validity
- trim-survival constraints for full verification
- difficulty target satisfaction from header bits

This keeps verification much cheaper than full mining.

## Chainstate And Tx Authorization

- chainstate persists accepted blocks and best-tip metadata to disk
- on restart, chainstate replays persisted blocks from genesis and recomputes best tip by total work
- tx authorization uses a minimal script template: pay-to-Ed25519-public-key locking script + Ed25519 signature unlocking script
- default insecure genesis now uses a deterministic Ed25519 locking script derived from `network-id`
- signature checks are enforced during block validation and mempool admission

## Build

### 1) Standard SwiftPM

```bash
swift build
swift test
```

If `swift test` fails with a local SwiftPM/manifest-loader mismatch, use `bash build.sh` as the current fallback while fixing the local toolchain install.

### 2) Standalone Script (fallback)

```bash
bash build.sh
```

Produces:

- `.build/release/libMacChainLib.dylib`
- `.build/release/macchain`
- `.build/release/macchain-bench`

## Quickstart Mining

Build and mine a first proof:

```bash
# Build binaries
bash build.sh

# Check CLI options
.build/release/macchain --help

# Quick benchmark (optional)
.build/release/macchain bench --graphs 3

# Mine up to 100k attempts
.build/release/macchain mine --start-nonce 0 --max-attempts 100000
```

Verify a proof returned by the miner:

```bash
.build/release/macchain verify --proof <hex-from-mine-output>
```

## Quickstart Node (Local P2P)

Run two local nodes and connect them:

```bash
# Terminal 1
.build/release/macchain node --listen 8338 --data-dir ./.macchain-a

# Terminal 2
.build/release/macchain node --listen 8339 --data-dir ./.macchain-b --connect 127.0.0.1:8338
```

Notes:

- this is an initial public-network skeleton (handshake, tip exchange, tx/block relay)
- nodes request missing blocks with `getBlock` when peers advertise higher tips or send orphans
- peers must complete version/verack handshake before block/tx data is accepted
- inbound frame size, message payload size, and pending block-request queue are bounded
- chainstate enforces block structure, UTXO transitions, and script/signature checks
- blocks/tip metadata are persisted under `--data-dir` and rebuilt on restart
- full fork-choice/difficulty-retarget networking logic is still evolving

## CLI Usage

```bash
# Mine
.build/release/macchain mine --max-attempts 100000

# Benchmark
.build/release/macchain bench --graphs 5

# Verify proof
.build/release/macchain verify --proof <hex>

# Run node
.build/release/macchain node --listen 8338 --connect 127.0.0.1:8339

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

Release workflow triggers on tags matching `v*` or plain semver (`*.*.*`) and publishes:

- `macchain-<tag>-macos-arm64.tar.gz`
- `macchain-<tag>-macos-arm64.sha256`

Create a release by tagging and pushing:

```bash
# plain semver
git tag 0.1.6
git push origin 0.1.6

# or prefixed semver
git tag v0.1.6
git push origin v0.1.6
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

This repository contains the MacChain blockchain implementation and tooling.

Current focus:

- correctness of edge generation, trimming, and cycle verification
- benchmarkability on Apple Silicon
- bootstrap of chainstate and P2P node scaffolding for a runnable public network

For deeper algorithm notes and rationale, see `macchain.md`.

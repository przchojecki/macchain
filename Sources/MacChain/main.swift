import Foundation
import MacChainLib

// MARK: - CLI (no external dependencies)

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "help"

switch command {
case "mine":
    runMine(args: Array(args.dropFirst()))
case "bench":
    runBench(args: Array(args.dropFirst()))
case "verify":
    runVerify(args: Array(args.dropFirst()))
case "help", "--help", "-h":
    printUsage()
case "--version":
    print("macchain 0.1.0")
default:
    print("Unknown command: \(command)")
    printUsage()
    exit(1)
}

// MARK: - Commands

func printUsage() {
    print("""
    MacChain — Mac-first proof-of-work for Apple Silicon

    USAGE: macchain <command> [options]

    COMMANDS:
      mine     Run the MacChain miner
      bench    Benchmark performance
      verify   Verify a proof
      help     Show this help

    OPTIONS:
      --version    Show version
    """)
}

func parseOption(_ args: [String], _ name: String, default defaultValue: String) -> String {
    guard let idx = args.firstIndex(of: name), idx + 1 < args.count else {
        return defaultValue
    }
    return args[idx + 1]
}

func runMine(args: [String]) {
    let maxAttempts = UInt64(parseOption(args, "--max-attempts", default: "0")) ?? 0
    let startNonce = UInt64(parseOption(args, "--start-nonce", default: "0")) ?? 0

    print("MacChain Miner v0.1.0")
    print("======================")
    print("Parameters: default (16 MB scratchpad, 2^24 edges, 16x16 matrix, 80 trim rounds)")
    print("")

    let header = BlockHeader(
        prevHash: Data(repeating: 0, count: 32),
        timestamp: UInt32(Date().timeIntervalSince1970)
    )
    let difficulty = Difficulty.initial
    let miner = Miner(difficulty: difficulty)

    let max = maxAttempts == 0 ? UInt64.max : maxAttempts

    print("Mining... (press Ctrl+C to stop)")
    print("")

    let result = miner.mine(
        blockHeader: header,
        startNonce: startNonce,
        maxAttempts: max
    ) { progress in
        let gps = String(format: "%.2f", progress.graphsPerSecond)
        let p1 = String(format: "%.1f", progress.phase1Ms)
        let p2 = String(format: "%.1f", progress.phase2Ms)
        let p3 = String(format: "%.1f", progress.phase3Ms)
        print("  nonce=\(progress.nonce) attempts=\(progress.attempts) " +
              "graphs/s=\(gps) phase1=\(p1)ms phase2=\(p2)ms phase3=\(p3)ms " +
              "surviving=\(progress.survivingEdges) cycle=\(progress.cycleFound)")
    }

    switch result {
    case .found(let proof):
        print("")
        print("PROOF FOUND!")
        print("  Nonce: \(proof.nonce)")
        print("  Cycle edges: \(proof.cycleEdges)")
        print("  Proof hex: \(proof.serialized().map { String(format: "%02x", $0) }.joined())")
    case .notFound:
        print("No proof found within attempt limit.")
    case .cancelled:
        print("Mining cancelled.")
    }
}

func runBench(args: [String]) {
    let graphs = Int(parseOption(args, "--graphs", default: "5")) ?? 5

    print("MacChain Benchmark")
    print("===================")
    print("Parameters: default (16 MB scratchpad, 2^24 edges, 16x16 matrix, 80 trim rounds)")
    print("Graphs to test: \(graphs)")
    print("")

    let params = MacChainParams.default
    let edgeGen = EdgeGenerator(params: params)
    let headerData = BlockHeader().serialized()

    var phase1Times = [Double]()
    var phase2Times = [Double]()
    var phase3Times = [Double]()
    var totalTimes = [Double]()
    var cyclesFound = 0

    let trimmer: Trimmer?
    do {
        trimmer = try Trimmer(params: params)
        print("GPU: Metal available")
    } catch {
        print("GPU: Metal unavailable (\(error.localizedDescription)), using CPU trimming")
        trimmer = nil
    }
    print("")

    for i in 0..<graphs {
        let nonce = UInt64(i)
        let totalStart = CFAbsoluteTimeGetCurrent()

        let p1Start = CFAbsoluteTimeGetCurrent()
        let edges = edgeGen.generateEdges(blockHeader: headerData, nonce: nonce)
        let p1Time = (CFAbsoluteTimeGetCurrent() - p1Start) * 1000
        phase1Times.append(p1Time)

        let p2Start = CFAbsoluteTimeGetCurrent()
        let surviving: [Int]
        if let trimmer = trimmer {
            do {
                surviving = try trimmer.trim(edges: edges)
            } catch {
                print("  GPU trim failed: \(error)")
                surviving = cpuTrim(edges: edges, params: params)
            }
        } else {
            surviving = cpuTrim(edges: edges, params: params)
        }
        let p2Time = (CFAbsoluteTimeGetCurrent() - p2Start) * 1000
        phase2Times.append(p2Time)

        let p3Start = CFAbsoluteTimeGetCurrent()
        let survivingEdges = surviving.map { edges[$0] }
        let cycle = CycleFinder.findCycle(edges: survivingEdges, survivingIndices: surviving)
        let p3Time = (CFAbsoluteTimeGetCurrent() - p3Start) * 1000
        phase3Times.append(p3Time)

        let totalTime = (CFAbsoluteTimeGetCurrent() - totalStart) * 1000
        totalTimes.append(totalTime)

        if cycle != nil { cyclesFound += 1 }

        let p1Str = String(format: "%8.1f", p1Time)
        let p2Str = String(format: "%8.1f", p2Time)
        let p3Str = String(format: "%8.1f", p3Time)
        let totStr = String(format: "%8.1f", totalTime)
        print("  Graph \(i): phase1=\(p1Str)ms  phase2=\(p2Str)ms  phase3=\(p3Str)ms  total=\(totStr)ms  " +
              "surviving=\(surviving.count)  cycle=\(cycle != nil)")
    }

    print("")
    print("Summary")
    print("-------")
    let avgP1 = String(format: "%.1f", phase1Times.reduce(0, +) / Double(graphs))
    let avgP2 = String(format: "%.1f", phase2Times.reduce(0, +) / Double(graphs))
    let avgP3 = String(format: "%.1f", phase3Times.reduce(0, +) / Double(graphs))
    let avgTotal = String(format: "%.1f", totalTimes.reduce(0, +) / Double(graphs))
    let gps = String(format: "%.3f", 1000.0 / (totalTimes.reduce(0, +) / Double(graphs)))

    print("  Avg phase 1 (edge gen):    \(avgP1) ms")
    print("  Avg phase 2 (trimming):    \(avgP2) ms")
    print("  Avg phase 3 (cycle find):  \(avgP3) ms")
    print("  Avg total per graph:       \(avgTotal) ms")
    print("  Graphs/second:             \(gps)")
    print("  Cycles found:              \(cyclesFound)/\(graphs)")
}

func runVerify(args: [String]) {
    let proofHex = parseOption(args, "--proof", default: "")
    guard !proofHex.isEmpty else {
        print("Error: --proof <hex> required")
        exit(1)
    }

    guard let proofData = Data(hexString: proofHex) else {
        print("Error: Invalid hex string")
        exit(1)
    }

    guard let proof = MacChainProof.deserialize(from: proofData) else {
        print("Error: Could not deserialize proof (need at least 120 bytes)")
        exit(1)
    }

    print("Verifying proof...")
    print("  Nonce: \(proof.nonce)")
    print("  Cycle edges: \(proof.cycleEdges)")

    let verifier = Verifier()
    let result = verifier.verifyCycleOnly(proof)

    switch result {
    case .valid:
        print("  Result: VALID")
    case .invalid(let reason):
        print("  Result: INVALID — \(reason)")
        exit(1)
    }
}

func cpuTrim(edges: [Edge], params: MacChainParams) -> [Int] {
    var alive = [Bool](repeating: true, count: edges.count)
    var degreeU = [UInt32: Int]()
    var degreeV = [UInt32: Int]()

    for edge in edges {
        degreeU[edge.u, default: 0] += 1
        degreeV[edge.v, default: 0] += 1
    }

    for _ in 0..<params.trimRounds {
        for (i, edge) in edges.enumerated() where alive[i] {
            if (degreeU[edge.u] ?? 0) <= 1 {
                alive[i] = false
                degreeU[edge.u, default: 0] -= 1
                degreeV[edge.v, default: 0] -= 1
            }
        }
        for (i, edge) in edges.enumerated() where alive[i] {
            if (degreeV[edge.v] ?? 0) <= 1 {
                alive[i] = false
                degreeU[edge.u, default: 0] -= 1
                degreeV[edge.v, default: 0] -= 1
            }
        }
    }

    return (0..<edges.count).filter { alive[$0] }
}

// MARK: - Hex helper

extension Data {
    init?(hexString: String) {
        let hex = hexString.hasPrefix("0x") ? String(hexString.dropFirst(2)) : hexString
        guard hex.count % 2 == 0 else { return nil }

        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }
}

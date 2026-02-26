import Foundation
import MacChainLib

private let appName = "macchain"
private let cliVersion = "0.1.3"

private struct ParsedCommandArgs {
    var values: [String: String] = [:]
    var flags: Set<String> = []
    var positionals: [String] = []
}

private enum CommandParseError: Error {
    case message(String)

    var text: String {
        switch self {
        case .message(let message):
            return message
        }
    }
}

private func stderrPrint(_ message: String) {
    fputs(message + "\n", stderr)
}

private func printError(_ message: String) {
    stderrPrint("error: \(message)")
}

private func printKeyValue(_ key: String, _ value: String) {
    let padded = key.padding(toLength: 18, withPad: " ", startingAt: 0)
    print("  \(padded) \(value)")
}

private func grouped(_ raw: String) -> String {
    let negative = raw.hasPrefix("-")
    let digits = negative ? String(raw.dropFirst()) : raw

    var out = ""
    var index = 0
    for ch in digits.reversed() {
        if index > 0 && index % 3 == 0 {
            out.append(",")
        }
        out.append(ch)
        index += 1
    }

    let groupedDigits = String(out.reversed())
    return negative ? "-\(groupedDigits)" : groupedDigits
}

private func formatCount(_ value: Int) -> String {
    grouped(String(value))
}

private func formatCount(_ value: UInt64) -> String {
    grouped(String(value))
}

private func formatSeconds(_ value: Double) -> String {
    if value < 1.0 {
        return String(format: "%.0f ms", value * 1000.0)
    }
    return String(format: "%.2f s", value)
}

private func parseCommandArgs(
    _ raw: [String],
    valueOptions: Set<String>,
    flagOptions: Set<String>
) -> Result<ParsedCommandArgs, CommandParseError> {
    var parsed = ParsedCommandArgs()
    var idx = 0

    while idx < raw.count {
        let token = raw[idx]

        if token == "--" {
            if idx + 1 < raw.count {
                parsed.positionals.append(contentsOf: raw[(idx + 1)...])
            }
            break
        }

        if token.hasPrefix("-") {
            var name = token
            var inlineValue: String?

            if token.hasPrefix("--"), let eq = token.firstIndex(of: "=") {
                name = String(token[..<eq])
                inlineValue = String(token[token.index(after: eq)...])
            }

            if valueOptions.contains(name) {
                let value: String
                if let inline = inlineValue {
                    value = inline
                } else {
                    idx += 1
                    guard idx < raw.count else {
                        return .failure(.message("Missing value for option '\(name)'"))
                    }
                    value = raw[idx]
                }
                parsed.values[name] = value
            } else if flagOptions.contains(name) {
                if inlineValue != nil {
                    return .failure(.message("Flag '\(name)' does not accept a value"))
                }
                parsed.flags.insert(name)
            } else {
                return .failure(.message("Unknown option '\(token)'"))
            }
        } else {
            parsed.positionals.append(token)
        }

        idx += 1
    }

    return .success(parsed)
}

private func parseUInt64Option(_ parsed: ParsedCommandArgs, name: String, default defaultValue: UInt64) -> UInt64? {
    guard let raw = parsed.values[name] else { return defaultValue }
    guard let value = UInt64(raw) else {
        printError("\(name) expects an unsigned integer, got '\(raw)'")
        return nil
    }
    return value
}

private func parseIntOption(_ parsed: ParsedCommandArgs, name: String, default defaultValue: Int) -> Int? {
    guard let raw = parsed.values[name] else { return defaultValue }
    guard let value = Int(raw) else {
        printError("\(name) expects an integer, got '\(raw)'")
        return nil
    }
    return value
}

private func printMainUsage() {
    print("""
    MacChain Blockchain CLI

    USAGE:
      \(appName) <command> [options]

    COMMANDS:
      mine      Mine for a valid MacChain proof
      bench     Benchmark the mining pipeline
      verify    Verify a serialized proof
      help      Show global or command help

    GLOBAL OPTIONS:
      --version         Show version
      -h, --help        Show this help

    Run '\(appName) <command> --help' for command-specific options.
    """)
}

private func printMineUsage() {
    print("""
    Mine for a valid MacChain proof.

    USAGE:
      \(appName) mine [options]

    OPTIONS:
      --start-nonce <u64>     Nonce to begin from (default: 0)
      --max-attempts <u64>    Number of nonces to try; 0 means unlimited (default: 0)
      -h, --help              Show this help

    EXAMPLE:
      \(appName) mine --start-nonce 0 --max-attempts 100000
    """)
}

private func printBenchUsage() {
    print("""
    Benchmark the MacChain mining phases.

    USAGE:
      \(appName) bench [options]

    OPTIONS:
      --graphs <int>          Number of graphs/nonces to benchmark (default: 5)
      --small                 Use reduced parameters for quick test runs
      -h, --help              Show this help

    EXAMPLE:
      \(appName) bench --graphs 10
      \(appName) bench --small --graphs 20
    """)
}

private func printVerifyUsage() {
    print("""
    Verify a serialized MacChain proof.

    USAGE:
      \(appName) verify --proof <hex> [--full]
      \(appName) verify <hex> [--full]

    OPTIONS:
      --proof <hex>           Hex-encoded serialized proof
      --full                  Run full verification (includes difficulty check)
      -h, --help              Show this help

    NOTES:
      Default mode verifies cycle validity only.
      Use --full to also enforce current difficulty target.
    """)
}

private func runMine(args: [String]) {
    let valueOptions: Set<String> = ["--start-nonce", "--max-attempts"]
    let flagOptions: Set<String> = ["--help", "-h"]

    let parsed: ParsedCommandArgs
    switch parseCommandArgs(args, valueOptions: valueOptions, flagOptions: flagOptions) {
    case .success(let p):
        parsed = p
    case .failure(let err):
        printError(err.text)
        printMineUsage()
        exit(2)
    }

    if parsed.flags.contains("--help") || parsed.flags.contains("-h") {
        printMineUsage()
        return
    }

    if !parsed.positionals.isEmpty {
        printError("Unexpected positional arguments: \(parsed.positionals.joined(separator: " "))")
        printMineUsage()
        exit(2)
    }

    guard let startNonce = parseUInt64Option(parsed, name: "--start-nonce", default: 0),
          let maxAttempts = parseUInt64Option(parsed, name: "--max-attempts", default: 0)
    else {
        exit(2)
    }

    let effectiveMax = maxAttempts == 0 ? UInt64.max : maxAttempts
    let maxText = maxAttempts == 0 ? "unlimited" : formatCount(maxAttempts)

    let header = BlockHeader(
        prevHash: Data(repeating: 0, count: 32),
        timestamp: UInt32(Date().timeIntervalSince1970)
    )
    let difficulty = Difficulty.initial
    let miner = Miner(difficulty: difficulty)

    print("MacChain Miner")
    print("-------------")
    printKeyValue("Version", cliVersion)
    printKeyValue("Start nonce", formatCount(startNonce))
    printKeyValue("Max attempts", maxText)
    printKeyValue("Scratchpad", "16 MB")
    printKeyValue("Edges", "2^24 (\(formatCount(1 << 24)))")
    printKeyValue("Trim rounds", "80")
    print("")
    print("Mining... (Ctrl+C to stop)")

    var lastProgress: MinerProgress?

    let result = miner.mine(
        blockHeader: header,
        startNonce: startNonce,
        maxAttempts: effectiveMax
    ) { progress in
        lastProgress = progress
        let gps = String(format: "%.2f", progress.graphsPerSecond)
        let p1 = String(format: "%.1f", progress.phase1Ms)
        let p2 = String(format: "%.1f", progress.phase2Ms)
        let p3 = String(format: "%.1f", progress.phase3Ms)
        print("  [\(formatCount(progress.attempts))] nonce=\(formatCount(progress.nonce)) gps=\(gps) p1=\(p1)ms p2=\(p2)ms p3=\(p3)ms surviving=\(formatCount(progress.survivingEdges)) cycle=\(progress.cycleFound)")
    }

    print("")

    switch result {
    case .found(let proof):
        print("PROOF FOUND")
        printKeyValue("Nonce", formatCount(proof.nonce))
        printKeyValue("Cycle edges", proof.cycleEdges.map(String.init).joined(separator: ", "))
        if let progress = lastProgress {
            printKeyValue("Attempts", formatCount(progress.attempts))
            printKeyValue("Elapsed", formatSeconds(progress.totalTimeS))
            printKeyValue("Avg rate", String(format: "%.2f graphs/s", progress.graphsPerSecond))
        }
        print("Proof hex:")
        print(proof.serialized().map { String(format: "%02x", $0) }.joined())

    case .notFound:
        print("No proof found within attempt limit.")
        if let progress = lastProgress {
            printKeyValue("Attempts", formatCount(progress.attempts))
            printKeyValue("Elapsed", formatSeconds(progress.totalTimeS))
            printKeyValue("Avg rate", String(format: "%.2f graphs/s", progress.graphsPerSecond))
        } else if maxAttempts > 0 {
            printKeyValue("Attempts", formatCount(maxAttempts))
        }

    case .cancelled:
        print("Mining cancelled.")
    }
}

private func runBench(args: [String]) {
    let valueOptions: Set<String> = ["--graphs"]
    let flagOptions: Set<String> = ["--small", "--help", "-h"]

    let parsed: ParsedCommandArgs
    switch parseCommandArgs(args, valueOptions: valueOptions, flagOptions: flagOptions) {
    case .success(let p):
        parsed = p
    case .failure(let err):
        printError(err.text)
        printBenchUsage()
        exit(2)
    }

    if parsed.flags.contains("--help") || parsed.flags.contains("-h") {
        printBenchUsage()
        return
    }

    if !parsed.positionals.isEmpty {
        printError("Unexpected positional arguments: \(parsed.positionals.joined(separator: " "))")
        printBenchUsage()
        exit(2)
    }

    guard let graphs = parseIntOption(parsed, name: "--graphs", default: 5), graphs > 0 else {
        printError("--graphs must be greater than zero")
        exit(2)
    }

    let useSmall = parsed.flags.contains("--small")

    let params: MacChainParams = useSmall
        ? MacChainParams(
            scratchpadSize: 1_048_576,
            numEdges: 1 << 16,
            numNodes: 1 << 15,
            nodeMask: 0x7FFF,
            matrixDim: 8,
            trimRounds: 40
        )
        : .default

    print("MacChain Benchmark")
    print("------------------")
    printKeyValue("Graphs", formatCount(graphs))
    printKeyValue("Profile", useSmall ? "small" : "default")
    printKeyValue("Scratchpad", "\(params.scratchpadSize / 1_048_576) MB")
    printKeyValue("Edges", formatCount(params.numEdges))
    printKeyValue("Nodes/partition", formatCount(params.numNodes))
    printKeyValue("Matrix", "\(params.matrixDim)x\(params.matrixDim)")
    printKeyValue("Trim rounds", formatCount(params.trimRounds))

    let edgeGen = EdgeGenerator(params: params)
    let headerData = BlockHeader().serialized()

    var phase1Times: [Double] = []
    var phase2Times: [Double] = []
    var phase3Times: [Double] = []
    var totalTimes: [Double] = []
    var cyclesFound = 0

    let trimmer: Trimmer?
    do {
        trimmer = try Trimmer(params: params)
        printKeyValue("Trimmer", "Metal GPU")
    } catch {
        trimmer = nil
        printKeyValue("Trimmer", "CPU fallback")
    }

    print("")
    print("Graph   Phase1(ms)  Phase2(ms)  Phase3(ms)   Total(ms)   Surviving  Cycle")
    print("-----   ----------  ----------  ----------   ---------   ---------  -----")

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

        print(String(
            format: "%5d   %10.1f  %10.1f  %10.1f   %9.1f   %9d  %@",
            i,
            p1Time,
            p2Time,
            p3Time,
            totalTime,
            surviving.count,
            cycle != nil ? "yes" : "no"
        ))
    }

    func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    let avgTotal = average(totalTimes)
    let gps = avgTotal > 0 ? 1000.0 / avgTotal : 0

    print("")
    print("Summary")
    print("-------")
    printKeyValue("Avg phase1", String(format: "%.1f ms", average(phase1Times)))
    printKeyValue("Avg phase2", String(format: "%.1f ms", average(phase2Times)))
    printKeyValue("Avg phase3", String(format: "%.1f ms", average(phase3Times)))
    printKeyValue("Avg total", String(format: "%.1f ms", avgTotal))
    printKeyValue("Throughput", String(format: "%.3f graphs/s", gps))
    printKeyValue("Cycles found", "\(cyclesFound)/\(graphs)")
}

private func runVerify(args: [String]) {
    let valueOptions: Set<String> = ["--proof"]
    let flagOptions: Set<String> = ["--full", "--help", "-h"]

    let parsed: ParsedCommandArgs
    switch parseCommandArgs(args, valueOptions: valueOptions, flagOptions: flagOptions) {
    case .success(let p):
        parsed = p
    case .failure(let err):
        printError(err.text)
        printVerifyUsage()
        exit(2)
    }

    if parsed.flags.contains("--help") || parsed.flags.contains("-h") {
        printVerifyUsage()
        return
    }

    guard parsed.positionals.count <= 1 else {
        printError("verify accepts at most one positional proof value")
        printVerifyUsage()
        exit(2)
    }

    let proofHex = parsed.values["--proof"] ?? parsed.positionals.first ?? ""
    guard !proofHex.isEmpty else {
        printError("Missing proof. Provide --proof <hex> or positional <hex>.")
        printVerifyUsage()
        exit(2)
    }

    guard let proofData = Data(hexString: proofHex) else {
        printError("Invalid hex proof string")
        exit(2)
    }

    guard let proof = MacChainProof.deserialize(from: proofData) else {
        printError("Could not deserialize proof (expected at least 120 bytes)")
        exit(2)
    }

    let fullCheck = parsed.flags.contains("--full")
    let verifier = Verifier()
    let result = fullCheck ? verifier.verify(proof) : verifier.verifyCycleOnly(proof)

    print("MacChain Proof Verification")
    print("---------------------------")
    printKeyValue("Mode", fullCheck ? "full (includes difficulty)" : "cycle-only")
    printKeyValue("Nonce", formatCount(proof.nonce))
    printKeyValue("Cycle edges", proof.cycleEdges.map(String.init).joined(separator: ", "))

    switch result {
    case .valid:
        print("Result: VALID")
    case .invalid(let reason):
        print("Result: INVALID")
        printKeyValue("Reason", reason)
        exit(1)
    }
}

private func cpuTrim(edges: [Edge], params: MacChainParams) -> [Int] {
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

private extension Data {
    init?(hexString: String) {
        let hex = hexString.hasPrefix("0x") ? String(hexString.dropFirst(2)) : hexString
        guard hex.count % 2 == 0 else { return nil }

        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}

// MARK: - Entry

let args = Array(CommandLine.arguments.dropFirst())

if args.isEmpty {
    printMainUsage()
    exit(0)
}

let command = args[0]
let commandArgs = Array(args.dropFirst())

switch command {
case "mine":
    runMine(args: commandArgs)
case "bench":
    runBench(args: commandArgs)
case "verify":
    runVerify(args: commandArgs)
case "help", "--help", "-h":
    if let topic = commandArgs.first {
        switch topic {
        case "mine": printMineUsage()
        case "bench": printBenchUsage()
        case "verify": printVerifyUsage()
        default:
            printError("Unknown help topic '\(topic)'")
            printMainUsage()
            exit(1)
        }
    } else {
        printMainUsage()
    }
case "--version", "version":
    print("\(appName) \(cliVersion)")
default:
    printError("Unknown command '\(command)'")
    printMainUsage()
    exit(1)
}

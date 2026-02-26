import Foundation
import MacChainLib

let args = Array(CommandLine.arguments.dropFirst())

func parseOpt(_ name: String, default d: String) -> String {
    guard let idx = args.firstIndex(of: name), idx + 1 < args.count else { return d }
    return args[idx + 1]
}

let graphCount = Int(parseOpt("--graphs", default: "3")) ?? 3
let small = args.contains("--small")

let params: MacChainParams
if small {
    params = MacChainParams(
        scratchpadSize: 1_048_576,
        numEdges: 1 << 16,
        numNodes: 1 << 15,
        nodeMask: 0x7FFF,
        matrixDim: 8,
        trimRounds: 40
    )
    print("Using SMALL parameters (for testing)")
} else {
    params = .default
    print("Using DEFAULT parameters")
}

print("  Scratchpad: \(params.scratchpadSize / 1_048_576) MB")
print("  Edges: \(params.numEdges)")
print("  Nodes per partition: \(params.numNodes)")
print("  Matrix: \(params.matrixDim)x\(params.matrixDim)")
print("  Trim rounds: \(params.trimRounds)")
print("")

let edgeGen = EdgeGenerator(params: params)
let header = BlockHeader().serialized()

for i in 0..<graphCount {
    let nonce = UInt64(i)
    let start = CFAbsoluteTimeGetCurrent()
    let edges = edgeGen.generateEdges(blockHeader: header, nonce: nonce)
    let p1 = (CFAbsoluteTimeGetCurrent() - start) * 1000

    let t2Start = CFAbsoluteTimeGetCurrent()
    var alive = [Bool](repeating: true, count: edges.count)
    var degU = [UInt32: Int]()
    var degV = [UInt32: Int]()
    for e in edges { degU[e.u, default: 0] += 1; degV[e.v, default: 0] += 1 }
    for _ in 0..<params.trimRounds {
        for (j, e) in edges.enumerated() where alive[j] {
            if (degU[e.u] ?? 0) <= 1 { alive[j] = false; degU[e.u, default: 0] -= 1; degV[e.v, default: 0] -= 1 }
        }
        for (j, e) in edges.enumerated() where alive[j] {
            if (degV[e.v] ?? 0) <= 1 { alive[j] = false; degU[e.u, default: 0] -= 1; degV[e.v, default: 0] -= 1 }
        }
    }
    let surviving = (0..<edges.count).filter { alive[$0] }
    let p2 = (CFAbsoluteTimeGetCurrent() - t2Start) * 1000

    let t3Start = CFAbsoluteTimeGetCurrent()
    let cycle = CycleFinder.findCycle(edges: surviving.map { edges[$0] }, survivingIndices: surviving)
    let p3 = (CFAbsoluteTimeGetCurrent() - t3Start) * 1000

    let total = (CFAbsoluteTimeGetCurrent() - start) * 1000
    print(String(format: "Graph %d: p1=%.0fms p2=%.0fms p3=%.0fms total=%.0fms surviving=%d cycle=%@",
                 i, p1, p2, p3, total, surviving.count, cycle != nil ? "yes" : "no"))
}

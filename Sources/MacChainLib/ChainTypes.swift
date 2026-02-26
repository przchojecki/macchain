import Foundation
import CryptoKit

public struct TransactionInput: Equatable, Hashable {
    public var prevTxID: Data      // 32 bytes
    public var outputIndex: UInt32
    public var unlockingScript: Data

    public init(prevTxID: Data, outputIndex: UInt32, unlockingScript: Data) {
        self.prevTxID = normalize32(prevTxID)
        self.outputIndex = outputIndex
        self.unlockingScript = unlockingScript
    }

    public var outPoint: OutPoint {
        OutPoint(txID: prevTxID, outputIndex: outputIndex)
    }
}

public struct TransactionOutput: Equatable, Hashable {
    public var value: UInt64
    public var lockingScript: Data

    public init(value: UInt64, lockingScript: Data) {
        self.value = value
        self.lockingScript = lockingScript
    }
}

public struct Transaction: Equatable, Hashable {
    public var version: UInt32
    public var inputs: [TransactionInput]
    public var outputs: [TransactionOutput]
    public var lockTime: UInt32

    public init(
        version: UInt32 = 1,
        inputs: [TransactionInput],
        outputs: [TransactionOutput],
        lockTime: UInt32 = 0
    ) {
        self.version = version
        self.inputs = inputs
        self.outputs = outputs
        self.lockTime = lockTime
    }

    public var txID: Data {
        Data(SHA256.hash(data: serialized()))
    }

    public func serialized() -> Data {
        var out = Data()
        out.appendUInt32LE(version)
        out.appendUInt32LE(UInt32(inputs.count))

        for input in inputs {
            out.append(normalize32(input.prevTxID))
            out.appendUInt32LE(input.outputIndex)
            out.appendUInt32LE(UInt32(input.unlockingScript.count))
            out.append(input.unlockingScript)
        }

        out.appendUInt32LE(UInt32(outputs.count))
        for output in outputs {
            out.appendUInt64LE(output.value)
            out.appendUInt32LE(UInt32(output.lockingScript.count))
            out.append(output.lockingScript)
        }

        out.appendUInt32LE(lockTime)
        return out
    }

    public static func deserialize(from data: Data) -> Transaction? {
        var reader = BinaryReader(data: data)
        guard let version = reader.readUInt32() else { return nil }
        guard let inputCountU32 = reader.readUInt32() else { return nil }
        let inputCount = Int(inputCountU32)

        var inputs: [TransactionInput] = []
        inputs.reserveCapacity(inputCount)
        for _ in 0..<inputCount {
            guard let prevTxID = reader.readData(count: 32),
                  let outputIndex = reader.readUInt32(),
                  let scriptLength = reader.readUInt32(),
                  let script = reader.readData(count: Int(scriptLength)) else {
                return nil
            }
            inputs.append(TransactionInput(
                prevTxID: prevTxID,
                outputIndex: outputIndex,
                unlockingScript: script
            ))
        }

        guard let outputCountU32 = reader.readUInt32() else { return nil }
        let outputCount = Int(outputCountU32)

        var outputs: [TransactionOutput] = []
        outputs.reserveCapacity(outputCount)
        for _ in 0..<outputCount {
            guard let value = reader.readUInt64(),
                  let scriptLength = reader.readUInt32(),
                  let script = reader.readData(count: Int(scriptLength)) else {
                return nil
            }
            outputs.append(TransactionOutput(value: value, lockingScript: script))
        }

        guard let lockTime = reader.readUInt32() else { return nil }
        guard reader.remaining == 0 else { return nil }

        return Transaction(
            version: version,
            inputs: inputs,
            outputs: outputs,
            lockTime: lockTime
        )
    }

    public func isStructurallyValid(
        maxInputs: Int = 10_000,
        maxOutputs: Int = 10_000,
        maxScriptBytes: Int = 10_000
    ) -> Bool {
        guard !outputs.isEmpty else { return false }
        guard inputs.count <= maxInputs, outputs.count <= maxOutputs else { return false }

        var totalOut: UInt64 = 0
        for input in inputs where input.unlockingScript.count > maxScriptBytes {
            return false
        }
        for output in outputs {
            guard output.lockingScript.count <= maxScriptBytes else { return false }
            let (sum, overflow) = totalOut.addingReportingOverflow(output.value)
            guard !overflow else { return false }
            totalOut = sum
        }
        return true
    }

    /// Transaction preimage used for signature generation/verification.
    /// All unlocking scripts are blanked to avoid circular signing.
    public func signaturePreimage(inputIndex: Int) -> Data? {
        guard inputIndex >= 0, inputIndex < inputs.count else { return nil }

        var copy = self
        for idx in copy.inputs.indices {
            copy.inputs[idx].unlockingScript = Data()
        }

        var preimage = copy.serialized()
        preimage.appendUInt32LE(UInt32(inputIndex))
        return preimage
    }

    /// Sign an input against a previous output script.
    /// Currently supports only Ed25519 pay-to-public-key scripts.
    @discardableResult
    public mutating func signInput(
        at inputIndex: Int,
        privateKey: Curve25519.Signing.PrivateKey,
        previousOutput: TransactionOutput
    ) -> Bool {
        guard inputIndex >= 0, inputIndex < inputs.count else { return false }
        guard let lockingKey = TxScript.parsePayToEd25519(previousOutput.lockingScript) else {
            return false
        }
        guard lockingKey == privateKey.publicKey.rawRepresentation else {
            return false
        }
        guard let preimage = signaturePreimage(inputIndex: inputIndex),
              let signature = try? privateKey.signature(for: preimage) else {
            return false
        }

        inputs[inputIndex].unlockingScript = TxScript.makeEd25519UnlockingScript(signature: signature)
        return true
    }

    /// Verify input signature against a previous output script.
    public func verifyInputSignature(
        inputIndex: Int,
        previousOutput: TransactionOutput
    ) -> Bool {
        guard inputIndex >= 0, inputIndex < inputs.count else { return false }
        guard let pubKeyData = TxScript.parsePayToEd25519(previousOutput.lockingScript),
              let signature = TxScript.parseEd25519UnlockingScript(inputs[inputIndex].unlockingScript),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: pubKeyData),
              let preimage = signaturePreimage(inputIndex: inputIndex) else {
            return false
        }

        return publicKey.isValidSignature(signature, for: preimage)
    }

    public var isCoinbase: Bool {
        guard inputs.count == 1 else { return false }
        let input = inputs[0]
        return input.prevTxID == Data(repeating: 0, count: 32) &&
               input.outputIndex == UInt32.max
    }

    public static func coinbase(height: UInt64, value: UInt64, to lockingScript: Data) -> Transaction {
        var heightBytes = Data()
        heightBytes.appendUInt64LE(height)

        let input = TransactionInput(
            prevTxID: Data(repeating: 0, count: 32),
            outputIndex: UInt32.max,
            unlockingScript: heightBytes
        )
        let output = TransactionOutput(value: value, lockingScript: lockingScript)
        return Transaction(inputs: [input], outputs: [output])
    }
}

public struct OutPoint: Equatable, Hashable {
    public var txID: Data
    public var outputIndex: UInt32

    public init(txID: Data, outputIndex: UInt32) {
        self.txID = normalize32(txID)
        self.outputIndex = outputIndex
    }
}

public struct Block {
    public var header: BlockHeader
    public var proof: MacChainProof
    public var transactions: [Transaction]

    public init(header: BlockHeader, proof: MacChainProof, transactions: [Transaction]) {
        self.header = header
        self.proof = proof
        self.transactions = transactions
    }

    /// Hash used as block identifier in chainstate/fork-choice.
    public var blockHash: Data {
        Data(SHA256.hash(data: header.serialized()))
    }

    public func serialized() -> Data {
        var out = Data()
        out.append(header.serialized())

        let proofData = proof.serialized()
        out.appendUInt32LE(UInt32(proofData.count))
        out.append(proofData)

        out.appendUInt32LE(UInt32(transactions.count))
        for tx in transactions {
            let txData = tx.serialized()
            out.appendUInt32LE(UInt32(txData.count))
            out.append(txData)
        }

        return out
    }

    public static func deserialize(from data: Data) -> Block? {
        var reader = BinaryReader(data: data)

        guard let headerData = reader.readData(count: 80),
              let header = BlockHeader.deserialize(from: headerData),
              let proofLen = reader.readUInt32(),
              let proofData = reader.readData(count: Int(proofLen)),
              let proof = MacChainProof.deserialize(from: proofData),
              let txCount = reader.readUInt32() else {
            return nil
        }

        var transactions: [Transaction] = []
        transactions.reserveCapacity(Int(txCount))
        for _ in 0..<txCount {
            guard let txLen = reader.readUInt32(),
                  let txData = reader.readData(count: Int(txLen)),
                  let tx = Transaction.deserialize(from: txData) else {
                return nil
            }
            transactions.append(tx)
        }

        guard reader.remaining == 0 else { return nil }

        return Block(header: header, proof: proof, transactions: transactions)
    }

    public func computedMerkleRoot() -> Data {
        Block.merkleRoot(for: transactions)
    }

    public func hasValidMerkleRoot() -> Bool {
        normalize32(header.merkleRoot) == computedMerkleRoot()
    }

    public func isProofHeaderConsistent() -> Bool {
        proof.blockHeader == header.serialized()
    }

    public static func merkleRoot(for transactions: [Transaction]) -> Data {
        guard !transactions.isEmpty else {
            return Data(repeating: 0, count: 32)
        }

        var level: [Data] = transactions.map(\.txID)
        while level.count > 1 {
            var next: [Data] = []
            next.reserveCapacity((level.count + 1) / 2)

            var i = 0
            while i < level.count {
                let left = level[i]
                let right = i + 1 < level.count ? level[i + 1] : left
                var pair = Data()
                pair.append(left)
                pair.append(right)
                next.append(Data(SHA256.hash(data: pair)))
                i += 2
            }

            level = next
        }

        return normalize32(level[0])
    }
}

public extension BlockHeader {
    static func deserialize(from data: Data) -> BlockHeader? {
        guard data.count >= 80 else { return nil }

        let version = readUInt32LE(data, at: 0)
        let prevHash = Data(data[4..<36])
        let merkleRoot = Data(data[36..<68])
        let timestamp = readUInt32LE(data, at: 68)
        let bits = readUInt32LE(data, at: 72)

        return BlockHeader(
            prevHash: prevHash,
            merkleRoot: merkleRoot,
            timestamp: timestamp,
            bits: bits,
            version: version
        )
    }
}

private struct BinaryReader {
    private let data: Data
    private(set) var offset: Int = 0

    init(data: Data) {
        self.data = data
    }

    var remaining: Int {
        data.count - offset
    }

    mutating func readData(count: Int) -> Data? {
        guard count >= 0, offset + count <= data.count else { return nil }
        let out = Data(data[offset..<(offset + count)])
        offset += count
        return out
    }

    mutating func readUInt32() -> UInt32? {
        guard let bytes = readData(count: 4) else { return nil }
        return readUInt32LE(bytes, at: 0)
    }

    mutating func readUInt64() -> UInt64? {
        guard let bytes = readData(count: 8) else { return nil }
        return readUInt64LE(bytes, at: 0)
    }
}

private extension Data {
    mutating func appendUInt32LE(_ value: UInt32) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    mutating func appendUInt64LE(_ value: UInt64) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}

private func normalize32(_ data: Data) -> Data {
    var out = Data(data.prefix(32))
    if out.count < 32 {
        out.append(Data(repeating: 0, count: 32 - out.count))
    }
    return out
}

private func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
    let b0 = UInt32(data[offset])
    let b1 = UInt32(data[offset + 1]) << 8
    let b2 = UInt32(data[offset + 2]) << 16
    let b3 = UInt32(data[offset + 3]) << 24
    return b0 | b1 | b2 | b3
}

private func readUInt64LE(_ data: Data, at offset: Int) -> UInt64 {
    var value: UInt64 = 0
    for i in 0..<8 {
        value |= UInt64(data[offset + i]) << UInt64(i * 8)
    }
    return value
}

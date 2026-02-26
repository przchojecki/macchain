import Foundation

/// Minimal script templates for transaction authorization.
/// Current supported template:
/// - Pay-to-Ed25519-public-key (locking script)
/// - Ed25519 signature blob (unlocking script)
public enum TxScript {
    private static let p2Ed25519Tag: UInt8 = 0x01
    private static let ed25519PublicKeyLength = 32
    private static let ed25519SignatureLength = 64

    public static func makePayToEd25519(publicKey: Data) -> Data {
        var script = Data([p2Ed25519Tag])
        script.append(publicKey.prefix(ed25519PublicKeyLength))
        if publicKey.count < ed25519PublicKeyLength {
            script.append(Data(repeating: 0, count: ed25519PublicKeyLength - publicKey.count))
        }
        return script
    }

    public static func parsePayToEd25519(_ script: Data) -> Data? {
        guard script.count == ed25519PublicKeyLength + 1 else { return nil }
        guard script.first == p2Ed25519Tag else { return nil }
        return Data(script.dropFirst())
    }

    public static func makeEd25519UnlockingScript(signature: Data) -> Data {
        var script = Data(signature.prefix(ed25519SignatureLength))
        if signature.count < ed25519SignatureLength {
            script.append(Data(repeating: 0, count: ed25519SignatureLength - signature.count))
        }
        return script
    }

    public static func parseEd25519UnlockingScript(_ script: Data) -> Data? {
        guard script.count == ed25519SignatureLength else { return nil }
        return script
    }
}

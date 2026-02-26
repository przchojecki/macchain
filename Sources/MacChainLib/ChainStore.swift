import Foundation

struct FileBlockStore {
    private let baseURL: URL
    private let blocksURL: URL
    private let metaURL: URL
    private let fileManager = FileManager.default

    init(baseURL: URL) throws {
        self.baseURL = baseURL.standardizedFileURL
        self.blocksURL = self.baseURL.appendingPathComponent("blocks", isDirectory: true)
        self.metaURL = self.baseURL.appendingPathComponent("meta.json", isDirectory: false)

        try fileManager.createDirectory(at: self.baseURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: blocksURL, withIntermediateDirectories: true)
    }

    func loadBlocks() throws -> [Block] {
        let urls = try fileManager.contentsOfDirectory(
            at: blocksURL,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "blk" }

        var blocks: [Block] = []
        blocks.reserveCapacity(urls.count)

        for url in urls {
            let data = try Data(contentsOf: url)
            guard let block = Block.deserialize(from: data) else {
                throw NSError(
                    domain: "MacChain.ChainStore",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to decode block file \(url.lastPathComponent)"]
                )
            }
            blocks.append(block)
        }

        return blocks
    }

    func saveBlock(_ block: Block) throws {
        let hashHex = block.blockHash.hexString
        let url = blocksURL.appendingPathComponent("\(hashHex).blk")
        if fileManager.fileExists(atPath: url.path) {
            return
        }
        try block.serialized().write(to: url, options: .atomic)
    }

    func loadBestHash() throws -> Data? {
        guard fileManager.fileExists(atPath: metaURL.path) else { return nil }
        let data = try Data(contentsOf: metaURL)
        let meta = try JSONDecoder().decode(StoreMeta.self, from: data)
        return Data(hexString: meta.bestHashHex)
    }

    func saveBestHash(_ hash: Data) throws {
        let meta = StoreMeta(bestHashHex: hash.hexString)
        let data = try JSONEncoder().encode(meta)
        try data.write(to: metaURL, options: .atomic)
    }
}

private struct StoreMeta: Codable {
    let bestHashHex: String
}

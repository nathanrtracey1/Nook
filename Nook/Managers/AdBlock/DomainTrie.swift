import Foundation

/// A compact domain trie node used for fast suffix matching of hosts.
/// Example: to match `ads.example.com`, we traverse `com` → `example` → `ads`.
final class DomainTrieNode {
    var children: [String: DomainTrieNode] = [:]
    var isTerminal: Bool = false
}

/// Optional fast precheck for large domain sets.
/// This is a simple Bloom filter implementation tuned for host strings.
struct BloomFilter {
    private var bits: [UInt64]
    private let mask: Int

    init(bitCount: Int) {
        let size = max(1024, (bitCount + 63) / 64)
        self.bits = Array(repeating: 0, count: size)
        self.mask = (size * 64) - 1
    }

    mutating func insert(_ value: String) {
        let h1 = Self.fnv1a64(value)
        let h2 = Self.splitmix64(h1)
        setBit(Int(h1) & mask)
        setBit(Int(h2) & mask)
        setBit(Int(h1 ^ h2) & mask)
    }

    func mightContain(_ value: String) -> Bool {
        let h1 = Self.fnv1a64(value)
        let h2 = Self.splitmix64(h1)
        return getBit(Int(h1) & mask)
            && getBit(Int(h2) & mask)
            && getBit(Int(h1 ^ h2) & mask)
    }

    private mutating func setBit(_ i: Int) {
        let word = i >> 6
        let bit = UInt64(1) << UInt64(i & 63)
        bits[word] |= bit
    }

    private func getBit(_ i: Int) -> Bool {
        let word = i >> 6
        let bit = UInt64(1) << UInt64(i & 63)
        return (bits[word] & bit) != 0
    }

    private static func fnv1a64(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x100000001b3
        for b in s.utf8 {
            hash ^= UInt64(b)
            hash &*= prime
        }
        return hash
    }

    private static func splitmix64(_ x: UInt64) -> UInt64 {
        var z = x &+ 0x9e3779b97f4a7c15
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
}

/// The data layer for domain-based blocking decisions.
/// Ingests uBO-formatted domain rules like `||example.com^` into a trie.
struct NookDomainFilter {
    private let root: DomainTrieNode
    private let bloom: BloomFilter?

    init(domains: Set<String>) {
        let root = DomainTrieNode()

        var bloom: BloomFilter? = nil
        if domains.count >= 100_000 {
            var bf = BloomFilter(bitCount: domains.count * 12)
            for d in domains { bf.insert(d) }
            bloom = bf
        }

        for domain in domains {
            Self.insert(domain: domain, into: root)
        }

        self.root = root
        self.bloom = bloom
    }

    /// Returns true if the given host matches any terminal in the trie.
    func matches(host: String) -> Bool {
        let host = host.lowercased()
        if let bloom, !bloom.mightContain(host) {
            return false
        }

        let parts = host.split(separator: ".").map(String.init)
        if parts.isEmpty { return false }

        var node: DomainTrieNode? = root
        for part in parts.reversed() {
            node = node?.children[part]
            if node == nil { return false }
            if node?.isTerminal == true { return true }
        }
        return node?.isTerminal == true
    }

    private static func insert(domain: String, into root: DomainTrieNode) {
        let d = domain.lowercased()
        let parts = d.split(separator: ".").map(String.init)
        guard !parts.isEmpty else { return }
        var node = root
        for part in parts.reversed() {
            if let existing = node.children[part] {
                node = existing
            } else {
                let created = DomainTrieNode()
                node.children[part] = created
                node = created
            }
        }
        node.isTerminal = true
    }
}


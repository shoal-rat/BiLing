import Darwin
import Foundation

/// A character trie compiled by Tools/zhuoqin/build_tries.py and read straight
/// from a memory map. Two of them exist: 琴谱's words and 子期's vocabulary.
/// Both are walked against a KeyReader to find everything readable from a
/// key position.
public final class CharTrie: @unchecked Sendable {
    public enum Kind: UInt32, Sendable { case tokens = 0, words = 1 }

    public let kind: Kind
    public let syllables: SyllableTable
    public let nodeCount: Int
    public let entryCount: Int

    private let base: UnsafeRawPointer
    private let length: Int
    private let nodes: UnsafePointer<UInt32>
    private let entries: UnsafeRawPointer
    private let pool: UnsafePointer<UInt16>
    private let rootOffsets: UnsafePointer<UInt32>
    private let rootNodes: UnsafePointer<UInt32>
    private let strings: UnsafePointer<UInt8>
    private let latin: UnsafePointer<UInt32>
    public let latinCount: Int

    public enum LoadError: Error, CustomStringConvertible {
        case unreadable(String)
        case malformed(String)
        public var description: String {
            switch self {
            case .unreadable(let path): return "cannot read \(path)"
            case .malformed(let why): return "malformed trie: \(why)"
            }
        }
    }

    public init(path: String) throws {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw LoadError.unreadable(path) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size > 40 else { throw LoadError.unreadable(path) }
        let size = Int(info.st_size)
        guard let map = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0), map != MAP_FAILED else {
            throw LoadError.unreadable(path)
        }
        let base = UnsafeRawPointer(map)
        self.base = base
        length = size

        guard base.load(as: UInt32.self) == 0x5254_595A else { // "ZYTR"
            munmap(map, size)
            throw LoadError.malformed("bad magic")
        }
        let u32 = { (i: Int) -> Int in Int(base.load(fromByteOffset: 4 + 4 * i, as: UInt32.self)) }
        guard u32(0) == 1, let kind = Kind(rawValue: UInt32(u32(1))) else {
            munmap(map, size)
            throw LoadError.malformed("unsupported version")
        }
        self.kind = kind
        nodeCount = u32(2)
        entryCount = u32(3)
        let poolCount = u32(4)
        let stringBytes = u32(5)
        latinCount = u32(6)
        let syllableBytes = u32(7)

        var offset = 36
        let names = String(
            decoding: UnsafeRawBufferPointer(start: base + offset, count: syllableBytes),
            as: UTF8.self
        ).split(separator: "\n").map(String.init)
        syllables = SyllableTable(names: names)
        offset = (offset + syllableBytes + 3) & ~3
        nodes = (base + offset).assumingMemoryBound(to: UInt32.self)
        offset += nodeCount * 28
        entries = base + offset
        offset += entryCount * 8
        pool = (base + offset).assumingMemoryBound(to: UInt16.self)
        offset = (offset + poolCount * 2 + 3) & ~3
        rootOffsets = (base + offset).assumingMemoryBound(to: UInt32.self)
        offset += (names.count + 1) * 4
        let rootTotal = Int(rootOffsets[names.count])
        rootNodes = (base + offset).assumingMemoryBound(to: UInt32.self)
        offset += rootTotal * 4
        strings = (base + offset).assumingMemoryBound(to: UInt8.self)
        offset = (offset + stringBytes + 3) & ~3
        latin = (base + offset).assumingMemoryBound(to: UInt32.self)
        offset += latinCount * 8
        guard offset <= size else {
            munmap(map, size)
            throw LoadError.malformed("truncated (\(offset) > \(size))")
        }
    }

    deinit {
        munmap(UnsafeMutableRawPointer(mutating: base), length)
    }

    // MARK: - Node access

    @inline(__always) func field(_ node: Int, _ k: Int) -> Int { Int(nodes[node * 7 + k]) }
    @inline(__always) public func character(_ node: Int) -> UInt32 { nodes[node * 7] }

    @inline(__always) func readings(_ node: Int) -> UnsafeBufferPointer<UInt16> {
        UnsafeBufferPointer(start: pool + field(node, 5), count: field(node, 6))
    }

    @inline(__always) public func payload(_ entry: Int) -> UInt32 {
        entries.load(fromByteOffset: entry * 8, as: UInt32.self)
    }

    @inline(__always) public func logp(_ entry: Int) -> Float {
        entries.load(fromByteOffset: entry * 8 + 4, as: Float.self)
    }

    /// The text of a word entry (kind == .words).
    public func text(_ entry: Int) -> String {
        string(at: Int(payload(entry)))
    }

    func string(at offset: Int) -> String {
        let length = Int(strings[offset])
        return String(decoding: UnsafeBufferPointer(start: strings + offset + 1, count: length), as: UTF8.self)
    }

    // MARK: - Walking

    /// One readable item: an entry whose text can be read from `start` to `end`.
    public struct Match: Sendable {
        public let entry: Int32
        public let end: Int16
        public let chars: Int8
        /// Characters read by initial or prefix rather than spelled in full.
        public let abbreviated: Int8
    }

    /// Everything readable from key position p, at most `maxChars` characters.
    public func walk(_ reader: KeyReader, from p: Int, maxChars: Int = 8) -> [Match] {
        var out: [Match] = []
        let q = reader.skipSeparator(p)
        guard q < reader.count else { return out }
        var seen = Set<UInt32>()
        for sid in reader.startable[q] {
            let lo = Int(rootOffsets[Int(sid)])
            let hi = Int(rootOffsets[Int(sid) + 1])
            for k in lo..<hi {
                let node = rootNodes[k]
                guard seen.insert(node).inserted else { continue }
                visit(Int(node), reader, from: p, depth: 1, abbreviated: 0, maxChars: maxChars, into: &out)
            }
        }
        return out
    }

    private func visit(
        _ node: Int,
        _ reader: KeyReader,
        from p: Int,
        depth: Int,
        abbreviated: Int,
        maxChars: Int,
        into out: inout [Match]
    ) {
        let n = reader.count
        reader.forEachEnd(from: p, readings: readings(node)) { end, full in
            let abbr = abbreviated + (full ? 0 : 1)
            let first = field(node, 3)
            let count = field(node, 4)
            for e in first..<(first + count) {
                out.append(Match(entry: Int32(e), end: Int16(end), chars: Int8(depth), abbreviated: Int8(abbr)))
            }
            guard end < n, depth < maxChars else { return }
            let child = field(node, 1)
            let children = field(node, 2)
            // Nothing can start at `end` (e.g. after an initial, `i` or `u`
            // follows): no child can be read, skip the whole subtree.
            guard children > 0, !reader.startable[reader.skipSeparator(end)].isEmpty else { return }
            for c in child..<(child + children) {
                visit(c, reader, from: end, depth: depth + 1, abbreviated: abbr, maxChars: maxChars, into: &out)
            }
        }
    }

    /// Latin tokens spelled out at p: (token id, end).
    public func latinMatches(_ reader: KeyReader, from p: Int, maxLetters: Int = 16) -> [(UInt32, Int)] {
        guard latinCount > 0 else { return [] }
        let q = reader.skipSeparator(p)
        var out: [(UInt32, Int)] = []
        guard q < reader.count else { return out }
        let available = reader.count - q
        guard available >= 2 else { return out }
        // Every Latin entry that is a prefix of keys[q...]: binary search the
        // sorted table for each candidate length.
        for length in 2...min(maxLetters, available) {
            let key = Array(reader.keys[q..<(q + length)])
            guard !key.contains(KeyReader.apostrophe) else { break }
            var lo = 0
            var hi = latinCount
            while lo < hi {
                let mid = (lo + hi) / 2
                if compare(latinEntry(mid), key) < 0 { lo = mid + 1 } else { hi = mid }
            }
            var i = lo
            while i < latinCount, compare(latinEntry(i), key) == 0 {
                out.append((latin[i * 2 + 1], q + length))
                i += 1
            }
        }
        return out
    }

    private func latinEntry(_ i: Int) -> UnsafeBufferPointer<UInt8> {
        let offset = Int(latin[i * 2])
        return UnsafeBufferPointer(start: strings + offset + 1, count: Int(strings[offset]))
    }

    private func compare(_ a: UnsafeBufferPointer<UInt8>, _ b: [UInt8]) -> Int {
        let n = min(a.count, b.count)
        for i in 0..<n where a[i] != b[i] { return a[i] < b[i] ? -1 : 1 }
        return a.count == b.count ? 0 : (a.count < b.count ? -1 : 1)
    }
}

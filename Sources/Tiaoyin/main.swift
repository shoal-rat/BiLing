import Foundation
import ZhiyinCore
import ZhiyinListener

// 调音 · Tuning. The command-line instrument for checking 知音 by ear:
//
//   tiaoyin listen [--context 前文] keys…      子期's readings, with timing
//   tiaoyin score keys…                        琴谱's readings (no model)
//   tiaoyin eval corpus.tsv [--no-context] [--per-item out.tsv] [--limit N]
//   tiaoyin bench corpus.tsv                   per-keystroke latency, typed letter by letter
//
// Paths: --model, --vocab, --qinpu, or ZHIYIN_MODEL / ZHIYIN_DATA.

var arguments = Array(CommandLine.arguments.dropFirst())

func option(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
    let value = arguments[i + 1]
    arguments.removeSubrange(i...(i + 1))
    return value
}

func flag(_ name: String) -> Bool {
    guard let i = arguments.firstIndex(of: name) else { return false }
    arguments.remove(at: i)
    return true
}

let environment = ProcessInfo.processInfo.environment
let here = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
let bundledData = here.deletingLastPathComponent().appendingPathComponent("Resources/Data").path
let dataDirectory = option("--data") ?? environment["ZHIYIN_DATA"]
    ?? (FileManager.default.fileExists(atPath: bundledData) ? bundledData : "Resources/Data")
let modelPath = option("--model") ?? environment["ZHIYIN_MODEL"]
    ?? "\(dataDirectory)/../Models/ziqi-base.gguf"
let adapterPath = option("--adapter") ?? environment["ZHIYIN_ADAPTER"]
    ?? "\(dataDirectory)/../Models/ziqi-tingyin.gguf"
let zhiWeight = option("--zhi").flatMap(Float.init)
let tingWeight = option("--ting").flatMap(Float.init)
let perKey = option("--per-key").flatMap(Float.init)
let abbrCost = option("--abbr-cost").flatMap(Float.init)
let slipCost = option("--slip-cost").flatMap(Float.init)
let vocabPath = option("--vocab") ?? "\(dataDirectory)/ziqi-vocab.trie"
let qinpuPath = option("--qinpu") ?? "\(dataDirectory)/qinpu.trie"
let beam = option("--beam").flatMap(Int.init)
let reward = option("--reward").flatMap(Float.init)
let latinPenalty = option("--latin-penalty").flatMap(Float.init)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func loadZiqi() -> Ziqi {
    let hasAdapter = FileManager.default.fileExists(atPath: adapterPath) && adapterPath != "none"
    var config = hasAdapter ? Ziqi.Config() : Ziqi.Config.zhiOnly
    if let beam { config.beam = beam }
    if let perKey { config.perKey = perKey }
    if let latinPenalty { config.latinCost = latinPenalty }
    if let zhiWeight { config.zhiWeight = zhiWeight }
    if let tingWeight { config.tingWeight = tingWeight }
    if let abbrCost { config.abbreviationCost = abbrCost }
    if let slipCost { config.slipCost = slipCost }
    _ = reward
    do {
        let started = Date()
        let z = try Ziqi(modelPath: modelPath, adapterPath: hasAdapter ? adapterPath : nil, vocabularyPath: vocabPath, config: config)
        FileHandle.standardError.write(Data("子期: \(z.description), loaded in \(Int(Date().timeIntervalSince(started) * 1000)) ms\n".utf8))
        return z
    } catch {
        fail("\(error)")
    }
}

func loadQinpu() -> Qinpu {
    do { return try Qinpu(path: qinpuPath) } catch { fail("\(error)") }
}

struct Item {
    let category: String
    let context: String
    let keys: String
    let expected: String
}

func readCorpus(_ path: String) -> [Item] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("cannot read \(path)") }
    return text.split(separator: "\n").compactMap { line in
        if line.hasPrefix("#") || line.hasPrefix("category\t") { return nil }
        let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 4 else { return nil }
        return Item(category: f[0], context: f[1] == "-" ? "" : f[1], keys: f[2], expected: f[3])
    }
}

let command = arguments.isEmpty ? "help" : arguments.removeFirst()
let context = option("--context") ?? ""

switch command {
case "listen":
    let z = loadZiqi()
    for keys in arguments {
        // Warm once so timings show the steady state.
        guard let answer = z.listen(context: context, keys: keys) else { print("\(keys): (no answer)"); continue }
        let again = z.listen(context: context, keys: keys) ?? answer
        print("\(context.isEmpty ? "" : context + " | ")\(keys)  — \(String(format: "%.1f", answer.milliseconds)) ms cold, \(String(format: "%.1f", again.milliseconds)) ms warm (decode \(String(format: "%.1f", again.decodeMilliseconds)) ms), \(answer.steps) steps")
        for r in answer.results.prefix(8) {
            print(String(format: "  %7.2f  %@", r.logp, r.text))
        }
        print("  leads: " + answer.leads.prefix(10).map { "\($0.text)·\($0.end)" }.joined(separator: " "))
    }

case "score":
    let q = loadQinpu()
    for keys in arguments {
        let reader = KeyReader(keys, syllables: q.syllables)
        let started = DispatchTime.now()
        let sentences = q.decode(reader)
        let prefixes = q.prefixes(reader, limit: 12)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6
        print("\(keys)  — \(String(format: "%.2f", ms)) ms")
        for s in sentences { print(String(format: "  %7.2f  %@", s.logp, s.text)) }
        print("  prefixes: " + prefixes.map { "\($0.text)·\($0.end)" }.joined(separator: " "))
    }

case "eval":
    guard let path = arguments.first else { fail("usage: tiaoyin eval corpus.tsv") }
    let noContext = flag("--no-context")
    let engineOnly = flag("--engine-only")
    let perItem = option("--per-item")
    let limit = option("--limit").flatMap(Int.init) ?? Int.max
    let items = Array(readCorpus(path).prefix(limit))
    let q = loadQinpu()
    let z = engineOnly ? nil : loadZiqi()
    var rows: [String] = ["category\tcontext\tpinyin\texpected\tzhiyin\tcorrect\trank\tms"]
    struct Tally { var n = 0, top1 = 0, top5 = 0, covered = 0, ms: [Double] = [] }
    var tallies: [String: Tally] = [:]
    var total = Tally()
    for (index, item) in items.enumerated() {
        let ctx = noContext ? "" : item.context
        let started = DispatchTime.now()
        var ranked: [String] = []
        if let z, let answer = z.listen(context: ctx, keys: item.keys) {
            ranked = answer.results.map(\.text)
        }
        if ranked.isEmpty {
            ranked = q.decode(KeyReader(item.keys, syllables: q.syllables)).map(\.text)
        }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6
        let rank = ranked.firstIndex(of: item.expected)
        for key in [item.category, "*"] {
            var t = key == "*" ? total : (tallies[key] ?? Tally())
            t.n += 1
            if rank == 0 { t.top1 += 1 }
            if let rank, rank < 5 { t.top5 += 1 }
            if rank != nil { t.covered += 1 }
            t.ms.append(ms)
            if key == "*" { total = t } else { tallies[key] = t }
        }
        rows.append([item.category, item.context.isEmpty ? "-" : item.context, item.keys, item.expected,
                     ranked.first ?? "", rank == 0 ? "1" : "0", rank.map(String.init) ?? "-",
                     String(format: "%.1f", ms)].joined(separator: "\t"))
        if (index + 1) % 100 == 0 {
            FileHandle.standardError.write(Data("… \(index + 1)/\(items.count) top-1 \(String(format: "%.1f", 100 * Double(total.top1) / Double(total.n)))%\n".utf8))
        }
    }
    func line(_ name: String, _ t: Tally) -> String {
        let sorted = t.ms.sorted()
        let p50 = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, sorted.count * 95 / 100)]
        func pct(_ x: Int) -> String { String(format: "%5.1f%%", 100 * Double(x) / Double(max(1, t.n))) }
        return "\(name.padding(toLength: 14, withPad: " ", startingAt: 0)) n=\(String(t.n).padding(toLength: 5, withPad: " ", startingAt: 0)) top1 \(pct(t.top1))  top5 \(pct(t.top5))  covered \(pct(t.covered))  p50 \(String(format: "%.0f", p50))ms  p95 \(String(format: "%.0f", p95))ms"
    }
    for key in tallies.keys.sorted() { print(line(key, tallies[key]!)) }
    print(line("all", total))
    if let perItem { try? rows.joined(separator: "\n").write(toFile: perItem, atomically: true, encoding: .utf8) }

case "bench":
    guard let path = arguments.first else { fail("usage: tiaoyin bench corpus.tsv") }
    let limit = option("--limit").flatMap(Int.init) ?? 100
    let z = loadZiqi()
    var ms: [Double] = []
    var steps = 0
    var keystrokes = 0
    for item in readCorpus(path).prefix(limit) {
        var typed = ""
        for ch in item.keys {
            typed.append(ch)
            if let a = z.listen(context: item.context, keys: typed) {
                ms.append(a.milliseconds)
                steps += a.steps
            }
            keystrokes += 1
        }
    }
    ms.sort()
    func q(_ f: Double) -> Double { ms.isEmpty ? 0 : ms[min(ms.count - 1, Int(Double(ms.count) * f))] }
    print(String(format: "%d keystrokes  p50 %.1f ms  p90 %.1f ms  p99 %.1f ms  mean steps %.1f",
                 keystrokes, q(0.5), q(0.9), q(0.99), Double(steps) / Double(max(1, ms.count))))

default:
    print("""
    调音 tiaoyin — tune 知音 by ear
      listen [--context 前文] keys…
      score keys…
      eval corpus.tsv [--no-context] [--engine-only] [--per-item out.tsv] [--limit N]
      bench corpus.tsv [--limit N]
    options: --model path.gguf --vocab ziqi-vocab.trie --qinpu qinpu.trie --beam N --reward R
    """)
}

// Hidden: time the vocabulary walk alone, per key position.
if command == "probe" {
    let trie = try! CharTrie(path: vocabPath)
    for keys in arguments {
        let reader = KeyReader(keys, syllables: trie.syllables)
        var total = 0.0
        var counts: [Int] = []
        for p in 0..<reader.count {
            let t = DispatchTime.now()
            let m = trie.walk(reader, from: p, maxChars: 4)
            total += Double(DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1e6
            counts.append(m.count)
        }
        print("\(keys): walk total \(String(format: "%.2f", total)) ms, matches per position \(counts)")
    }
}

if command == "probe-score" {
    let q = loadQinpu()
    for keys in arguments {
        let reader = KeyReader(keys, syllables: q.syllables)
        func t(_ f: () -> Void) -> Double { let s = DispatchTime.now(); f(); return Double(DispatchTime.now().uptimeNanoseconds - s.uptimeNanoseconds) / 1e6 }
        var walk = 0.0, phr = 0.0
        for p in 0..<reader.count {
            walk += t { _ = q.trie.walk(reader, from: p) }
            phr += t { _ = q.phrases(reader, from: p) }
        }
        let lat = q.lattice(reader)
        let fill = t { for p in 0..<reader.count { _ = lat.phrases(from: p) } }
        let dec = t { _ = q.decode(lat) }
        let pre = t { _ = q.prefixes(lat) }
        print("\(keys): walk \(String(format: "%.2f", walk)) phrases \(String(format: "%.2f", phr)) fill \(String(format: "%.2f", fill)) decode \(String(format: "%.2f", dec)) prefixes \(String(format: "%.2f", pre))")
    }
}

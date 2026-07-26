import Foundation

/// Latin-script vocabulary for mixed Chinese–English typing.
///
/// Three layers answer queries:
/// 1. A curated table of everyday Latin-script vocabulary — tech and finance
///    terms, common English given names, and Chinese-internet initialisms —
///    each with its proper display form (`claude` → `Claude`, `ai` → `AI`,
///    `xswl` stays lowercase). It answers instantly and outranks the rest.
/// 2. The macOS system word list (`/usr/share/dict/words`), loaded and sorted
///    once on a background queue the first time the buffer stops looking like
///    pinyin. Filtered to lowercase 2–15 letter words, every entry fits
///    Swift's inline small-string storage, so ~200k words cost a few
///    megabytes and zero per-word heap allocations.
/// 3. Exact-key display lookup, so fully typed keys surface their canonical
///    casing even in an otherwise Chinese candidate list.
public final class EnglishLexicon: @unchecked Sendable {
    public static let shared = EnglishLexicon()

    /// Lowercase key → canonical display form. Keys must be pure a–z because
    /// the composition buffer only ever holds lowercase letters.
    private static let curatedEntries: [(key: String, display: String)] = [
        // Chinese-internet initialisms and loanwords (kept lowercase)
        ("awsl", "awsl"), ("bhys", "bhys"), ("buff", "buff"), ("cpdd", "cpdd"),
        ("ddl", "ddl"), ("emo", "emo"), ("flag", "flag"), ("gg", "gg"),
        ("hhh", "hhh"), ("hhhh", "hhhh"), ("nbcs", "nbcs"), ("nsdd", "nsdd"),
        ("ojbk", "ojbk"), ("plmm", "plmm"), ("pyq", "pyq"), ("srds", "srds"),
        ("tql", "tql"), ("xdm", "xdm"), ("xswl", "xswl"), ("yyds", "yyds"),
        ("yygq", "yygq"), ("zqsg", "zqsg"),
        // AI and companies
        ("agi", "AGI"), ("ai", "AI"), ("aigc", "AIGC"), ("anthropic", "Anthropic"),
        ("chatgpt", "ChatGPT"), ("claude", "Claude"), ("copilot", "Copilot"),
        ("deepseek", "DeepSeek"), ("gemini", "Gemini"), ("gpt", "GPT"),
        ("grok", "Grok"), ("kimi", "Kimi"), ("llama", "Llama"), ("llm", "LLM"),
        ("midjourney", "Midjourney"), ("nlp", "NLP"), ("ocr", "OCR"),
        ("openai", "OpenAI"), ("qwen", "Qwen"), ("rag", "RAG"),
        ("sora", "Sora"), ("token", "token"),
        // Tech terms and products
        ("api", "API"), ("app", "app"), ("apple", "Apple"), ("bug", "bug"),
        ("chrome", "Chrome"), ("cli", "CLI"), ("cloud", "cloud"),
        ("code", "code"), ("commit", "commit"), ("cpu", "CPU"), ("css", "CSS"),
        ("cuda", "CUDA"), ("debug", "debug"), ("demo", "demo"),
        ("docker", "Docker"), ("email", "email"), ("emoji", "emoji"),
        ("excel", "Excel"), ("figma", "Figma"), ("firefox", "Firefox"),
        ("git", "git"), ("github", "GitHub"), ("gitlab", "GitLab"),
        ("golang", "Golang"), ("google", "Google"), ("gpu", "GPU"),
        ("gui", "GUI"), ("html", "HTML"), ("http", "HTTP"), ("https", "HTTPS"),
        ("ide", "IDE"), ("ios", "iOS"), ("ipad", "iPad"), ("iphone", "iPhone"),
        ("java", "Java"), ("javascript", "JavaScript"), ("json", "JSON"),
        ("keynote", "Keynote"), ("kubernetes", "Kubernetes"),
        ("linux", "Linux"), ("macbook", "MacBook"), ("macos", "macOS"),
        ("markdown", "Markdown"), ("nas", "NAS"), ("nginx", "nginx"),
        ("node", "Node"), ("notion", "Notion"), ("npm", "npm"),
        ("office", "Office"), ("offer", "offer"), ("online", "online"),
        ("pdf", "PDF"), ("photoshop", "Photoshop"), ("ppt", "PPT"),
        ("python", "Python"), ("pytorch", "PyTorch"), ("ram", "RAM"),
        ("react", "React"), ("rust", "Rust"), ("safari", "Safari"),
        ("sdk", "SDK"), ("slack", "Slack"), ("sql", "SQL"), ("ssd", "SSD"),
        ("ssh", "SSH"), ("swift", "Swift"), ("terminal", "terminal"),
        ("test", "test"), ("typescript", "TypeScript"), ("ui", "UI"),
        ("update", "update"), ("url", "URL"), ("usb", "USB"), ("ux", "UX"),
        ("video", "video"), ("vim", "Vim"), ("vpn", "VPN"), ("vscode", "VS Code"),
        ("vue", "Vue"), ("wifi", "Wi-Fi"), ("windows", "Windows"),
        ("word", "Word"), ("xcode", "Xcode"), ("zoom", "Zoom"),
        // Business and finance
        ("btc", "BTC"), ("b2b", "B2B"), ("ceo", "CEO"), ("cfo", "CFO"),
        ("cpi", "CPI"), ("cto", "CTO"), ("defi", "DeFi"), ("esg", "ESG"),
        ("etf", "ETF"), ("eth", "ETH"), ("forex", "forex"), ("gdp", "GDP"),
        ("hr", "HR"), ("ipo", "IPO"), ("kpi", "KPI"), ("nft", "NFT"),
        ("okr", "OKR"), ("ppi", "PPI"), ("pr", "PR"), ("roi", "ROI"),
        ("vc", "VC"),
        // Common English given names
        ("alex", "Alex"), ("alice", "Alice"), ("amy", "Amy"), ("anna", "Anna"),
        ("ben", "Ben"), ("bob", "Bob"), ("chris", "Chris"), ("daniel", "Daniel"),
        ("david", "David"), ("emma", "Emma"), ("eric", "Eric"),
        ("frank", "Frank"), ("grace", "Grace"), ("helen", "Helen"),
        ("henry", "Henry"), ("jack", "Jack"), ("james", "James"),
        ("jane", "Jane"), ("jason", "Jason"), ("jerry", "Jerry"),
        ("jessica", "Jessica"), ("john", "John"), ("kevin", "Kevin"),
        ("leo", "Leo"), ("lily", "Lily"), ("linda", "Linda"), ("lisa", "Lisa"),
        ("lucas", "Lucas"), ("lucy", "Lucy"), ("mark", "Mark"),
        ("mary", "Mary"), ("mike", "Mike"), ("nancy", "Nancy"),
        ("oscar", "Oscar"), ("paul", "Paul"), ("peter", "Peter"),
        ("rose", "Rose"), ("sam", "Sam"), ("sarah", "Sarah"),
        ("tom", "Tom"), ("tony", "Tony"), ("victor", "Victor"),
        ("wendy", "Wendy"),
    ]

    private let curatedByKey: [String: String]
    private let curatedKeysSorted: [String]

    private let lock = NSLock()
    private var systemWords: [String]?
    private var loadStarted = false

    public init() {
        var byKey: [String: String] = [:]
        for entry in Self.curatedEntries {
            byKey[entry.key] = entry.display
        }
        curatedByKey = byKey
        curatedKeysSorted = byKey.keys.sorted()
    }

    /// Canonical display form when `key` exactly matches a curated entry
    /// (`claude` → `Claude`, `gdp` → `GDP`). Nil otherwise.
    public func exactDisplay(for key: String) -> String? {
        curatedByKey[key]
    }

    /// Ranked completions for `prefix`: curated entries first (shortest key
    /// first), then the shortest system words. Empty below two letters.
    public func completions(for prefix: String, limit: Int) -> [String] {
        guard prefix.count >= 2, prefix.allSatisfy({ $0.isASCII && $0.isLowercase && $0.isLetter }) else {
            return []
        }
        var seenKeys: Set<String> = []
        var output: [String] = []
        for key in curatedKeysSorted where key.hasPrefix(prefix) && key != prefix {
            if seenKeys.insert(key).inserted, let display = curatedByKey[key] {
                output.append(display)
            }
            if output.count >= limit { return output }
        }
        output.sort { $0.count < $1.count }

        guard let words = snapshotSystemWords() else {
            beginLoadingIfNeeded()
            return output
        }
        var matches: [String] = []
        var index = lowerBound(of: prefix, in: words)
        while index < words.count, words[index].hasPrefix(prefix), matches.count < 4_096 {
            let word = words[index]
            if word != prefix && !seenKeys.contains(word) {
                matches.append(word)
            }
            index += 1
        }
        matches.sort {
            if $0.count != $1.count { return $0.count < $1.count }
            return $0 < $1
        }
        output.append(contentsOf: matches.prefix(max(0, limit - output.count)))
        return output
    }

    public func bestCompletion(for prefix: String) -> String? {
        completions(for: prefix, limit: 1).first
    }

    /// Curated-table-only lookup, for callers that must not surface obscure
    /// system words (for example, tails that also parse as valid pinyin).
    public func curatedCompletion(for prefix: String) -> String? {
        guard prefix.count >= 2 else { return nil }
        if let exact = curatedByKey[prefix] { return exact }
        for key in curatedKeysSorted where key.hasPrefix(prefix) {
            return curatedByKey[key]
        }
        return nil
    }

    private func snapshotSystemWords() -> [String]? {
        lock.lock()
        defer { lock.unlock() }
        return systemWords
    }

    private func beginLoadingIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !loadStarted else { return }
        loadStarted = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let loaded = Self.loadSystemWords()
            guard let self else { return }
            self.lock.lock()
            self.systemWords = loaded
            self.lock.unlock()
        }
    }

    private static func loadSystemWords() -> [String] {
        guard let raw = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else {
            return []
        }
        var unique: Set<String> = []
        unique.reserveCapacity(220_000)
        for line in raw.split(separator: "\n") {
            guard line.count >= 2, line.count <= 15,
                  line.allSatisfy({ $0.isASCII && $0.isLowercase && $0.isLetter }) else {
                continue
            }
            unique.insert(String(line))
        }
        return unique.sorted()
    }

    private func lowerBound(of prefix: String, in words: [String]) -> Int {
        var low = 0
        var high = words.count
        while low < high {
            let middle = (low + high) / 2
            if words[middle] < prefix {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }
}

import Foundation
import Testing

@testable import BackboneEngine

/// Decides which lexicon this test run is about to load, so suites frozen
/// against the full production database can skip themselves anywhere it is
/// not really present — most importantly on CI, which checks out without Git
/// LFS and leaves an ASCII pointer file where the lexicon should be.
enum TestLexicon {
    /// The small checked-in lexicon built by scripts/build_fixture_lexicon.py.
    /// Located through the source tree rather than a resource bundle so the
    /// same file the repository versions is the file under test.
    static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // BackboneEngineTests
        .deletingLastPathComponent() // Tests
        .appendingPathComponent("Fixtures/fixture-lexicon.sqlite3")

    /// True when `DictTrie.bundled()` will load the full production lexicon.
    ///
    /// The check mirrors `bundled()`'s resolution order (BILING_LEXICON_PATH
    /// first, then the module bundle) and judges the file without opening it:
    /// it must begin with the SQLite magic — a Git LFS pointer file is ASCII
    /// text, so this is what detects an `lfs: false` checkout as "absent" —
    /// and be at least 32 MB, which the production database exceeds by an
    /// order of magnitude and the CI fixture never approaches.
    static let realLexiconAvailable: Bool = {
        guard let url = DictTrie.resolvedLexiconURL(),
              url.pathExtension == "sqlite3" else { return false }
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 16),
              header == Data("SQLite format 3\0".utf8) else { return false }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        return size >= 32 * 1024 * 1024
    }()
}

extension Trait where Self == ConditionTrait {
    /// Gate for suites whose expectations were recorded against the real
    /// 1.4M-entry lexicon; against anything smaller they measure nothing.
    static var requiresRealLexicon: Self {
        .enabled(
            if: TestLexicon.realLexiconAvailable,
            "Needs the full production lexicon: run `git lfs pull`, or set BILING_LEXICON_PATH to a full database."
        )
    }
}

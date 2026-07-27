import Foundation

/// One scale for every candidate, so scores from different sources can be
/// compared instead of merely coexisting.
///
/// Everything is a log-probability under the same generative story: the user
/// chose a sequence of words and typed each one in some form.
///
///     score(path) = Σᵢ [ log P(wordᵢ) + log P(formᵢ) ]
///
/// `log P(word)` is the word's corpus frequency divided by the corpus total,
/// and `log P(form)` is how often people spell a word out rather than
/// abbreviate it. Three things fall out that the previous additive-bonus
/// scoring had to fake with hand-set constants:
///
/// * **Fewer segments win.** Each extra segment adds another `−log(total)`,
///   so 北京 + 还有 beats 被 + 尽管 + 还有 with no rule saying so.
/// * **Abbreviation is a fallback.** An abbreviated segment pays the log-odds
///   of abbreviating, so a spelled-out reading wins whenever one exists — and
///   an abbreviated reading still beats no reading at all.
/// * **Latin words compete on equal terms.** They enter through the same
///   unigram model via a pseudo-frequency, instead of an absolute probability
///   that silently outranked every Chinese word.
///
/// Path scores are *not* divided by segment count. A sum of log-probabilities
/// is already the probability of the whole path; averaging it would destroy
/// precisely the length preference that makes segmentation work.
public enum ScoreModel {
    /// How the user typed a word. These are usage priors, not measured rates;
    /// what matters is their order and rough spacing.
    public enum TypingForm {
        /// Every syllable spelled out: `beijing` → 北京.
        case full
        /// First syllable spelled out, the rest as initials: `meiy` → 没有.
        case mixed
        /// Initials only: `dx` → 大学.
        case initials

        var logProbability: Double {
            switch self {
            case .full: log(0.80)
            case .mixed: log(0.13)
            case .initials: log(0.07)
            }
        }
    }

    /// Latin vocabulary has no corpus counts, so it enters the same unigram
    /// model through a stand-in frequency. The values are chosen relative to
    /// real Chinese counts: a term the user spelled out in full is about as
    /// likely as a moderately common word, a curated expansion less so, and a
    /// guess from the system dictionary rare enough that it cannot outbid a
    /// genuine Chinese reading of the same letters.
    public enum LatinEvidence {
        /// The letters spell a known term exactly (`economics`, `github`).
        case spelledOut
        /// Expanded from a curated table (`vs` → VS Code).
        case curatedExpansion
        /// Completed from the system word list — a weak guess.
        case guessedExpansion

        var pseudoWeight: Double {
            switch self {
            case .spelledOut: 20_000
            case .curatedExpansion: 6_000
            case .guessedExpansion: 300
            }
        }
    }

    /// Log-probability of a word given its raw corpus weight.
    public static func wordLogProbability(weight: Double, logTotalWeight: Double) -> Double {
        log(max(weight, 0.5)) - logTotalWeight
    }

    /// Cost of one segment written in `form`.
    public static func segmentLogProbability(
        weight: Double,
        logTotalWeight: Double,
        form: TypingForm
    ) -> Double {
        wordLogProbability(weight: weight, logTotalWeight: logTotalWeight)
            + form.logProbability
    }

    /// Cost of one Latin segment, on the same scale as a Chinese one.
    public static func latinLogProbability(
        _ evidence: LatinEvidence,
        logTotalWeight: Double
    ) -> Double {
        wordLogProbability(weight: evidence.pseudoWeight, logTotalWeight: logTotalWeight)
    }

    /// "The user meant the raw keystrokes."
    ///
    /// A prior on wanting Latin output at all, times a uniform model over the
    /// letters typed. The length term is what matters: it keeps the literal
    /// reachable for a short unparseable run while making it hopeless against
    /// a real reading of a long one — a fixed constant cannot do both.
    public static func literalLogProbability(length: Int) -> Double {
        log(0.005) + Double(length) * log(1.0 / 26.0)
    }

    /// The literal *is* the answer — an uppercase run, a URL, an email — so it
    /// pays no length cost.
    public static let literalIntended = log(0.99)

    /// A word the user has already chosen for this exact key.
    ///
    /// Anchored to the most frequent word in the corpus, so one deliberate
    /// selection is worth at least as much as the commonest reading — that is
    /// what makes a correction stick on the very next keystroke — and repeated
    /// selections climb from there.
    public static func learnedLogProbability(
        decayedCount: Double,
        logMaxWeight: Double,
        logTotalWeight: Double
    ) -> Double {
        logMaxWeight - logTotalWeight + log1p(max(0, decayedCount)) * 0.5
    }

    /// Weight on the language model when its scores are mixed with the
    /// lexicon's, as a log-linear combination of two models of the same
    /// candidate. With committed context the model has real evidence and gets
    /// a strong vote; cold, its preference is mostly style, so the corpus
    /// keeps the upper hand.
    public static func languageModelWeight(hasContext: Bool) -> Double {
        hasContext ? 0.50 : 0.30
    }
}

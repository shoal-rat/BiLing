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
    public enum TypingForm: Sendable {
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

    /// How the typed letters deviate from the intended syllable. Priced like
    /// `TypingForm`: another factor in the same generative story, so a fuzzy
    /// or repaired reading is a log-probability on the shared scale, never an
    /// additive bonus. Exact typing is the untyped default and pays nothing —
    /// log P(no deviation) ≈ log 1 = 0.
    ///
    /// These are usage priors, not measured rates; their order and rough
    /// spacing is what matters. A fuzzy merger is far likelier than any slip
    /// (the user opted in because it *is* how they spell), doubled letters
    /// and swaps are the common mechanical slips, and a wrong or missing
    /// letter is rarer still — it also generates the widest net of readings,
    /// so it must pay the most to stay in its place.
    public enum Tolerance: Sendable {
        /// A dialect merger the user enabled: z/zh, c/ch, s/sh, n/l, f/h,
        /// an/ang, en/eng, in/ing (and thereby ian/iang, uan/uang).
        case fuzzySyllable
        /// Two adjacent letters swapped: nihoa → nihao.
        case transposition
        /// One letter doubled: nihaoo → nihao.
        case duplication
        /// A physical QWERTY neighbour hit instead: zhpng → zhong.
        case substitution
        /// One letter left out: wmen → women.
        case omission

        public var logProbability: Double {
            switch self {
            // Sized against the lexicon, not guessed. Two measured bounds box
            // the value in. It must cost *more* than the widest gap an exact
            // reading can be beaten by: 6.78 nats of raw frequency (zhai 摘 →
            // zai 在) plus the structural advantage of a fuzzy rival that is a
            // whole-buffer word while the exact reading is a multi-segment
            // stitch paying an unsupported transition — ≈ 10 nats in total on
            // the worst dev case (碳素材料 vs 搪塑材料 on tansucailiao). It
            // must cost *less* than the ≈ 11.5-nat margin by which a genuine
            // rescue (zongguo → 中国 over the 总过 stitch) wins. −10.8 sits
            // between the two with margin on the side that protects exact
            // typing, because that is the side the user cannot toggle off.
            case .fuzzySyllable: log(0.00002)
            case .transposition: log(0.012)
            case .duplication: log(0.012)
            case .substitution: log(0.006)
            // The rarest slip and the widest net — and, measured, the one
            // that collides with abbreviated typing: `shp…` is far more
            // likely 上海浦东 as initials than 是 with its i omitted, so
            // omission must stay well under the initials form cost.
            case .omission: log(0.0015)
            }
        }
    }

    /// Latin vocabulary has no corpus counts, so it enters the same unigram
    /// model through a stand-in frequency. The values are chosen relative to
    /// real Chinese counts: a term the user spelled out in full is about as
    /// likely as a moderately common word, a curated expansion less so, and a
    /// guess from the system dictionary rare enough that it cannot outbid a
    /// genuine Chinese reading of the same letters.
    public enum LatinEvidence: Sendable {
        /// The letters spell a known term exactly (`economics`, `github`).
        case spelledOut
        /// Expanded from a curated table (`vs` → VS Code).
        case curatedExpansion
        /// Completed from the system word list — a weak guess.
        case guessedExpansion

        public var pseudoWeight: Double {
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

    /// How much of the transition probability comes from the bigram model
    /// rather than the lexicon unigram (Jelinek-Mercer interpolation). An
    /// unseen transition falls back exactly to the unigram behaviour.
    public static let transitionWeight = 0.40

    /// Weight on the trigram term when rescoring the n-best list.
    ///
    /// Decoding keeps a bigram state because a trigram state would multiply the
    /// lattice; the third-order context is applied afterwards to the finished
    /// candidates instead. This is the usual arrangement in speech decoders —
    /// search with a compact model, rescore with a richer one — and it costs
    /// nothing during search.
    public static let trigramWeight = 0.15

    /// How much a third-order context changes the language-model term.
    ///
    /// Returned as a *difference* from what the decoder already charged, so the
    /// written-form costs it applied — the price of abbreviating — survive
    /// untouched. Rescoring by recomputing the whole score instead throws those
    /// away and, measured, was worth nothing.
    public static func trigramAdjustment(
        words: [String],
        weights: [Double],
        logTotalWeight: Double,
        bigram: (String, String) -> Double,
        trigram: (String, String, String) -> Double
    ) -> Double {
        guard words.count == weights.count else { return 0 }
        var delta = 0.0
        var first = DictTrie.sentenceStart
        var second = DictTrie.sentenceStart
        for (index, word) in words.enumerated() {
            let uni = exp(wordLogProbability(weight: weights[index], logTotalWeight: logTotalWeight))
            let bi = bigram(second, word)
            let tri = trigram(first, second, word)
            let decoded = transitionWeight * bi + (1 - transitionWeight) * uni
            let rescored = trigramWeight * tri
                + transitionWeight * bi
                + max(0, 1 - trigramWeight - transitionWeight) * uni
            delta += log(max(rescored, .leastNormalMagnitude))
                - log(max(decoded, .leastNormalMagnitude))
            first = second
            second = word
        }
        return delta
    }

    /// Cost of one segment given the word before it.
    ///
    /// Scoring a segmentation as independent words cannot separate
    /// 中国工程院·院士 from 中国工程·远远失望 — both are sequences of
    /// individually plausible words. Conditioning on the previous word does,
    /// and it also keeps the correct path alive during pruning, which is where
    /// most of the gain comes from.
    public static func transitionLogProbability(
        weight: Double,
        logTotalWeight: Double,
        conditional: Double,
        form: TypingForm
    ) -> Double {
        let unigram = exp(wordLogProbability(weight: weight, logTotalWeight: logTotalWeight))
        let blended = transitionWeight * conditional + (1 - transitionWeight) * unigram
        return log(max(blended, Double.leastNormalMagnitude)) + form.logProbability
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

    /// Should the language model run at all for this candidate list?
    ///
    /// The statistical margin — the score gap between the first and second
    /// candidate — is the cheapest confidence signal there is, already
    /// computed, and it directly measures whether there is a decision left to
    /// make. When the deterministic layer is sure, invoking a 0.6B model burns
    /// energy to confirm a ranking it almost never changes; when the margin is
    /// thin, the model is exactly what breaks the tie. The threshold is
    /// calibrated on the development set for the largest energy saving at an
    /// accuracy cost indistinguishable from noise; the calibration table lives
    /// in Docs/results/gate-calibration.txt.
    public static func shouldInvokeModel(topScore: Double, secondScore: Double?) -> Bool {
        guard let secondScore else { return false }  // one candidate: nothing to rank
        return (topScore - secondScore) < modelInvocationMargin
    }

    /// Log-score gap above which the statistical ranking stands unassisted.
    public static let modelInvocationMargin = 3.0

    /// Weight on the language model, scaled by how much it actually has to say.
    ///
    /// The lexicon already carries unigram frequency, estimated from a far
    /// larger corpus than a 0.6B model's opinion about a single character. What
    /// the model adds that the lexicon cannot is *conditional* structure: how a
    /// candidate follows the text before it, and how its own parts follow one
    /// another. That evidence is absent for a one-character candidate typed
    /// with no preceding context — and those were exactly the inputs where
    /// re-ranking made accuracy worse.
    ///
    /// So the weight grows with the number of conditional judgements available:
    /// one per token boundary inside the candidate, plus the boundary with the
    /// context when there is one. At zero evidence the model gets no vote and
    /// the lexicon order stands.
    public static func languageModelWeight(
        hasContext: Bool,
        candidateLength: Int
    ) -> Double {
        let evidence = Double(max(0, candidateLength - 1)) + (hasContext ? 2 : 0)
        return 0.55 * evidence / (evidence + 1)
    }
}

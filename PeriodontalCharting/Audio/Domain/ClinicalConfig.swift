//
//  ClinicalConfig.swift
//  transcript
//
//  Port of the periodontal-charting bias + cleanup from the Python notebook
//  (test_whisper_live.ipynb) to WhisperKit.
//
//  Design principle: we store the *words*, not token IDs. Token IDs are
//  tokenizer-specific and must never be hardcoded across runtimes. At load
//  time we encode these words against WhisperKit's own tokenizer, so the
//  IDs are always correct for the model actually loaded.
//
//  Mapping from the Python `generate_kwargs`:
//    words_to_suppress   -> DecodingOptions.suppressTokens   (native)
//    initial_prompt      -> NOT ported. WhisperKit's `promptTokens` isn't a
//                           "prime the first few seconds" hint like Python's
//                           `initial_prompt` — it gets re-injected verbatim
//                           into every 30s window for the whole session
//                           (`DecodingInputs.reset()` never clears it), which
//                           measured as catastrophic on real multi-minute
//                           recordings: over half the audio silently dropped.
//                           See the NOTE in `decodingOptions(for:)` below.
//    words_to_boost      -> SequenceBiasFilter (real per-step logit bias, see that
//                           file) — doesn't degrade with session length the way
//                           a static prompt does.
//    nlp_clean()         -> ClinicalConfig.clean(_:)         (reimplemented in Swift)
//

import Foundation
import WhisperKit

enum ClinicalConfig {
    
    // MARK: - Vocabulary (ported verbatim from the notebook)
    
    /// Directional stems. In `app.py` (DIRECTIONAL_BOOST) these get the
    /// strongest push — they're the highest-value, most acoustically
    /// confusable terms (mesio/disto vs "misi"/"situ"/"stok" etc). Biased at
    /// every decoding step via `SequenceBiasFilter` (see that file).
    static let directionalBoostWords: [String] = [
        "mesio", "disto", "mesial", "distal", "distolingual", "mesiolingual","distobukal", "mesiobukal"
    ]
    
    /// Core clinical words. In `app.py` (WORDS_TO_BOOST) these get a lighter
    /// push than the directional stems — real words that are less prone to
    /// mishearing, so a smaller nudge is enough.
    static let generalBoostWords: [String] = [
        "gigi", "bukal", "lingual", "palatal", "BOP", "resesi",  "kemunduran", "enlargement", "pembengkakan", "pembesaran", "poket", "probing", "kedalaman", "berdarah"
    ]
    
    static let lessCommonBoostWords: [String] = [
        "furcation", "furkasi", "margin", "gingival", "kegoyangan", "mobilitas", "mobility", "implan", "implant"
    ]

    /// Logit bias values, ported directly from `app.py`'s `sequence_bias`
    /// dict (18.0 / 10.0 / -20.0) rather than re-tuned from scratch — per
    /// the "freeze the artifacts" principle, the Python PoC's bias map is
    /// the validated ceiling and reimplementing it from a fresh guess is
    /// exactly the kind of silent divergence that's hard to debug later.
    static let directionalBoostBias: Float = 20.0
    static let generalBoostBias: Float = 10.0
    static let lessCommonBoostBias: Float = 6.0

    /// Known mis-transcriptions / hallucinations to suppress at decode time.
    /// Ported from `words_to_suppress`. We keep the leading-space variants out
    /// here because WhisperKit's `encode` handles spacing; we suppress the token
    /// forms below.
    static let suppressWords: [String] = [
        // gingival-margin / "misio" confusions
        "Tua", "tua", "tuwa", "Duda", "Mimpi", "Gingival", "Rekang",
        "misi", "Misi", "missi", "misio", "misih",
        "kiki", "Kicil", "kicil", "Kecil", "kecil", "Kecik", "kecik",
        "Kecel", "kecel",
        // YouTube-style closing hallucinations in silence/breath gaps
        "Selamat", "menikmati", "Terima", "kasih", "menonton",
        // subtitle-credit hallucinations
        "terjemahan", "Terjemahan", "oleh", "bersambung", "Amin", "amin",
        // "disto" mis-heard as "situ"/"stok"/"situl"
        "situ", "Situ", "stok", "Stok", "situl", "Situl", "sissy"
    ]

    // MARK: - Token binding (runtime, against the loaded tokenizer)

    /// Encode the suppress list into token IDs for the *currently loaded* model.
    /// Returns a de-duplicated, sorted list suitable for `DecodingOptions.suppressTokens`.
    ///
    /// NOTE — divergence from the `app.py` ceiling worth a deliberate call:
    /// `app.py`'s WORDS_TO_SUPPRESS gets a finite -20.0 bias (strongly discouraged,
    /// but still selectable if every other token is worse). This goes through
    /// WhisperKit's native `SuppressTokensFilter`, which hard-masks to -infinity
    /// (never selectable, full stop). That's a real behavioral difference, not
    /// just an implementation detail — if a hallucination word is ever the
    /// acoustically correct answer in some edge case, Python could still emit
    /// it and Swift never will. Flagging rather than "fixing" since -infinity
    /// may well be the right call for pure hallucination words; worth deciding
    /// on purpose rather than by accident of which API was easiest to reach.
    static func suppressTokens(for tokenizer: WhisperTokenizer) -> [Int] {
        var ids = Set<Int>()
        for word in suppressWords {
            // encode both bare and space-prefixed forms; BPE often splits differently
            for variant in [word, " " + word] {
                for id in tokenizer.encode(text: variant) {
                    ids.insert(id)
                }
            }
        }
        // never suppress special tokens; the decoder needs them
        let special = tokenizer.specialTokens.specialTokenBegin
        return ids.filter { $0 < special }.sorted()
    }

    /// Encode `directionalBoostWords` + `generalBoostWords` into
    /// `SequenceBiasFilter.BiasedSequence`s for the *currently loaded*
    /// tokenizer, each at its own tier's bias. Encodes both bare and
    /// space-prefixed forms, same as `suppressTokens(for:)`, since BPE
    /// splits them differently and dictation audio can land on either —
    /// `app.py` only encodes the single leading-space form it observed in
    /// practice (e.g. `" mesio"`), so this is a deliberately wider net
    /// around the same ceiling values, not a narrower one.
    static func boostSequences(for tokenizer: WhisperTokenizer) -> [SequenceBiasFilter.BiasedSequence] {
        let special = tokenizer.specialTokens.specialTokenBegin
        var seen = Set<[Int]>()
        var sequences: [SequenceBiasFilter.BiasedSequence] = []
        func addAll(_ words: [String], bias: Float) {
            for word in words {
                for variant in [word, " " + word] {
                    let ids = tokenizer.encode(text: variant).filter { $0 < special }
                    guard !ids.isEmpty, seen.insert(ids).inserted else { continue }
                    sequences.append(SequenceBiasFilter.BiasedSequence(tokens: ids, bias: bias))
                }
            }
        }
        addAll(directionalBoostWords, bias: directionalBoostBias)
        addAll(generalBoostWords, bias: generalBoostBias)
        addAll(lessCommonBoostWords, bias: lessCommonBoostBias)
        return sequences
    }

    /// DecodingOptions carrying the periodontal-charting bias (suppress
    /// mis-hears via `suppressTokens`; vocabulary boost lives in
    /// `SequenceBiasFilter`, wired in separately at the WhisperKit/
    /// textDecoder level — see TranscriptionViewModel.loadModel()).
    /// Centralized here (not in the view model) so the eval harness builds
    /// the exact same options the app uses — a hand-copied second
    /// definition is exactly the kind of silent divergence that makes an
    /// eval number meaningless.
    static func decodingOptions(for tokenizer: WhisperTokenizer?) -> DecodingOptions {
        var suppress: [Int] = []
        if let tokenizer {
            suppress = suppressTokens(for: tokenizer)
        }
        // Threshold tuning for periodontal charting audio.
        //
        // Charting dictation is (a) highly repetitive ("bukal 2 bukal 2 bukal 2") and
        // (b) delivered as quiet, bare numbers. The stock fallback logic misfires on both:
        //
        //   • compressionRatioThreshold — meant to catch degenerate repeat-loops, but
        //     charting is *legitimately* repetitive, so the stock 2.4 keeps flagging
        //     correct decodes and re-decoding them at higher temperature (worse AND
        //     slower). Measured against real charting audio (ClinicalEval harness):
        //     legitimate repetitive segments top out around compressionRatio ~3.9;
        //     an actual degenerate loop (model stuck repeating a single digit ~110
        //     times) hit 29.9. 8.0 sits with comfortable margin on both sides — this
        //     is a LOOSENED guard, not a disabled one. `nil` was tried and measured
        //     worse: it let that exact repeat-loop through untouched, disproving the
        //     assumption that the logProb fallback below would always catch it (that
        //     segment's avgLogprob was -0.21 — confidently wrong, not "terrible").
        //
        //   • noSpeechThreshold 0.6 -> 0.9  : quiet dictation is not treated as silence
        //                                     (prevents whole segments being skipped).
        //   • logProbThreshold  -1.0 -> -1.5: keep more low-confidence (but real) number
        //                                     segments; still catches genuine garbage.
        //   • temperatureFallbackCount 5 -> 2: fewer costly re-decodes -> faster.
        //
        // NOTE: `promptTokens`/`initialPrompt` are intentionally NOT wired in here.
        // WhisperKit prefills `initialPrompt` once before the seek loop and
        // `DecodingInputs.reset(maxTokenContext:)` (called between every window)
        // only clears the KV-cache/masks — it never touches `initialPrompt`. So a
        // static prompt is NOT a "prime the first few seconds" hint the way
        // Python's/openai's `initial_prompt` is: it gets re-injected verbatim into
        // EVERY window for the life of the session. On a real multi-minute
        // recording this measured as catastrophic — over half the audio silently
        // dropped (many windows decoded straight to `<|endoftext|>`) once the
        // fixed prompt's content ("gigi 18 gak ada...") drifted far enough from
        // what was actually being said minutes later. Removing it alone recovered
        // full-file coverage (recall 18% -> 73% on one eval clip). The vocabulary
        // boost this was standing in for is now handled properly by
        // `SequenceBiasFilter` (real per-step logit bias, doesn't degrade with
        // session length); the hallucination case it also guarded against
        // ("dua dua dua" -> "Tuhan") is still covered by `suppressTokens` below.
        return DecodingOptions(
            task: .transcribe,
            language: "id",
            temperature: 0.0,
            temperatureIncrementOnFallback: 0.2,
            temperatureFallbackCount: 2,
            usePrefillPrompt: true,
            suppressBlank: true,
            suppressTokens: suppress.isEmpty ? nil : suppress,
            compressionRatioThreshold: 8.0,   // loosened, not disabled — see note above
            logProbThreshold: -1.5,
            noSpeechThreshold: 0.9
        )
    }

    // MARK: - Post-processing (Swift port of nlp_clean)

    /// Multi-word corruption repairs, applied BEFORE tokenizing the transcript.
    /// (regex pattern, replacement) — ported from PHRASE_FIX.
    private static let phraseFixes: [(String, String)] = [
        (#"\bplak\s*ada\b"#, "gak ada"),
        // "gak ada" (tooth missing) merged/garbled by STT into one token
        // ("gada"/"gaada"/"gakda"/"gadda"…). Left alone, the Levenshtein snap sends
        // it to "pada" (the "at" action) — because "pada" precedes "ada" in the
        // lexicon and is 1 edit away — so the tooth never gets marked missing.
        // Must run here (before the snap). Leaves "pada"/"ada"/"tidak ada" untouched.
        (#"\bgak?\s?a?d+a+\b"#, "gak ada"),
        // "disto" corruptions, only when a site word / number follows
        (#"\b(?:di\s*situ|disitu|justru|di\s*stok|di\s*stop|stok|situl|di\s*situl|di\s*setiap|di\s*semua|di\s*1)\b(?=\s+(?:bukal|lingual|\d))"#, "disto"),
        (#"\bdi\s*situ\b"#, "disto"),
        (#"\bdisitu\b"#, "disto"),
        (#"\bjustru\b"#, "disto"),
        // "disto bukal" acoustically compressed by STT into "di bop" — dangerous
        // because "bop" is the BLEEDING metric, so the site would mark bleeding
        // instead. Safe to rewrite: legit "di" is always followed by a site word
        // (bukal/lingual/…), never "bop", and "bop di bukal" has the other order.
        (#"\bdi\s*bop\b"#, "disto bukal"),
        // "disto lingual" split as "<stem> wall"
        (#"\b(?:pistoling|storing|sturing|distoling)\s+wall\b"#, "disto lingual"),
        (#"\bdistoling\b"#, "disto lingual"),
        // "mesio lingual"
        (#"\b(?:mecholing|mesiolimual|lingwang)\b"#, "mesio lingual"),
        (#"\bmezio\s*limual\b"#, "mesio lingual"),
        // "disto bukal"
        (#"\b(?:kistobukal|disubukal|disubuka)\b"#, "disto bukal"),
        // "disto bukal" glued into one token with the leading 'd' dropped (disto ->
        // seto/situ/sto) and/or the site's final 'l' dropped (bukal -> buka), optionally
        // with a stray leading "di" and/or the tooth number glued on: "di setobuka",
        // "setobukal", "situbuka", "stobukal", "setobukal17". The trailing (\d+) is
        // re-spaced so the tooth id survives. Runs before tokenizing so BOTH the displayed
        // transcript and the parser see "disto bukal". Requires the "buk" core, so
        // "setelah"/"sibuk"/"setubuh"/"membuka" are untouched. See STT_ISSUES #3/#5.
        (#"\b(?:di\s+)?s[ei]?t[ou]?buka?l?(\d+)?\b"#, "disto bukal $1"),
        // "mesio bukal" glued/compressed variants, likewise with an optional glued tooth
        // number ("mesiyobukal", "msiyobukal", "mesiobuka", "mesiyobukal17").
        (#"\bm[e]?s[iy]+o?buka?l?(\d+)?\b"#, "mesio bukal $1"),
        // "mesio bukal"
        (#"\bmili\s*bukal\b"#, "mesio bukal"),
        // stray "lingual"
        (#"\b(?:limual|limoal|lungwal|lingwal|linguah|linguard|bistur)\b"#, "lingual"),
        (#"\b(?:4 cation|furukasih|forcation|furukashi)\b"#, "furcation"),
        // "minus satu" (recession value -1) gets merged/garbled by STT into one
        // non-corpus word ("minosato" / "minusatu"), so the value is lost entirely.
        // Split it back so "satu" -> 1 survives (the sign still comes from the
        // metric, e.g. resesi). Matches the merged form only; leaves the correct
        // spaced "minus satu"/"minus dua" untouched. Add sibling numbers as observed.
        (#"\bmin[oau]sat[ou]o?\b"#, "minus satu"),
        (#"\bmissed\b"#, "missing"),
        // Compound site terms: normalize to the SPACED form.
        //
        // Both spellings mean the same site, and both occur in dictation and in
        // the reference transcripts ("mesio bukal" 31x vs "mesiobukal" 3x in
        // ground_truth_sample_2). Whitespace-tokenized comparison can't align
        // the two, so an otherwise-correct decode scores as a miss on the
        // compound AND a false positive on its stem. Collapsing to one form
        // makes the two spellings compare equal.
        //
        // Spaced is the target because it's what the model overwhelmingly
        // emits and what dominates the references; it also keeps the stem
        // ("mesio"/"disto") visible as its own token for downstream charting.
        //
        // NOTE: deliberately does NOT rewrite "mesial"/"distal" -> "mesio"/"disto".
        // Those are a speaker-convention difference, not a transcription error:
        // sample_1 dictates "mesial bukal"/"distal bukal" and its ground truth
        // records them verbatim, while sample_2 uses "mesio"/"disto". A blind
        // rewrite would "fix" sample_2 and corrupt sample_1.
        (#"\b(mesio|disto)(bukal|lingual|palatal)\b"#, "$1 $2"),
    ]

    /// Words to drop entirely (disfluencies + hallucinations). Ported from DISFLUENCY.
    private static let disfluency: Set<String> = [
        "uh", "eh", "em", "oke", "ok", "hmm", "ya", "tuh", "nih", "gitu",
        "terima", "kasih", "terimakasih", "menonton", "sudah", "applause",
        "round", "of", "dikala", "apaan", "ati", "pun", "dental", "crystal",
        "mimpi", "rekang", "gatuh", "atu", "ticke", "pelat", "pelak", "a",
        "selamat", "menikmati", "okay", "noir", "uko", "begitikan", "bikin",
        "jadwal", "kisah", "lejyu", "dermatik", "kicil", "kisok", "kedakkal",
        "mecioli", "krisdo", "cookar", "saturnah", "pahamu", "mesti", "kim",
        "prosesi", "meshubuga", "terjemahan", "oleh", "bersambung", "amin",
        "kikimpa", "bistur"
    ]

    /// Indonesian number words -> digits.
    private static let textToNum: [String: String] = {
        var m: [String: String] = [
            "satu": "1", "dua": "2", "tiga": "3", "empat": "4", "lima": "5",
            "enam": "6", "tujuh": "7", "lapan": "8", "delapan": "8", "minus": "-"
        ]
        // "dua" mis-transcriptions that should all collapse to "2"
        let twos = ["tua", "tuwa", "tuwwa", "tuah", "tuwah", "tuuh", "tuih",
                    "tuha", "tuhe", "tuho", "tuwe", "tuva", "tuam", "tuor",
                    "duda", "duba", "duma", "dupa", "duka", "duta", "dala",
                    "dukat", "dula", "daba", "dura", "dima", "danga", "tuala",
                    "dikat", "tuhan", "tuh", "tue", "twer"]
        for t in twos { m[t] = "2" }
        return m
    }()

    /// Words that are correct clinical/Indonesian terms (never flag or drop).
    /// Ordered to match Python's LEXICON so the Levenshtein tie-break (first
    /// strictly-closer match wins) resolves identically. `lexicon` is the O(1)
    /// membership set derived from it.
    private static let lexiconList: [String] = [
        "gigi", "bukal", "palatal", "lingual", "labial", "mesial", "distal",
        "mesio", "disto", "distolingual", "mesiolingual", "resesi", "plak",
        "probing", "depth", "bop", "rahang", "atas", "bawah", "gingival",
        "margin", "mili", "milimeter", "sampai", "hingga", "lanjut", "dari",
        "pada", "semua", "dan", "tidak", "ada", "gak", "minus", "mm",
        "bagian", "bleeding", "pocket", "missing", "terdapat", "seluruh",
        "permukaan", "maupun", "sekitar", "setelah", "disini", "on", "or",
        "measure", "kecil", "furcation", "furkasi"
    ]
    private static let lexicon: Set<String> = Set(lexiconList)

    /// Swift port of `nlp_clean`. Applies phrase fixes, drops disfluencies,
    /// maps number-words to digits, and collapses immediate repeats.
    static func clean(_ text: String) -> String {
        var t = text
        for (pattern, repl) in phraseFixes {
            t = replace(t, pattern: pattern, with: repl)
        }

        var out: [String] = []
        var prev: String? = nil
        for rawTok in t.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            let tok = String(rawTok)
            // extract the core [a-zA-Z0-9-] run + surrounding punctuation
            guard let core = firstMatch(tok, pattern: #"[a-zA-Z0-9\-]+"#) else { continue }
            let low = core.lowercased()
            if low.isEmpty || disfluency.contains(low) { continue }

            let final: String
            if let num = textToNum[low] {
                final = num
            } else if low.allSatisfy({ $0.isLetter }) && low.count >= 3 && !lexicon.contains(low) {
                // unknown alpha token: snap to the nearest lexicon word within 2 edits
                // (Python nlp_clean's get_best_match_levenshtein); keep as-is otherwise.
                final = bestLexiconMatch(low, maxEdits: 2) ?? low
            } else {
                final = low
            }

            // collapse an immediate non-numeric repeat
            let hasDigit = final.contains { $0.isNumber }
            if final == prev && !hasDigit { continue }
            prev = final

            // preserve leading/trailing punctuation around the core
            if let range = tok.range(of: core) {
                let prefix = String(tok[tok.startIndex..<range.lowerBound])
                let suffix = String(tok[range.upperBound...])
                out.append(prefix + final + suffix)
            } else {
                out.append(final)
            }
        }

        var joined = out.joined(separator: " ")
        // tidy space-before-punctuation
        joined = replace(joined, pattern: #"\s+([.,!?])"#, with: "$1")
        return joined.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Levenshtein fuzzy match (port of get_best_match_levenshtein)

    /// Nearest lexicon word to `word` within `maxEdits` edits, or nil. Iterates in
    /// `lexiconList` order and keeps the first strictly-closer match, mirroring the
    /// Python tie-break so the same corrections come out.
    private static func bestLexiconMatch(_ word: String, maxEdits: Int) -> String? {
        var best: String?
        var minDist = Int.max
        let wordChars = Array(word)
        for lex in lexiconList {
            let d = levenshtein(wordChars, Array(lex))
            if d < minDist { minDist = d; best = lex }
        }
        return minDist <= maxEdits ? best : nil
    }

    /// Classic two-row Levenshtein edit distance.
    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 0..<a.count {
            cur[0] = i + 1
            for j in 0..<b.count {
                let cost = a[i] == b[j] ? 0 : 1
                cur[j + 1] = min(prev[j + 1] + 1, cur[j] + 1, prev[j] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    // MARK: - Regex helpers

    private static func replace(_ s: String, pattern: String, with repl: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return s
        }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        return re.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: repl)
    }

    private static func firstMatch(_ s: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        guard let m = re.firstMatch(in: s, options: [], range: range),
              let r = Range(m.range, in: s) else { return nil }
        return String(s[r])
    }
}

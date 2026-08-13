//
//  SequenceBiasFilter.swift
//  transcript
//
//  Real per-step logit biasing for the clinical vocabulary, on top of
//  WhisperKit's public `LogitsFiltering` extension point — no fork needed
//  (WhisperKitConfig.logitsFilters / TextDecoder.logitsFilters are both
//  public: Sources/WhisperKit/Core/{Configurations,TextDecoder}.swift).
//
//  Why this exists: ClinicalConfig currently only "boosts" via the initial
//  prompt, which primes the first few tokens of context and fades as
//  decoding proceeds. A dictation session runs for minutes; by the time
//  we're deep into "bukal 3 lingual 2 mesio 4 ...", the prompt's influence
//  is gone. This filter re-applies a bias to the clinical vocabulary on
//  EVERY decoding step, for the life of the session.
//
//  Progressive / sequence-conditioned, not flat per-token: for a multi-token
//  word like "distolingual" -> [t1, t2, t3], we only bias t2 once t1 has
//  just been generated, and t3 once [t1, t2] has just been generated. A flat
//  "always bias t1, t2, t3" would also boost t2 or t3 whenever they appear as
//  a BPE fragment of some unrelated word, which is exactly the kind of silent
//  contamination the tokenizer-verification step is meant to catch. This
//  mirrors HF transformers' `SequenceBiasLogitsProcessor` semantics, which is
//  where the name comes from.
//

import CoreML
import WhisperKit

final class SequenceBiasFilter: LogitsFiltering {

    struct BiasedSequence {
        /// Token IDs for one surface form of a boosted word (e.g. " bukal").
        let tokens: [Int]
        /// Added to the logit of `tokens[k]` once the previous `k` generated
        /// tokens exactly match `tokens[0..<k]`. Positive boosts, negative
        /// suppresses (finite, unlike `DecodingOptions.suppressTokens`'s -inf).
        let bias: Float
    }

    private let sequences: [BiasedSequence]

    /// - Parameter maxLogitMagnitude: clamp applied to the post-bias logit
    ///   before it's written back. `FloatType` is `Float16` on-device (see
    ///   ArgmaxCore/FloatType.swift); Float16's max finite value is ~65504,
    ///   and an already-high logit plus a careless bias can otherwise round
    ///   to +inf and poison the softmax. 65000 leaves headroom either side.
    /// - Parameter maxImmediateRepeats: anti-runaway guard. A biased word's
    ///   *first* token is boosted regardless of preceding context (that's the
    ///   point — nudge the vocabulary when acoustics are ambiguous). But in a
    ///   silence / low-confidence stretch the true logit spread is tiny, so a
    ///   flat boost on a short boosted word (e.g. single-token "plaque") wins,
    ///   the emitted token conditions the next step, and the model detonates
    ///   into "plaque plaque plaque …" — measured on both the live path and the
    ///   un-VAD'd probe_doc benchmark (142 spurious "plaque" @ 6.5% precision).
    ///   Once a boosted sequence has already been emitted back-to-back this many
    ///   times ending at the current position, we STOP boosting its first token,
    ///   so the loop can't be self-sustained by the bias. A normal repeat the
    ///   speaker actually said ("bukal … bukal") is unaffected up to the limit,
    ///   and is still selectable past it on acoustics alone — we only remove the
    ///   *thumb on the scale*, we don't suppress the token.
    init(sequences: [BiasedSequence], maxLogitMagnitude: Float = 65000, maxImmediateRepeats: Int = 2) {
        // Drop empty token sequences defensively; they'd otherwise bias
        // index 0 unconditionally (prefixLen would be 0 with no tokens[0]).
        self.sequences = sequences.filter { !$0.tokens.isEmpty }
        self.maxLogitMagnitude = maxLogitMagnitude
        self.maxImmediateRepeats = max(1, maxImmediateRepeats)
    }

    private let maxLogitMagnitude: Float
    private let maxImmediateRepeats: Int

    /// How many times `seq.tokens` appears as an immediate, back-to-back suffix
    /// of `tokens` (the already-generated context). 0 if the tail isn't a whole
    /// copy of the sequence. Used to detect a bias-driven runaway before we add
    /// yet another boost that would extend it.
    private func immediateRepeatCount(of seq: [Int], in tokens: [Int]) -> Int {
        let n = seq.count
        guard n > 0, tokens.count >= n else { return 0 }
        var count = 0
        var end = tokens.count
        while end >= n && Array(tokens[(end - n)..<end]) == seq {
            count += 1
            end -= n
        }
        return count
    }

    func filterLogits(_ logits: MLMultiArray, withTokens tokens: [Int]) -> MLMultiArray {
        guard !sequences.isEmpty else { return logits }

        // Bound against the array's *actual* last-dimension size, not an
        // assumed vocab constant — the model config is the source of truth.
        let vocabSize = logits.shape.last?.intValue ?? 0
        guard vocabSize > 0 else { return logits }

        logits.withUnsafeMutableBufferPointer(ofType: FloatType.self) { ptr, strides in
            let tokenStride = strides.last ?? 1
            for seq in sequences {
                let prefixLen = min(seq.tokens.count - 1, tokens.count)
                guard prefixLen == 0 || tokens.suffix(prefixLen).elementsEqual(seq.tokens[0..<prefixLen]) else {
                    continue
                }
                // Anti-runaway: if we're at a word boundary (prefixLen == 0, i.e.
                // about to boost the FIRST token of this sequence) and the sequence
                // has already been emitted immediately back-to-back at least
                // `maxImmediateRepeats` times, don't add another boost — that's the
                // self-reinforcing loop, not real repeated speech worth nudging.
                if prefixLen == 0,
                   immediateRepeatCount(of: seq.tokens, in: tokens) >= maxImmediateRepeats {
                    continue
                }
                let nextTokenID = seq.tokens[prefixLen]
                guard nextTokenID >= 0, nextTokenID < vocabSize else { continue }

                let offset = nextTokenID * tokenStride
                guard offset >= 0, offset < ptr.count else { continue }

                let boosted = Float(ptr[offset]) + seq.bias
                let clamped = max(-maxLogitMagnitude, min(maxLogitMagnitude, boosted))
                ptr[offset] = FloatType(clamped)
            }
        }
        return logits
    }
}

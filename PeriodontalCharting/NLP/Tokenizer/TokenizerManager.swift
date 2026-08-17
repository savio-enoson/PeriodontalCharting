import Foundation

/// Single entry point for Phase 1 tokenization. The CoreML word classifier has
/// been removed; this now forwards directly to the rule-based `VoiceTokenizer`.
/// Kept as the shared seam so callers (AIVoiceViewModel, tests) are unchanged.
final class TokenizerManager {
    static let shared = TokenizerManager()

    private init() {}

    /// No-op retained for call-site compatibility. There is no model to load now
    /// that the rule-based tokenizer is the only Phase 1 path.
    func loadModel() {}

    func tokenize(text: String, isFinal: Bool = false, currentMetric: AnnotationOperation? = nil) -> [VoiceToken] {
        VoiceTokenizer.tokenize(text: text, isFinal: isFinal, currentMetric: currentMetric)
    }
}

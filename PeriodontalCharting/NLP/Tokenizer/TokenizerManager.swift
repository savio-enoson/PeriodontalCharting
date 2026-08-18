import Foundation

/// Single entry point for Phase 1 tokenization. The CoreML word classifier has
/// been removed; this now forwards directly to the rule-based `VoiceTokenizer`.
/// Kept as the shared seam so callers (AIVoiceViewModel, tests) are unchanged.
final class TokenizerManager {
    static let shared = TokenizerManager()
    
    init() {
    }
    
    func loadModel() {
        // No-op
    }
    
    func tokenize(text: String, isFinal: Bool = false, currentMetric: AnnotationOperation? = nil, parserCurrentValues: Int = 0, parserExpectedValues: Int = 3) -> [VoiceToken] {
        return VoiceTokenizer.tokenize(text: text, isFinal: isFinal, currentMetric: currentMetric, parserCurrentValues: parserCurrentValues, parserExpectedValues: parserExpectedValues)
    }
}

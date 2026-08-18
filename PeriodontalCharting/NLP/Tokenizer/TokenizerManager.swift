import Foundation

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

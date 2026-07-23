import Foundation

extension VoiceTokenizer {
    static func parseIntOrWord(_ w: String) -> Int? {
        if let num = Int(w) { return num }
        if let num = VoiceTokenizer.numberWords[w] { return num }
        return nil
    }
}

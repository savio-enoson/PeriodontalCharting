import Foundation
import CoreML
import Combine

class TokenizerManager: ObservableObject, @unchecked Sendable {
    static let shared = TokenizerManager()
    
    var useMLTokenizer = true
    private(set) var mlTokenizer: MLVoiceTokenizer?
    

    private init() {
        if let modelURL = Bundle.main.url(forResource: "VoiceTokenizerModel", withExtension: "mlmodelc") {
            self.mlTokenizer = MLVoiceTokenizer(modelURL: modelURL)
        } else {
            // For testing in CLI
            let url = URL(fileURLWithPath: "VoiceTokenizerModel.mlmodelc")
            self.mlTokenizer = MLVoiceTokenizer(modelURL: url)
        }
    }
    
    func tokenize(text: String, isFinal: Bool = false) -> [VoiceToken] {
        if useMLTokenizer, let ml = mlTokenizer {
            let normalized = normalizeSTT(text, isForML: true)
            var state = MLTokenizerState()
            return ml.tokenize(text: normalized, isFinal: isFinal, sessionState: &state)
        } else {
            let normalized = normalizeSTT(text, isForML: false)
            return VoiceTokenizer.tokenize(text: normalized, isFinal: isFinal)
        }
    }
    
    private func normalizeSTT(_ text: String, isForML: Bool) -> String {
        // First correct phonetic typos and STT errors
        var processed = PhoneticCorrector.normalize(text: text)
        
        processed = processed.lowercased()
            .replacingOccurrences(of: ".", with: " _sep_ ")
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "\n", with: " _sep_ ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "{", with: " ")
            .replacingOccurrences(of: "}", with: " ")
            .replacingOccurrences(of: " -", with: " minus ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "b o p", with: "bop")
            .replacingOccurrences(of: "b.o.p", with: "bop")
            .replacingOccurrences(of: "bleeding on probing", with: "bop")
            .replacingOccurrences(of: "bleeding or probing", with: "bop")
            .replacingOccurrences(of: "probing depth", with: "poket")
            
        // Word level misspellings mapping
        var words = processed.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        words = words.map { word in
            switch word {
            case "misio", "mesyio", "mesyu", "meso", "mezzo": return "mesio"
            case "sampe": return "sampai"
            case "disco": return "disto"
            case "misial", "mesyal": return "mesial"
            case "diso", "distio", "dista": return "disto"
            case "disal": return "distal"
            case "bocal", "vocal", "buka", "buckal", "buk": return "bukal"
            case "plat", "plug", "flak", "plek", "flek", "black", "flag": return "plak"
            case "pocket", "poke", "poked": return "poket"
            case "beope", "biopi", "tiopi", "bleeding": return "bop"
            case "palato", "palat": return "palatal"
            case "linguo": return "lingual"
            case "enggak", "nda", "ndak": return "gak"
            case "mobiliti": return "mobility"
            case "purkasi", "furkasion", "forkasi": return "furkasi"
            default: return word
            }
        }
        processed = words.joined(separator: " ")
        if isForML {
            processed = processed
                .replacingOccurrences(of: "mesio lingual", with: "mesiolingual")
                .replacingOccurrences(of: "disto lingual", with: "distolingual")
                .replacingOccurrences(of: "mesio bukal", with: "mesiobukal")
                .replacingOccurrences(of: "disto bukal", with: "distobukal")
                .replacingOccurrences(of: "mesio palatal", with: "mesiopalatal")
                .replacingOccurrences(of: "disto palatal", with: "distopalatal")
                .replacingOccurrences(of: "mesio labial", with: "mesiolabial")
                .replacingOccurrences(of: "disto labial", with: "distolabial")
        } else {
            processed = processed
                .replacingOccurrences(of: "mesiolingual", with: "mesio lingual")
                .replacingOccurrences(of: "distolingual", with: "disto lingual")
                .replacingOccurrences(of: "mesiobukal", with: "mesio bukal")
                .replacingOccurrences(of: "distobukal", with: "disto bukal")
                .replacingOccurrences(of: "mesiopalatal", with: "mesio palatal")
                .replacingOccurrences(of: "distopalatal", with: "disto palatal")
                .replacingOccurrences(of: "mesiolabial", with: "mesio labial")
                .replacingOccurrences(of: "distolabial", with: "disto labial")
                .replacingOccurrences(of: "mid-", with: "mid ")
        }
        
        // 1. Value Splitting
        if let regex = try? NSRegularExpression(pattern: "\\d{3,}") {
            let nsString = processed as NSString
            let matches = regex.matches(in: processed, range: NSRange(location: 0, length: nsString.length))
            
            // Iterate backwards to avoid messing up ranges
            for match in matches.reversed() {
                let matchedString = nsString.substring(with: match.range)
                let spaced = matchedString.map { String($0) }.joined(separator: " ")
                processed = (processed as NSString).replacingCharacters(in: match.range, with: spaced)
            }
        }
        
        // 2. Tooth Merging
        let num1 = "([1-4]|satu|dua|tiga|empat)"
        let num2 = "([1-8]|satu|dua|tiga|empat|lima|enam|tujuh|delapan)"
        let pattern = "\\b(gigi|g)\\s+\(num1)\\s+\(num2)\\b"
        
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let nsString = processed as NSString
            let matches = regex.matches(in: processed, range: NSRange(location: 0, length: nsString.length))
            for match in matches.reversed() {
                let d1Str = nsString.substring(with: match.range(at: 2))
                let d2Str = nsString.substring(with: match.range(at: 3))
                
                if let v1 = VoiceTokenizer.parseIntOrWord(d1Str), let v2 = VoiceTokenizer.parseIntOrWord(d2Str) {
                    let replacement = "gigi \(v1)\(v2)"
                    processed = (processed as NSString).replacingCharacters(in: match.range, with: replacement)
                }
            }
        }
        
        return processed
    }
}

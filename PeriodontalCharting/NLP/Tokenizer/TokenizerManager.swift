import Foundation

final class TokenizerManager {
    static let shared = TokenizerManager()
    
    var mlTokenizer: MLVoiceTokenizer?
    
    init() {
    }
    
    func loadModel() {
        if mlTokenizer == nil {
            mlTokenizer = MLVoiceTokenizer()
        }
    }
    
    func tokenize(text: String, isFinal: Bool = false) -> [VoiceToken] {
        let useML = UserDefaults.standard.object(forKey: "useMLTokenizer") as? Bool ?? true
        if useML {
            loadModel()
        }
        guard useML, let mlTokenizer = mlTokenizer else {
            return VoiceTokenizer.tokenize(text: text, isFinal: isFinal)
        }
        
        let cleaned = normalize(text: text)
        let words = cleaned.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        
        var tokens: [VoiceToken] = []
        
        let sentences = words.split(separator: "_sep_", omittingEmptySubsequences: false)
        for (idx, sentence) in sentences.enumerated() {
            let sentenceWords = Array(sentence)
            if sentenceWords.isEmpty {
                if idx < sentences.count - 1 { tokens.append(.word("_sep_")) }
                continue
            }
            
            var state = MLTokenizerState(activeMetric: 0, priorLabels: [41, 41, 41], contextWindow: [])
            
            for (i, word) in sentenceWords.enumerated() {
                let contextStart = max(0, i - 10)
                let contextEnd = min(sentenceWords.count - 1, i + 5)
                let contextWords = Array(sentenceWords[contextStart...contextEnd])
                let wordIndex = i - contextStart
                
                if let token = mlTokenizer.predict(wordIndex: wordIndex, context: contextWords, state: &state, originalWord: word) {
                    if let lastToken = tokens.last {
                        if case .anatomy(let lastAnatomy) = lastToken, case .anatomy(let currentAnatomy) = token, lastAnatomy == currentAnatomy {
                            continue // Skip duplicate consecutive anatomy tokens
                        }
                        if case .action(let lastAction) = lastToken, case .action(let currentAction) = token, lastAction == currentAction {
                            continue // Skip duplicate consecutive action tokens
                        }
                    }
                    tokens.append(token)
                }
            }
            
            if idx < sentences.count - 1 {
                tokens.append(.word("_sep_"))
            }
        }
        
        var processedTokens: [VoiceToken] = []
        var tIdx = 0
        while tIdx < tokens.count {
            let token = tokens[tIdx]
            
            if case .word(let w) = token {
                let nextW = (tIdx + 1 < tokens.count) ? {
                    if case .word(let nw) = tokens[tIdx + 1] { return nw }
                    return ""
                }() : ""
                
                if (w == "gak" || w == "tidak") && nextW == "ada" {
                    processedTokens.append(.action(.missing))
                    tIdx += 2
                    continue
                }
                if w == "missing" {
                    processedTokens.append(.action(.missing))
                    tIdx += 1
                    continue
                }
                if w == "semua" || w == "semuanya" || w == "seluruh" || w == "seluruhnya" {
                    processedTokens.append(.action(.all))
                    tIdx += 1
                    continue
                }
                if w == "lanjut" || w == "selesai" || w == "kemudian" || w == "selanjutnya" || w == "berikutnya" {
                    processedTokens.append(.action(.commit))
                    tIdx += 1
                    continue
                }
                if w == "dari" || w == "mulai" {
                    processedTokens.append(.action(.from))
                    tIdx += 1
                    continue
                }
                if w == "sampai" || w == "hingga" || w == "ke" {
                    processedTokens.append(.action(.until))
                    tIdx += 1
                    continue
                }
            }
            
            if case .number(let n) = token, n >= 11, n % 11 == 0, tIdx > 0 {
                if let last = processedTokens.last, case .number(_) = last {
                    processedTokens.append(.number(n / 11))
                    processedTokens.append(.number(n / 11))
                    tIdx += 1
                    continue
                }
            }
            
            // Match legacy heuristic: any number > 10 and < 99 (that wasn't caught by the 11-repeating rule above)
            // is unconditionally treated as a tooth identifier.
            if case .number(let n) = token, n > 10 && n < 99 {
                processedTokens.append(.toothIdentifier(n))
                tIdx += 1
                continue
            }
            
            if case .toothIdentifier(let d1) = token, d1 >= 1 && d1 <= 8 {
                if tIdx + 1 < tokens.count, case .toothIdentifier(let d2) = tokens[tIdx+1], d2 >= 1 && d2 <= 8 {
                    processedTokens.append(.toothIdentifier(d1 * 10 + d2))
                    tIdx += 2
                    continue
                }
            }
            
            // Helper to extract digit from any token type
            func extractDigit(from t: VoiceToken) -> Int? {
                if case .number(let n) = t { return n }
                if case .toothIdentifier(let n) = t { return n }
                if case .word(let w) = t {
                    if let n = Int(w) { return n }
                    if let n = VoiceTokenizer.numberWords[w] { return n }
                }
                return nil
            }
            
            // Match legacy heuristic: if we see two single digits that could form a tooth ID, 
            // and they are NOT followed by a third digit (which would mean it's a 3-value PD array)
            // or another number, we merge them into a tooth identifier.
            if let d1 = extractDigit(from: token), d1 >= 1 && d1 <= 4 {
                if tIdx + 1 < tokens.count, let d2 = extractDigit(from: tokens[tIdx+1]), d2 >= 1 && d2 <= 8 {
                    var thirdIsNumber = false
                    
                    // Look ahead for a third number, ignoring _sep_ tokens temporarily
                    var lookaheadIdx = tIdx + 2
                    while lookaheadIdx < tokens.count {
                        let nextTok = tokens[lookaheadIdx]
                        if case .word(let w) = nextTok, w == "_sep_" {
                            lookaheadIdx += 1
                            continue
                        } else if extractDigit(from: nextTok) != nil {
                            thirdIsNumber = true
                            break
                        } else {
                            break
                        }
                    }
                    
                    if !thirdIsNumber {
                        // Check if previous token was also a number IN THE SAME BLOCK
                        var prevIsNumber = false
                        var lookbehindIdx = processedTokens.count - 1
                        while lookbehindIdx >= 0 {
                            let prevTok = processedTokens[lookbehindIdx]
                            if case .word(let w) = prevTok, w == "_sep_" {
                                // A _sep_ means we are at the start of a new block, so no previous number in this block.
                                break
                            } else if case .anatomy(_) = prevTok {
                                // An anatomy token also resets the number block
                                break
                            } else if extractDigit(from: prevTok) != nil {
                                prevIsNumber = true
                                break
                            } else {
                                lookbehindIdx -= 1
                            }
                        }
                        
                        if !prevIsNumber {
                            processedTokens.append(.toothIdentifier(d1 * 10 + d2))
                            tIdx += 2
                            continue
                        }
                    }
                }
            }
            
            // Deduplicate consecutive identical anatomy tokens
            if case .anatomy(let anat1) = token, let last = processedTokens.last, case .anatomy(let anat2) = last, anat1 == anat2 {
                tIdx += 1
                continue
            }
            
            processedTokens.append(token)
            tIdx += 1
        }
        
        return processedTokens
    }
    
    private func normalize(text: String) -> String {
        var cleaned = text.lowercased()
            .replacingOccurrences(of: #"(?<=\d)\.(?=\d)"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: ".", with: " _sep_ ")
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "\n", with: " _sep_ ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "{", with: " ")
            .replacingOccurrences(of: "}", with: " ")
            .replacingOccurrences(of: "mesiolingual", with: "mesio lingual")
            .replacingOccurrences(of: "distolingual", with: "disto lingual")

            .replacingOccurrences(of: "mesiopalatal", with: "mesio palatal")
            .replacingOccurrences(of: "distopalatal", with: "disto palatal")
            .replacingOccurrences(of: "mesiolabial", with: "mesio labial")
            .replacingOccurrences(of: "distolabial", with: "disto labial")
            .replacingOccurrences(of: "mid-", with: "mid ")
            .replacingOccurrences(of: "mid ", with: "mid")
            .replacingOccurrences(of: " -", with: " minus ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "b o p", with: "bop")
            .replacingOccurrences(of: "b.o.p", with: "bop")
            .replacingOccurrences(of: "bleeding on probing", with: "bop")
            .replacingOccurrences(of: "bleeding or probing", with: "bop")
            .replacingOccurrences(of: "probing depth", with: "poket")
            
        var words = cleaned.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        
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
        
        var sentenceWords: [String] = []
        let rawWords = text.components(separatedBy: .whitespacesAndNewlines)
        for w in rawWords {
            let lower = w.lowercased()
            let cleaned = String(lower.compactMap { $0.isLetter || $0.isNumber ? $0 : nil })
            if !cleaned.isEmpty {
                sentenceWords.append(cleaned)
            }
        }
        
        var splitWords: [String] = []
        for word in words {
            if let num = Int(word), num >= 100 {
                for ch in word {
                    splitWords.append(String(ch))
                }
            } else {
                splitWords.append(word)
            }
        }
        
        return splitWords.joined(separator: " ")
    }
}

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
        
        var tokens: [VoiceToken] = []
        var state = MLTokenizerState(activeMetric: 0, priorLabels: [41, 41, 41], contextWindow: [])
        
        let sentences = text.lowercased()
            .replacingOccurrences(of: #"(?<=\d)\.(?=\d)"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: ".", with: " _sep_ ")
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "\n", with: " _sep_ ")
            .replacingOccurrences(of: "\r", with: " ")
            .components(separatedBy: "_sep_")
        
        for sentence in sentences {
            let words = sentence
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
            
            if words.isEmpty {
                tokens.append(.word("_sep_"))
                state = MLTokenizerState(activeMetric: state.activeMetric, priorLabels: [41, 41, 41], contextWindow: [])
                continue
            }
            
            let count = words.count
            for i in 0..<count {
                let word = words[i]
                
                let cleaned = String(word.compactMap { $0.isLetter || $0.isNumber ? $0 : nil })
                if cleaned.isEmpty { continue }
                
                let contextStart = max(0, i - 10)
                let contextEnd = min(count - 1, i + 5)
                let contextWords = Array(words[contextStart...contextEnd])
                let localWordIndex = i - contextStart
                
                if let token = mlTokenizer.predict(wordIndex: localWordIndex, context: contextWords, state: &state, originalWord: cleaned) {
                    // Filter out spurious furcation prediction for "mesio", "disto", etc.
                    if cleaned == "mesio" || cleaned == "disto" || cleaned == "bukal" || cleaned == "lingual" || cleaned == "palatal" {
                        if case .metric(let op, _) = token, op == .furcation {
                            continue
                        }
                    }
                    
                    if let lastToken = tokens.last {
                        if case .anatomy(let lastAnat) = lastToken, case .anatomy(let currAnat) = token, lastAnat == currAnat { continue }
                        if case .action(let lastAct) = lastToken, case .action(let currAct) = token, lastAct == currAct { continue }
                        if case .metric(let lastMet, _) = lastToken, case .metric(let currMet, _) = token, lastMet == currMet { continue }
                    }
                    tokens.append(token)
                }
            }
            tokens.append(.word("_sep_"))
            state = MLTokenizerState(activeMetric: state.activeMetric, priorLabels: [41, 41, 41], contextWindow: [])
        }
        
        var processedTokens: [VoiceToken] = []
        var tIdx = 0
        while tIdx < tokens.count {
            let token = tokens[tIdx]
            
            // Re-inflate double numbers like 22 -> 2, 2
            if case .number(let n) = token, n >= 11, n % 11 == 0, tIdx > 0 {
                if let last = processedTokens.last, case .number(_) = last {
                    processedTokens.append(.number(n / 11))
                    processedTokens.append(.number(n / 11))
                    tIdx += 1
                    continue
                }
            }
            
            // Legacy generic number to tooth ID mapping (e.g. "47" parsed as number)
            if case .number(let n) = token, n > 10 && n < 99 {
                processedTokens.append(.toothIdentifier(n))
                tIdx += 1
                continue
            }
            
            // Map "dari" and "sampai" words to actions
            if case .word(let w) = token {
                if w == "dari" || w == "mulai" {
                    processedTokens.append(.action(.from))
                    tIdx += 1
                    continue
                } else if w == "sampai" || w == "hingga" || w == "ke" {
                    processedTokens.append(.action(.until))
                    tIdx += 1
                    continue
                }
            }
            
            // Stitch consecutive single-digit tooth identifiers (e.g. [tooth(4), tooth(7)] -> tooth(47))
            // Also stitch number(4) + number(7) if context implies it's a tooth ID
            let isSingleDigit = { (t: VoiceToken) -> Int? in
                if case .toothIdentifier(let d) = t, d >= 1 && d <= 8 { return d }
                if case .number(let d) = t, d >= 1 && d <= 8 { return d }
                return nil
            }
            
            if let d1 = isSingleDigit(token) {
                if tIdx + 1 < tokens.count, let d2 = isSingleDigit(tokens[tIdx+1]) {
                    let isFirstDigitNumber = {
                        if case .number(_) = token { return true }
                        return false
                    }()
                    
                    var shouldStitch = false
                    
                    if !isFirstDigitNumber {
                        shouldStitch = true
                    } else {
                        var prevToken: VoiceToken? = nil
                        for pIdx in stride(from: processedTokens.count - 1, through: 0, by: -1) {
                            if case .word(let w) = processedTokens[pIdx], w == "_sep_" { continue }
                            prevToken = processedTokens[pIdx]
                            break
                        }
                        
                        var nextToken: VoiceToken? = nil
                        for nIdx in stride(from: tIdx + 2, to: tokens.count, by: 1) {
                            if case .word(let w) = tokens[nIdx], w == "_sep_" { continue }
                            nextToken = tokens[nIdx]
                            break
                        }
                        
                        if prevToken == nil {
                            shouldStitch = true
                        } else if case .word(let w) = prevToken!, w.lowercased() == "gigi" || w.lowercased() == "gigi_" {
                            shouldStitch = true
                        } else if case .action(let act) = prevToken!, (act == .from || act == .until) {
                            shouldStitch = true
                        } else if let next = nextToken {
                            if case .anatomy(_) = next {
                                shouldStitch = true
                            } else if case .action(let act) = next, act == .missing {
                                shouldStitch = true
                            } else {
                                shouldStitch = false
                            }
                        } else {
                            shouldStitch = false
                        }
                        
                        if let prev = prevToken {
                            if case .anatomy(_) = prev {
                                if let next = nextToken, case .action(let act) = next, (act == .until || act == .from) {
                                    shouldStitch = true
                                } else if let next = nextToken, case .word(let w) = next, (w == "sampai" || w == "hingga" || w == "ke") {
                                    shouldStitch = true
                                } else {
                                    shouldStitch = false
                                }
                            } else if case .metric(_, _) = prev {
                                shouldStitch = false
                            }
                        }
                    }
                    
                    if shouldStitch {
                        processedTokens.append(.toothIdentifier(d1 * 10 + d2))
                        tIdx += 2
                        continue
                    }
                }
            }
            
            processedTokens.append(token)
            tIdx += 1
        }
        
        return processedTokens
    }
}

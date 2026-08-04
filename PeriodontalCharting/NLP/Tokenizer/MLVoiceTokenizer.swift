import Foundation
import CoreML

class BertTokenizer {
    private var vocab: [String: Int] = [:]
    let unkTokenId = 1
    let clsTokenId = 2
    let sepTokenId = 3
    let padTokenId = 0
    
    init(vocabURL: URL) {
        if let text = try? String(contentsOf: vocabURL, encoding: .utf8) {
            let lines = text.components(separatedBy: .newlines)
            for (i, line) in lines.enumerated() {
                if !line.isEmpty {
                    vocab[line] = i
                }
            }
        }
    }
    
    func encode(word: String) -> [Int] {
        var tokens: [Int] = []
        let w = word.lowercased()
        var start = w.startIndex
        while start < w.endIndex {
            var end = w.endIndex
            var found = false
            while start < end {
                let sub = String(w[start..<end])
                let prefix = (start == w.startIndex) ? sub : "##\(sub)"
                if let id = vocab[prefix] {
                    tokens.append(id)
                    start = end
                    found = true
                    break
                }
                end = w.index(before: end)
            }
            if !found {
                tokens.append(unkTokenId)
                start = w.index(after: start) // Just skip 1 char for unknown
            }
        }
        return tokens
    }
}

struct MLTokenizerState: Sendable {
    var activeMetric: String
    var priorLabels: [String]
    var contextWindow: [String]
    
    init(activeMetric: String = "PAD", priorLabels: [String] = ["PAD", "PAD", "PAD"], contextWindow: [String] = []) {
        self.activeMetric = activeMetric
        self.priorLabels = priorLabels
        self.contextWindow = contextWindow
    }
}

class MLVoiceTokenizer {
    private let model: VoiceTokenizerModel
    private let bertTokenizer: BertTokenizer
    
    private let maxLen = 32
    
    // Extracted from train_phase1.py
    private let validLabels = [
        "NUMBER", "SIGNED_NUMBER", "TOOTH_MARKER", "TOOTH_ID", "METRIC_PD", 
        "METRIC_GM_NEG", "METRIC_GM_POS", "METRIC_BOP", "METRIC_PLAQUE", 
        "METRIC_MOBILITY", "METRIC_FURCATION", "METRIC_IMPLANT", 
        "ANAT_MESIOBUCCAL", "ANAT_DISTOBUCCAL", "ANAT_MIDBUCCAL", "ANAT_MESIOPALATAL", 
        "ANAT_DISTOPALATAL", "ANAT_MIDPALATAL", "ANAT_MESIOLINGUAL", "ANAT_DISTOLINGUAL", 
        "ANAT_MIDLINGUAL", "ANAT_MESIOLABIAL", "ANAT_DISTOLABIAL", "ANAT_MIDLABIAL", 
        "ANAT_MESIAL", "ANAT_DISTAL", "ANAT_BUCCAL", "ANAT_LINGUAL", "ANAT_PALATAL", 
        "ANAT_LABIAL", "ACTION_COMMIT", "ACTION_MISSING", "ACTION_FROM", "ACTION_UNTIL", 
        "ACTION_AT", "ACTION_ALL", "JAW_UPPER", "JAW_LOWER", "SIGN_MINUS", "SEPARATOR", 
        "FILLER", "PAD"
    ]
    
    private let metrics = ["METRIC_PD", "METRIC_GM_NEG", "METRIC_GM_POS", "METRIC_BOP", "METRIC_PLAQUE", "METRIC_MOBILITY", "METRIC_FURCATION", "METRIC_IMPLANT", "PAD"]
    
    private var labelToId: [String: Int] = [:]
    private var metricToId: [String: Int] = [:]
    
    // Cached CoreML Inputs
    private let inputIdsMulti: MLMultiArray
    private let maskMulti: MLMultiArray
    private let targetIdxMulti: MLMultiArray
    private let activeMetricMulti: MLMultiArray
    private let priorLabelsMulti: MLMultiArray
    
    // Raw C-Pointers for fast assignments
    private let inputIdsPtr: UnsafeMutablePointer<Int32>
    private let maskPtr: UnsafeMutablePointer<Int32>
    private let targetIdxPtr: UnsafeMutablePointer<Int32>
    private let activeMetricPtr: UnsafeMutablePointer<Int32>
    private let priorLabelsPtr: UnsafeMutablePointer<Int32>
    
    private let inferenceLock = NSLock()
    
    init?(modelURL: URL) {
        do {
            let config = MLModelConfiguration()
            self.model = try VoiceTokenizerModel(contentsOf: modelURL, configuration: config)
            
            // Look for vocab.txt in the same directory as the model or main bundle
            if let vocabURL = Bundle.main.url(forResource: "vocab", withExtension: "txt") {
                self.bertTokenizer = BertTokenizer(vocabURL: vocabURL)
            } else {
                print("vocab.txt not found in bundle!")
                return nil
            }
            
            for (i, label) in validLabels.enumerated() { labelToId[label] = i }
            for (i, metric) in metrics.enumerated() { metricToId[metric] = i }
            
            // Pre-allocate MultiArrays to prevent thrashing
            inputIdsMulti = try MLMultiArray(shape: [1, NSNumber(value: maxLen)], dataType: .int32)
            maskMulti = try MLMultiArray(shape: [1, NSNumber(value: maxLen)], dataType: .int32)
            targetIdxMulti = try MLMultiArray(shape: [1], dataType: .int32)
            activeMetricMulti = try MLMultiArray(shape: [1], dataType: .int32)
            priorLabelsMulti = try MLMultiArray(shape: [1, 3], dataType: .int32)
            
            inputIdsPtr = inputIdsMulti.dataPointer.bindMemory(to: Int32.self, capacity: maxLen)
            maskPtr = maskMulti.dataPointer.bindMemory(to: Int32.self, capacity: maxLen)
            targetIdxPtr = targetIdxMulti.dataPointer.bindMemory(to: Int32.self, capacity: 1)
            activeMetricPtr = activeMetricMulti.dataPointer.bindMemory(to: Int32.self, capacity: 1)
            priorLabelsPtr = priorLabelsMulti.dataPointer.bindMemory(to: Int32.self, capacity: 3)
            
        } catch {
            print("Failed to initialize MLVoiceTokenizer:", error)
            return nil
        }
    }
    
    func tokenize(text: String, isFinal: Bool = false, sessionState: inout MLTokenizerState) -> [VoiceToken] {
        var outputTokens: [VoiceToken] = []
        
        let cleaned = text
        let words = cleaned.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        
        var i = 0
        while i < words.count {
            let word = words[i]
            if word == "_sep_" {
                outputTokens.append(.word("_sep_"))
                sessionState.contextWindow.removeAll()
                sessionState.priorLabels = ["PAD", "PAD", "PAD"]
                sessionState.activeMetric = "PAD"
                i += 1
                continue
            }
            
            // Predict label for word
            sessionState.contextWindow.append(word)
            if sessionState.contextWindow.count > 10 { // Keep context window reasonable
                sessionState.contextWindow.removeFirst()
            }
            
            inferenceLock.lock()
            let label = predict(targetIndex: sessionState.contextWindow.count - 1, sessionState: sessionState)
            inferenceLock.unlock()
            
            print("ML_DEBUG: word='\(word)' label='\(label)'")
            let parsedTokens = mapLabelToVoiceTokens(label: label, word: word, lastToken: outputTokens.last)
            
            if label != "FILLER" && label != "PAD" && label != "SEPARATOR" {
                sessionState.priorLabels.append(label)
                if sessionState.priorLabels.count > 3 {
                    sessionState.priorLabels.removeFirst()
                }
            }
            
            if metrics.contains(label) {
                sessionState.activeMetric = label
            }
            
            if !parsedTokens.isEmpty {
                for token in parsedTokens {
                    if let last = outputTokens.last, last == token {
                        switch token {
                        case .action, .anatomy, .metric:
                            // Deduplicate consecutive identical actions/anatomies/metrics
                            // because multi-word phrases (e.g. "gak ada") emit the same token multiple times.
                            continue
                        default:
                            break
                        }
                    }
                    outputTokens.append(token)
                }
            }
            i += 1
        }
        
        print("ML_FINAL_TOKENS: \(outputTokens)")
        return outputTokens
    }
    
    private func predict(targetIndex: Int, sessionState: MLTokenizerState) -> String {
        var inputIds = [bertTokenizer.clsTokenId]
        var targetTokenIdx = 1
        
        for (i, word) in sessionState.contextWindow.enumerated() {
            let tokens = bertTokenizer.encode(word: word)
            if i == targetIndex {
                targetTokenIdx = inputIds.count
            }
            inputIds.append(contentsOf: tokens)
        }
        
        inputIds.append(bertTokenizer.sepTokenId)
        
        if inputIds.count > maxLen {
            inputIds = Array(inputIds.prefix(maxLen))
            if targetTokenIdx >= maxLen {
                targetTokenIdx = maxLen - 1
            }
        }
        
        var attentionMask = Array(repeating: Int32(1), count: inputIds.count)
        
        while inputIds.count < maxLen {
            inputIds.append(bertTokenizer.padTokenId)
            attentionMask.append(Int32(0))
        }
        
        // Fast assignment using C-pointers
        for i in 0..<maxLen {
            inputIdsPtr[i] = Int32(inputIds[i])
            maskPtr[i] = Int32(attentionMask[i])
        }
        
        targetIdxPtr[0] = Int32(targetTokenIdx)
        
        let mId = metricToId[sessionState.activeMetric] ?? (metrics.count - 1)
        activeMetricPtr[0] = Int32(mId)
        
        for (i, pLabel) in sessionState.priorLabels.enumerated() {
            let lId = labelToId[pLabel] ?? labelToId["PAD"]!
            priorLabelsPtr[i] = Int32(lId)
        }
        
        do {
            let prediction = try model.prediction(
                input_ids: inputIdsMulti,
                attention_mask: maskMulti,
                target_token_idx: targetIdxMulti,
                active_metric_id: activeMetricMulti,
                prior_label_ids: priorLabelsMulti
            )
            
            // Find argmax of logits
            let logits = prediction.logits
            let logitsPtr = logits.dataPointer.bindMemory(to: Float32.self, capacity: validLabels.count)
            
            var maxVal: Float32 = -Float32.greatestFiniteMagnitude
            var maxIdx = 0
            
            for i in 0..<validLabels.count {
                let val = logitsPtr[i]
                if val > maxVal {
                    maxVal = val
                    maxIdx = i
                }
            }
            
            return validLabels[maxIdx]
            
        } catch {
            print("Prediction error:", error)
            return "FILLER"
        }
    }
    
    private func parseIntOrWord(_ word: String) -> Int? {
        let cleanWord = word.trimmingCharacters(in: CharacterSet.punctuationCharacters)
        if let num = Int(cleanWord) { return num }
        if let num = VoiceTokenizer.numberWords[cleanWord] { return num }
        return nil
    }
    
    private func mapLabelToVoiceTokens(label: String, word: String, lastToken: VoiceToken?) -> [VoiceToken] {
        switch label {
        case "NUMBER":
            if let n = parseIntOrWord(word) {
                // Handle Whisper artifact where spoken run "3 3 3" becomes "333"
                if n >= 100 {
                    var splitTokens: [VoiceToken] = []
                    for ch in String(n) {
                        guard let d = ch.wholeNumberValue else { continue }
                        splitTokens.append(.number(d))
                    }
                    return splitTokens
                }
                // Repetition-artifact guard: a "doubled digit" (11, 22, … 88, 99)
                if n >= 11, n % 11 == 0, case .number = lastToken {
                    let d = n / 11
                    return [.number(d), .number(d)]
                }
                return [.number(n)]
            }
            return []
            
        case "SIGNED_NUMBER":
            if let n = parseIntOrWord(word) { return [.number(-n)] }
            return []
            
        case "TOOTH_ID":
            if let n = parseIntOrWord(word) {
                if n < 11 {
                    return [.number(n)]
                }
                return [.toothIdentifier(n)]
            }
            return []
            
        case "TOOTH_MARKER": return [.word(word)]
            
        case "METRIC_PD": return [.metric(.probingDepth, multiplier: 1)]
        case "METRIC_GM_NEG": return [.metric(.gingivalMargin, multiplier: -1)]
        case "METRIC_GM_POS": return [.metric(.gingivalMargin, multiplier: 1)]
        case "METRIC_BOP": return [.metric(.bleeding, multiplier: 1)]
        case "METRIC_PLAQUE": return [.metric(.plaque, multiplier: 1)]
        case "METRIC_MOBILITY": return [.metric(.mobility, multiplier: 1)]
        case "METRIC_FURCATION": return [.metric(.furcation, multiplier: 1)]
        case "METRIC_IMPLANT": return [.metric(.implant, multiplier: 1)]
        case "METRIC_MISSING": return [.metric(.missing, multiplier: 1)]
            
        case "ANAT_MESIOBUCCAL": return [.anatomy(.mesioBuccal)]
        case "ANAT_DISTOBUCCAL": return [.anatomy(.distoBuccal)]
        case "ANAT_MIDBUCCAL": return [.anatomy(.midBuccal)]
        case "ANAT_MESIOPALATAL": return [.anatomy(.mesioPalatal)]
        case "ANAT_DISTOPALATAL": return [.anatomy(.distoPalatal)]
        case "ANAT_MIDPALATAL": return [.anatomy(.midPalatal)]
        case "ANAT_MESIOLINGUAL": return [.anatomy(.mesioLingual)]
        case "ANAT_DISTOLINGUAL": return [.anatomy(.distoLingual)]
        case "ANAT_MIDLINGUAL": return [.anatomy(.midLingual)]
        case "ANAT_MESIOLABIAL": return [.anatomy(.mesioLabial)]
        case "ANAT_DISTOLABIAL": return [.anatomy(.distoLabial)]
        case "ANAT_MIDLABIAL": return [.anatomy(.midLabial)]
        
        case "ANAT_MESIAL": return [.anatomy(.mesial)]
        case "ANAT_DISTAL": return [.anatomy(.distal)]
        case "ANAT_BUCCAL": return [.anatomy(.buccal)]
        case "ANAT_LINGUAL": return [.anatomy(.lingual)]
        case "ANAT_PALATAL": return [.anatomy(.palatal)]
        case "ANAT_LABIAL": return [.anatomy(.labial)]
            
        case "ACTION_FROM": return [.action(.from)]
        case "ACTION_UNTIL": return [.action(.until)]
        case "ACTION_MISSING": return [.action(.missing)]
        case "ACTION_COMMIT": return [.action(.commit)]
        case "ACTION_AT": return [.action(.at)]
        case "ACTION_ALL": return [.action(.all)]
            
        case "JAW_UPPER": return [.anatomy(.upperJaw)]
        case "JAW_LOWER": return [.anatomy(.lowerJaw)]
            
        case "SIGN_MINUS": return [.word("minus")]
            
        case "FILLER": return []
        case "SEPARATOR": return [.word("_sep_")]
            
        default:
            return []
        }
    }
}

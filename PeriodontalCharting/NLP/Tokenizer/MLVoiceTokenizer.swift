import Foundation
import CoreML

final class MLVoiceTokenizer: @unchecked Sendable {
    private var model: MLModel?
    private let bertTokenizer = BertTokenizer()
    private let inferenceLock = NSLock()
    
    // CoreML pre-allocated buffers
    private var inputIdsBuffer: MLMultiArray?
    private var attentionMaskBuffer: MLMultiArray?
    private var targetTokenIdxBuffer: MLMultiArray?
    private var activeMetricIdBuffer: MLMultiArray?
    private var priorLabelIdsBuffer: MLMultiArray?
    
    private let maxLen = 32
    
    static let validLabels = [
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
    
    init() {
        var vocabURL = Bundle.main.url(forResource: "vocab", withExtension: "txt")
        #if DEBUG
        if vocabURL == nil {
            vocabURL = URL(fileURLWithPath: "/Users/vio/PycharmProjects/Periodontology/PeriodontalCharting/PeriodontalCharting/AI/vocab.txt")
        }
        #endif
        
        var modelURL = Bundle.main.url(forResource: "VoiceTokenizerModel", withExtension: "mlmodelc")
        #if DEBUG
        if modelURL == nil {
            modelURL = URL(fileURLWithPath: "/Users/vio/PycharmProjects/Periodontology/PeriodontalCharting/VoiceTokenizerModel.mlmodelc")
        }
        #endif
        
        if let modelURL = modelURL {
            do {
                let config = MLModelConfiguration()
                self.model = try MLModel(contentsOf: modelURL, configuration: config)
                setupBuffers()
            } catch {
                print("Failed to load VoiceTokenizerModel: \(error)")
                self.model = nil
            }
        } else {
            print("VoiceTokenizerModel.mlmodelc not found in bundle or fallback path.")
            self.model = nil
        }
    }
    
    private func setupBuffers() {
        do {
            inputIdsBuffer = try MLMultiArray(shape: [1, NSNumber(value: maxLen)], dataType: .int32)
            attentionMaskBuffer = try MLMultiArray(shape: [1, NSNumber(value: maxLen)], dataType: .int32)
            targetTokenIdxBuffer = try MLMultiArray(shape: [1], dataType: .int32)
            activeMetricIdBuffer = try MLMultiArray(shape: [1], dataType: .int32)
            priorLabelIdsBuffer = try MLMultiArray(shape: [1, 3], dataType: .int32)
        } catch {
            print("Failed to initialize MLMultiArray buffers: \(error)")
        }
    }
    
    func predict(wordIndex: Int, context: [String], state: inout MLTokenizerState, originalWord: String) -> VoiceToken? {
        guard let model = model,
              let inputIdsBuffer = inputIdsBuffer,
              let attentionMaskBuffer = attentionMaskBuffer,
              let targetTokenIdxBuffer = targetTokenIdxBuffer,
              let activeMetricIdBuffer = activeMetricIdBuffer,
              let priorLabelIdsBuffer = priorLabelIdsBuffer else {
            return mapLabelToVoiceTokens(label: "FILLER", word: originalWord, state: &state)
        }
        
        inferenceLock.lock()
        defer { inferenceLock.unlock() }
        
        // Encode context
        var inputIds: [Int] = [bertTokenizer.clsTokenId]
        var targetIdx = 1
        
        for (i, word) in context.enumerated() {
            let tokens = bertTokenizer.encode(word)
            if i == wordIndex {
                targetIdx = inputIds.count
            }
            inputIds.append(contentsOf: tokens)
        }
        inputIds.append(bertTokenizer.sepTokenId)
        
        if inputIds.count > maxLen {
            let keepCount = maxLen - 2
            let sliceStart = inputIds.count - 1 - keepCount
            let sliced = inputIds[sliceStart..<(inputIds.count - 1)]
            inputIds = [inputIds[0]] + Array(sliced) + [inputIds.last!]
            
            if targetIdx <= sliceStart {
                targetIdx = 1 // target word truncated, point to first word
            } else {
                targetIdx = targetIdx - sliceStart + 1
            }
        }
        
        var attentionMask: [Int] = Array(repeating: 1, count: inputIds.count)
        
        while inputIds.count < maxLen {
            inputIds.append(bertTokenizer.padTokenId)
            attentionMask.append(0)
        }
        
        // Fill buffers using fast pointer access
        let inputIdsPtr = inputIdsBuffer.dataPointer.bindMemory(to: Int32.self, capacity: maxLen)
        let attentionMaskPtr = attentionMaskBuffer.dataPointer.bindMemory(to: Int32.self, capacity: maxLen)
        
        for i in 0..<maxLen {
            inputIdsPtr[i] = Int32(inputIds[i])
            attentionMaskPtr[i] = Int32(attentionMask[i])
        }
        
        let targetTokenPtr = targetTokenIdxBuffer.dataPointer.bindMemory(to: Int32.self, capacity: 1)
        targetTokenPtr[0] = Int32(targetIdx)
        
        let activeMetricPtr = activeMetricIdBuffer.dataPointer.bindMemory(to: Int32.self, capacity: 1)
        activeMetricPtr[0] = Int32(state.activeMetric)
        
        let priorLabelsPtr = priorLabelIdsBuffer.dataPointer.bindMemory(to: Int32.self, capacity: 3)
        for i in 0..<3 {
            priorLabelsPtr[i] = Int32(state.priorLabels[i])
        }
        
        // Predict
        do {
            let featureProvider = try MLDictionaryFeatureProvider(dictionary: [
                "input_ids": inputIdsBuffer,
                "attention_mask": attentionMaskBuffer,
                "target_token_idx": targetTokenIdxBuffer,
                "active_metric_id": activeMetricIdBuffer,
                "prior_label_ids": priorLabelIdsBuffer
            ])
            
            let output = try model.prediction(from: featureProvider)
            if let outputName = output.featureNames.first,
               let outputMultiArray = output.featureValue(for: outputName)?.multiArrayValue {
                
                let outputPtr = outputMultiArray.dataPointer.bindMemory(to: Float32.self, capacity: MLVoiceTokenizer.validLabels.count)
                var maxIndex = 0
                var maxValue: Float32 = -Float32.greatestFiniteMagnitude
                
                for i in 0..<MLVoiceTokenizer.validLabels.count {
                    let val = outputPtr[i]
                    if val > maxValue {
                        maxValue = val
                        maxIndex = i
                    }
                }
                
                let predictedLabel = MLVoiceTokenizer.validLabels[maxIndex]
                
                // Update state
                if predictedLabel == "METRIC_PD" { state.activeMetric = 0 }
                else if predictedLabel == "METRIC_GM_NEG" { state.activeMetric = 1 }
                else if predictedLabel == "METRIC_GM_POS" { state.activeMetric = 2 }
                else if predictedLabel == "METRIC_BOP" { state.activeMetric = 3 }
                else if predictedLabel == "METRIC_PLAQUE" { state.activeMetric = 4 }
                else if predictedLabel == "METRIC_MOBILITY" { state.activeMetric = 5 }
                else if predictedLabel == "METRIC_FURCATION" { state.activeMetric = 6 }
                else if predictedLabel == "METRIC_IMPLANT" { state.activeMetric = 7 }
                
                if predictedLabel != "FILLER" && predictedLabel != "PAD" && predictedLabel != "SEPARATOR" {
                    state.priorLabels.removeFirst()
                    state.priorLabels.append(maxIndex)
                }
                
                
                if predictedLabel == "SIGN_MINUS" {
                    state.pendingNegative = true
                    return nil
                }
                
                return mapLabelToVoiceTokens(label: predictedLabel, word: originalWord, state: &state)
            }
        } catch {
            print("Prediction failed: \(error)")
        }
        
        return mapLabelToVoiceTokens(label: "FILLER", word: originalWord, state: &state)
    }
    
    private func parseNumber(_ word: String) -> Int? {
        if let num = Int(word) { return num }
        let map: [String: Int] = [
            "nol": 0, "satu": 1, "dua": 2, "tiga": 3, "empat": 4, 
            "lima": 5, "enam": 6, "tujuh": 7, "delapan": 8, "sembilan": 9, "sepuluh": 10
        ]
        return map[word.lowercased()]
    }

    private func mapLabelToVoiceTokens(label: String, word: String, state: inout MLTokenizerState) -> VoiceToken? {
        switch label {
        case "NUMBER":
            if let num = parseNumber(word) { 
                let finalNum = state.pendingNegative ? -num : num
                state.pendingNegative = false
                return .number(finalNum) 
            }
            return .word(word)
        case "SIGNED_NUMBER":
            if let num = parseNumber(word) { return .number(-num) }
            return .word(word)
        case "TOOTH_ID":
            if let num = parseNumber(word) { return .toothIdentifier(num) }
            return .word(word)
        case "METRIC_PD": return .metric(.probingDepth, multiplier: 1)
        case "METRIC_GM_NEG": return .metric(.gingivalMargin, multiplier: -1)
        case "METRIC_GM_POS": return .metric(.gingivalMargin, multiplier: 1)
        case "METRIC_BOP": return .metric(.bleeding, multiplier: 1)
        case "METRIC_PLAQUE": return .metric(.plaque, multiplier: 1)
        case "METRIC_MOBILITY": return .metric(.mobility, multiplier: 1)
        case "METRIC_FURCATION": return .metric(.furcation, multiplier: 1)
        case "METRIC_IMPLANT": return .metric(.implant, multiplier: 1)
        case "ANAT_MESIOBUCCAL": return .anatomy(.mesioBuccal)
        case "ANAT_DISTOBUCCAL": return .anatomy(.distoBuccal)
        case "ANAT_MIDBUCCAL": return .anatomy(.midBuccal)
        case "ANAT_MESIOPALATAL": return .anatomy(.mesioPalatal)
        case "ANAT_DISTOPALATAL": return .anatomy(.distoPalatal)
        case "ANAT_MIDPALATAL": return .anatomy(.midPalatal)
        case "ANAT_MESIOLINGUAL": return .anatomy(.mesioLingual)
        case "ANAT_DISTOLINGUAL": return .anatomy(.distoLingual)
        case "ANAT_MIDLINGUAL": return .anatomy(.midLingual)
        case "ANAT_MESIOLABIAL": return .anatomy(.mesioBuccal)
        case "ANAT_DISTOLABIAL": return .anatomy(.distoBuccal)
        case "ANAT_MIDLABIAL": return .anatomy(.midLabial)
        case "ANAT_MESIAL": return .anatomy(.mesial)
        case "ANAT_DISTAL": return .anatomy(.distal)
        case "ANAT_BUCCAL": return .anatomy(.buccal)
        case "ANAT_LINGUAL": return .anatomy(.lingual)
        case "ANAT_PALATAL": return .anatomy(.palatal)
        case "ANAT_LABIAL": return .anatomy(.labial)
        case "ACTION_COMMIT": return .action(.commit)
        case "ACTION_MISSING": return .action(.missing)
        case "ACTION_FROM": return .action(.from)
        case "ACTION_UNTIL": return .action(.until)
        case "ACTION_AT": return .action(.at)
        case "ACTION_ALL": return .action(.all)
        case "JAW_UPPER": return .anatomy(.upperJaw)
        case "JAW_LOWER": return .anatomy(.lowerJaw)
        case "TOOTH_MARKER", "SEPARATOR": return nil
        case "FILLER", "PAD":
            return .word(word)
        default:
            return .word(word)
        }
    }
}

import Foundation

struct BeamState: Hashable {
    var text: String
    var lastCharIndex: Int
}

struct Beam {
    var text: String
    var lastCharIndex: Int
    var probBlank: Float
    var probNonBlank: Float
    var lastSpaceFrame: Int
    
    var wordCosts: [Float]
    var currentWordCost: Float
    
    var totalProb: Float {
        // Log sum exp approximation: max(a, b)
        return max(probBlank, probNonBlank)
    }
    
    var state: BeamState {
        return BeamState(text: text, lastCharIndex: lastCharIndex)
    }
}

class CTCDecoder {

    // The bar a word must clear to survive.
    static let maxCostPerFrame: Float = 2.0

    var labels: [String] = []
    let trie: PrefixTrie
    var blankIndex: Int = 27 // [PAD] in original vocab
    var spaceIndex: Int = 6  // '|' is often space in wav2vec2, we need to map it to " "
    
    var dynamicMapping: [String: String] = [:]
    
    init(vocabPath: String, lexiconPath: String) {
        self.trie = PrefixTrie(lexiconPath: lexiconPath)
        loadVocab(path: vocabPath)
    }
    
    init(vocabPath: String, trie: PrefixTrie, dynamicMapping: [String: String]) {
        self.trie = trie
        self.dynamicMapping = dynamicMapping
        loadVocab(path: vocabPath)
    }
    
    private func loadVocab(path: String) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Int] else {
            print("Failed to load vocab from \(path)")
            return
        }
        
        var sortedLabels = Array(repeating: "", count: json.count)
        for (char, index) in json {
            if index < sortedLabels.count {
                sortedLabels[index] = char
            }
        }
        
        // Find indices
        if let padIdx = json["[PAD]"] { self.blankIndex = padIdx }
        else if let sIdx = json["</s>"] { self.blankIndex = sIdx }
        
        if let barIdx = json["|"] { self.spaceIndex = barIdx }
        
        // Clean labels
        for i in 0..<sortedLabels.count {
            if i == self.spaceIndex {
                sortedLabels[i] = " "
            } else if sortedLabels[i].hasPrefix("[") || sortedLabels[i].hasPrefix("<") {
                sortedLabels[i] = ""
            }
        }
        
        self.labels = sortedLabels
    }
    
    private func applyLogSoftmax(to logits: [[Float]]) -> [[Float]] {
        return logits.map { step in
            let maxLogit = step.max() ?? 0
            var sumExp: Float = 0
            for val in step {
                sumExp += exp(val - maxLogit)
            }
            let logSumExp = maxLogit + log(sumExp)
            return step.map { $0 - logSumExp }
        }
    }
    
    func decode(logits: [[Float]], beamWidth: Int = 10, isLivePreview: Bool = false) -> String {
        // --- GREEDY DEBUG ---
        var greedyChars: [String] = []
        var lastGreedy = -1
        for t in 0..<logits.count {
            let stepLogits = logits[t]
            var maxIdx = 0
            var maxVal = stepLogits[0]
            for i in 1..<stepLogits.count {
                if stepLogits[i] > maxVal { maxVal = stepLogits[i]; maxIdx = i }
            }
            if maxIdx != lastGreedy && maxIdx != blankIndex && maxIdx < labels.count {
                let char = labels[maxIdx] == "|" ? " " : labels[maxIdx]
                greedyChars.append(char)
            }
            lastGreedy = maxIdx
        }
        print("GREEDY: '\(greedyChars.joined())'")
        // ---------------------

        let logProbs = applyLogSoftmax(to: logits)
        let negInf: Float = -Float.greatestFiniteMagnitude
        var beams: [BeamState: Beam] = [:]
        let initialBeam = Beam(text: "", lastCharIndex: -1, probBlank: 0.0, probNonBlank: negInf, lastSpaceFrame: -1, wordCosts: [], currentWordCost: 0.0)
        beams[initialBeam.state] = initialBeam
        
        // We need to track wordFrames to calculate costPerFrame
        var beamWordFrames: [BeamState: [Int]] = [initialBeam.state: []]
        
        for t in 0..<logProbs.count {
            let stepLogits = logProbs[t]
            let maxLogit = stepLogits.max() ?? 0.0
            
            var nextBeams: [BeamState: Beam] = [:]
            var nextBeamWordFrames: [BeamState: [Int]] = [:]
            
            for (state, beam) in beams {
                let currentWordFrames = beamWordFrames[state] ?? []
                
                // 1. Extension with blank
                let pBlank = stepLogits[blankIndex]
                if pBlank > -20.0 { // minor pruning
                    var newBeam = beam
                    newBeam.probBlank = beam.totalProb + pBlank
                    newBeam.probNonBlank = negInf
                    newBeam.lastCharIndex = -1 // Reset last char
                    
                    let newState = newBeam.state
                    if let existing = nextBeams[newState] {
                        if newBeam.totalProb > existing.totalProb {
                            newBeam.probBlank = max(newBeam.probBlank, existing.probBlank)
                            nextBeams[newState] = newBeam
                            nextBeamWordFrames[newState] = currentWordFrames
                        } else {
                            var updatedExisting = existing
                            updatedExisting.probBlank = max(updatedExisting.probBlank, newBeam.probBlank)
                            nextBeams[newState] = updatedExisting
                        }
                    } else {
                        nextBeams[newState] = newBeam
                        nextBeamWordFrames[newState] = currentWordFrames
                    }
                }
                
                // 2. Extension with characters
                for (c, label) in labels.enumerated() {
                    if c == blankIndex || label.isEmpty { continue }
                    
                    let pChar = stepLogits[c]
                    if pChar < -15.0 { continue } // prune highly unlikely chars
                    if label == " " && beam.text.hasSuffix(" ") { continue }
                    
                    var newText = beam.text
                    let isRepeat = (c == beam.lastCharIndex)
                    
                    var newLastSpaceFrame = beam.lastSpaceFrame
                    var newWordCosts = beam.wordCosts
                    var newWordFrames = currentWordFrames
                    var newCurrentWordCost = beam.currentWordCost + (maxLogit - pChar)
                    
                    if !isRepeat {
                        newText += label
                        if label == " " {
                            newLastSpaceFrame = t
                            newWordCosts.append(newCurrentWordCost)
                            newWordFrames.append(max(1, t - beam.lastSpaceFrame))
                            newCurrentWordCost = 0.0
                        }
                    }
                    
                    // Prefix Trie Constraint check!
                    var activeText = newText
                    var activeLastSpaceFrame = newLastSpaceFrame
                    var beamProbPenalty: Float = 0.0
                    
                    if !isRepeat && label == " " {
                        let words = activeText.split(separator: " ", omittingEmptySubsequences: true)
                        if let completedWord = words.last {
                            let anatomyTerms: Set<String> = ["lingual", "mesiolingual", "distolingual", "mesio", "disto", "bukal", "mesiobukal", "distobukal", "palatal", "mesiopalatal", "distopalatal", "labial", "mesial", "distal", "gigi", "gak", "missing", "misin", "bleeding", "bop", "plak", "plaque", "pocket", "resesi", "recession", "kalkulus", "karang", "implan", "implant", "probing"]
                            
                            if anatomyTerms.contains(String(completedWord)) {
                                beamProbPenalty -= 20.0 // Strong anatomy/action bonus
                            }
                            
                            // Phrase boost for missing commands
                            if words.count >= 2 {
                                let lastTwo = String(words[words.count - 2]) + " " + String(completedWord)
                                if lastTwo == "gak ada" || lastTwo == "tidak ada" {
                                    beamProbPenalty -= 20.0
                                }
                            }
                        }
                    } else if !isRepeat && label != " " {
                        if let currentWord = activeText.split(separator: " ", omittingEmptySubsequences: true).last {
                            let anatomyTerms = ["lingual", "mesiolingual", "distolingual", "mesio", "disto", "bukal", "mesiobukal", "distobukal", "palatal", "mesiopalatal", "distopalatal", "labial", "mesial", "distal", "gigi", "gak", "missing", "misin", "bleeding", "bop", "plak", "plaque", "pocket", "resesi", "recession", "kalkulus", "karang", "implan", "implant", "probing"]
                            
                            let currentStr = String(currentWord)
                            if currentStr.count >= 2 && anatomyTerms.contains(where: { $0.hasPrefix(currentStr) }) {
                                beamProbPenalty -= 2.0 // Running prefix boost
                            }
                        }
                    }
                    
                    if !isRepeat {
                        if !trie.isValidPrefix(sequence: activeText) {
                            // Try implicit space injection if the current word is fully formed
                            let words = beam.text.split(separator: " ", omittingEmptySubsequences: true)
                            if let lastWord = words.last, trie.isWord(String(lastWord)) {
                                let altText = beam.text + " " + label
                                if trie.isValidPrefix(sequence: altText) {
                                    activeText = altText
                                    activeLastSpaceFrame = t
                                    beamProbPenalty = 2.0 // Penalize fracturing
                                    
                                    let anatomyTerms: Set<String> = ["lingual", "mesiolingual", "distolingual", "mesio", "disto", "bukal", "mesiobukal", "distobukal", "palatal", "mesiopalatal", "distopalatal", "labial", "mesial", "distal", "gigi", "gak", "missing", "misin", "bleeding", "bop", "plak", "plaque", "pocket", "resesi", "recession", "kalkulus", "karang", "implan", "implant", "probing"]
                                    if anatomyTerms.contains(String(lastWord)) {
                                        beamProbPenalty -= 20.0 // Strong anatomy bonus overrides fracture penalty
                                    }
                                    
                                    if words.count >= 2 {
                                        let lastTwo = String(words[words.count - 2]) + " " + String(lastWord)
                                        if lastTwo == "gak ada" || lastTwo == "tidak ada" {
                                            beamProbPenalty -= 20.0
                                        }
                                    }
                                    
                                    // Implicit space was injected!
                                    newWordCosts = beam.wordCosts
                                    newWordCosts.append(beam.currentWordCost)
                                    newWordFrames = currentWordFrames
                                    newWordFrames.append(max(1, t - beam.lastSpaceFrame))
                                    // The new letter's cost applies to the NEXT word
                                    newCurrentWordCost = (maxLogit - pChar)
                                } else {
                                    continue
                                }
                            } else {
                                continue
                            }
                        }
                    }
                    
                    var newBeam = beam
                    newBeam.text = activeText
                    newBeam.lastCharIndex = c
                    newBeam.probBlank = negInf
                    newBeam.probNonBlank = beam.totalProb + pChar - beamProbPenalty
                    newBeam.lastSpaceFrame = activeLastSpaceFrame
                    newBeam.wordCosts = newWordCosts
                    newBeam.currentWordCost = newCurrentWordCost
                    
                    let newState = newBeam.state
                    if let existing = nextBeams[newState] {
                        if newBeam.totalProb > existing.totalProb {
                            newBeam.probNonBlank = max(newBeam.probNonBlank, existing.probNonBlank)
                            nextBeams[newState] = newBeam
                            nextBeamWordFrames[newState] = newWordFrames
                        } else {
                            var updatedExisting = existing
                            updatedExisting.probNonBlank = max(updatedExisting.probNonBlank, newBeam.probNonBlank)
                            nextBeams[newState] = updatedExisting
                        }
                    } else {
                        nextBeams[newState] = newBeam
                        nextBeamWordFrames[newState] = newWordFrames
                    }
                }
            }
            
            // Prune to beam width
            let sortedNext = nextBeams.values.sorted(by: { $0.totalProb > $1.totalProb })
            beams.removeAll(keepingCapacity: true)
            beamWordFrames.removeAll(keepingCapacity: true)
            for b in sortedNext.prefix(beamWidth) {
                beams[b.state] = b
                beamWordFrames[b.state] = nextBeamWordFrames[b.state] ?? []
            }
        }
        
        let bestBeam = beams.values.max(by: { $0.totalProb < $1.totalProb })
        let bestBeamWordFrames = beamWordFrames[bestBeam?.state ?? BeamState(text: "", lastCharIndex: -1)] ?? []
        let sortedBeams = beams.values.sorted(by: { $0.totalProb > $1.totalProb }).prefix(3)
        print("--- TOP 3 BEAMS ---")
        for (i, beam) in sortedBeams.enumerated() {
            print("Beam \(i): '\(beam.text)' (Prob: \(beam.totalProb))")
        }
        print("-------------------")
        let constrainedText = bestBeam?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lastSpaceFrame = bestBeam?.lastSpaceFrame ?? -1
        let hasTrailingSpace = bestBeam?.text.hasSuffix(" ") ?? false
        
        if constrainedText.isEmpty {
            return ""
        }
        
        var finalWords = constrainedText.split(separator: " ").map(String.init)
        var finalWordCosts = bestBeam?.wordCosts ?? []
        var finalWordFrames = bestBeamWordFrames
        if !hasTrailingSpace {
            finalWordCosts.append(bestBeam?.currentWordCost ?? 0.0)
            finalWordFrames.append(max(1, logProbs.count - lastSpaceFrame))
        }
        
        if !hasTrailingSpace {
            if let lastWord = finalWords.last, !trie.isWord(lastWord) {
                finalWords.removeLast() // Hard commit: only drop if it's an invalid partial
                if !finalWordCosts.isEmpty { finalWordCosts.removeLast() }
                if !finalWordFrames.isEmpty { finalWordFrames.removeLast() }
            }
        }
        
        // 2. Evaluate Acoustic Cost per word!
        var filteredWords: [String] = []
        for i in 0..<min(finalWords.count, finalWordCosts.count) {
            let word = finalWords[i]
            let cost = finalWordCosts[i]
            let frames = (i < finalWordFrames.count) ? finalWordFrames[i] : 1
            
            // Normalize cost by frames spanned
            let costPerFrame = cost / Float(max(1, frames))

            var threshold: Float = 1.5 // Relaxed default threshold
            
            let strictModifiers: Set<String> = ["semua", "semuanya", "seluruh", "seluruhnya", "sampai", "hingga", "tika", "tike"]
            if strictModifiers.contains(word) {
                threshold = 0.2 // Tighter threshold for strict modifiers
            }
            
            let accepted = costPerFrame <= threshold
            if accepted {
                filteredWords.append(word)
            } else {
                if !isLivePreview {
                    print("⚠️ WORD REJECTED via Acoustic Cost: '\(word)' (Cost per frame: \(costPerFrame))")
                }
            }
        }
        
        var finalString = filteredWords.joined(separator: " ")
        
        // 3. Apply canonical mapping for multi-word phrases and variants
        // Sort keys by length descending so longer phrases match first
        let sortedKeys = dynamicMapping.keys.sorted { $0.count > $1.count }
        for _ in 0..<2 {
            for key in sortedKeys {
                if finalString.contains(key) {
                    let escapedKey = NSRegularExpression.escapedPattern(for: key)
                    let pattern = "\\b\(escapedKey)\\b"
                    if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                        let range = NSRange(location: 0, length: finalString.utf16.count)
                        finalString = regex.stringByReplacingMatches(
                            in: finalString,
                            options: [],
                            range: range,
                            withTemplate: dynamicMapping[key]!
                        )
                    }
                }
            }
        }
        
        return finalString
    }
}

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
        let logProbs = applyLogSoftmax(to: logits)
        let negInf: Float = -Float.greatestFiniteMagnitude
        var beams: [BeamState: Beam] = [:]
        let initialBeam = Beam(text: "", lastCharIndex: -1, probBlank: 0.0, probNonBlank: negInf, lastSpaceFrame: -1, wordCosts: [], currentWordCost: 0.0)
        beams[initialBeam.state] = initialBeam
        
        for t in 0..<logProbs.count {
            let stepLogits = logProbs[t]
            let maxLogit = stepLogits.max() ?? 0.0
            
            var nextBeams: [BeamState: Beam] = [:]
            
            for (_, beam) in beams {
                // 1. Extension with blank
                let pBlank = stepLogits[blankIndex]
                if pBlank > -20.0 { // minor pruning
                    var newBeam = beam
                    newBeam.probBlank = beam.totalProb + pBlank
                    newBeam.probNonBlank = negInf
                    newBeam.lastCharIndex = -1 // Reset last char
                    
                    let state = newBeam.state
                    if let existing = nextBeams[state] {
                        if newBeam.totalProb > existing.totalProb {
                            newBeam.probBlank = max(newBeam.probBlank, existing.probBlank)
                            nextBeams[state] = newBeam
                        } else {
                            var updatedExisting = existing
                            updatedExisting.probBlank = max(updatedExisting.probBlank, newBeam.probBlank)
                            nextBeams[state] = updatedExisting
                        }
                    } else {
                        nextBeams[state] = newBeam
                    }
                }
                
                // 2. Extension with characters
                for (c, label) in labels.enumerated() {
                    if c == blankIndex || label.isEmpty { continue }
                    
                    let pChar = stepLogits[c]
                    if pChar < -10.0 { continue } // prune highly unlikely chars
                    
                    var newText = beam.text
                    let isRepeat = (c == beam.lastCharIndex)
                    
                    var newLastSpaceFrame = beam.lastSpaceFrame
                    var newWordCosts = beam.wordCosts
                    var newCurrentWordCost = beam.currentWordCost + (maxLogit - pChar)
                    
                    if !isRepeat {
                        newText += label
                        if label == " " {
                            newLastSpaceFrame = t
                            newWordCosts.append(newCurrentWordCost)
                            newCurrentWordCost = 0.0
                        }
                    }
                    
                    // Prefix Trie Constraint check!
                    var activeText = newText
                    var activeLastSpaceFrame = newLastSpaceFrame
                    var beamProbPenalty: Float = 0.0
                    
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
                                    
                                    // Implicit space was injected!
                                    newWordCosts = beam.wordCosts
                                    newWordCosts.append(beam.currentWordCost)
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
                    
                    let state = newBeam.state
                    if let existing = nextBeams[state] {
                        if newBeam.totalProb > existing.totalProb {
                            newBeam.probNonBlank = max(newBeam.probNonBlank, existing.probNonBlank)
                            nextBeams[state] = newBeam
                        } else {
                            var updatedExisting = existing
                            updatedExisting.probNonBlank = max(updatedExisting.probNonBlank, newBeam.probNonBlank)
                            nextBeams[state] = updatedExisting
                        }
                    } else {
                        nextBeams[state] = newBeam
                    }
                }
            }
            
            // Prune to beam width
            let sortedNext = nextBeams.values.sorted(by: { $0.totalProb > $1.totalProb })
            beams.removeAll(keepingCapacity: true)
            for b in sortedNext.prefix(beamWidth) {
                beams[b.state] = b
            }
        }
        
        let bestBeam = beams.values.max(by: { $0.totalProb < $1.totalProb })
        let constrainedText = bestBeam?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lastSpaceFrame = bestBeam?.lastSpaceFrame ?? -1
        let hasTrailingSpace = bestBeam?.text.hasSuffix(" ") ?? false
        
        if constrainedText.isEmpty {
            return ""
        }
        
        var finalWords = constrainedText.split(separator: " ").map(String.init)
        var finalWordCosts = bestBeam?.wordCosts ?? []
        if !hasTrailingSpace {
            finalWordCosts.append(bestBeam?.currentWordCost ?? 0.0)
        }
        
        if !hasTrailingSpace {
            if let lastWord = finalWords.last, !trie.isWord(lastWord) {
                finalWords.removeLast() // Hard commit: only drop if it's an invalid partial
                if !finalWordCosts.isEmpty { finalWordCosts.removeLast() }
            }
        }
        
        // 2. Evaluate Acoustic Cost per word!
        // This completely replaces Levenshtein. It strictly catches phonetic hallucinations 
        // by looking at how hard the Trie had to fight the acoustic model's top probabilities.
        var filteredWords: [String] = []
        for i in 0..<finalWords.count {
            let word = finalWords[i]
            let cost = finalWordCosts[i]
            
            // Normalize cost by word length
            let costPerLetter = cost / Float(max(1, word.count))
            
            // If the cost per letter is very high (e.g. > 4.5), it means the model was heavily fighting the dictionary.
            // i.e., it's a hallucination (like "sampai" forced out of static).
            // We enforce this on ALL inferences (including Live Preview) so the UI doesn't jitter.
            if costPerLetter <= 4.5 { 
                filteredWords.append(word)
            } else {
                print("⚠️ WORD REJECTED via Acoustic Cost: '\(word)' (Cost per letter: \(costPerLetter))")
            }
        }
        
        var finalString = filteredWords.joined(separator: " ")
        
        // 3. Apply canonical mapping for multi-word phrases and variants
        // Sort keys by length descending so longer phrases match first
        let sortedKeys = dynamicMapping.keys.sorted { $0.count > $1.count }
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
        
        return finalString
    }
}

import Foundation

struct PhoneticCorrector {
    
    // Known clinical terms and their canonical representations
    static let dictionary: Set<String> = [
        "mesio", "disto", "mesial", "distal",
        "bukal", "lingual", "palatal", "labial",
        "mesiobukal", "distobukal", "mesiopalatal", "distopalatal",
        "mesiolingual", "distolingual", "mesiolabial", "distolabial",
        "poket", "kedalaman", "resesi", "hiperplasia", "bleeding", "bop",
        "plak", "kegoyangan", "goyang", "furkasi", "implan", "mukogingival",
        "selesai", "simpan", "hilang", "cabut", "jembatan", "pontik",
        "dari", "mulai", "sampai", "hingga", "dan", "pada", "di", "bagian",
        "semua", "seluruh", "gigi", "elemen", "atas", "bawah", "rahang", "tengah",
        "satu", "dua", "tiga", "empat", "lima", "enam", "tujuh", "delapan", "sembilan", "nol", "minus", "min"
    ]
    
    // Max acceptable edit distance for correction
    static let maxDistance = 2
    
    /// Normalizes a sentence by correcting misspellings and STT errors
    static func normalize(text: String) -> String {
        let words = text.lowercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        var correctedWords: [String] = []
        
        for word in words {
            // Remove punctuation for checking
            let cleanWord = word.trimmingCharacters(in: .punctuationCharacters)
            
            if cleanWord.isEmpty {
                continue
            }
            
            // If it's a number, skip phonetic correction
            if Double(cleanWord) != nil {
                correctedWords.append(word)
                continue
            }
            
            if dictionary.contains(cleanWord) {
                correctedWords.append(word)
            } else {
                let corrected = closestMatch(for: cleanWord)
                // Preserve original punctuation if any (simple append)
                correctedWords.append(corrected)
            }
        }
        
        return correctedWords.joined(separator: " ")
    }
    
    private static func closestMatch(for word: String) -> String {
        // Quick STT mappings that Levenshtein might miss
        let manualOverrides: [String: String] = [
            "purkasi": "furkasi",
            "bocal": "bukal",
            "puket": "poket",
            "pocket": "poket",
            "buccal": "bukal",
            "rang": "rahang"
        ]
        
        if let override = manualOverrides[word] {
            return override
        }
        
        var bestMatch = word
        var minDistance = Int.max
        
        for dictWord in dictionary {
            // Optimization: Skip words with vastly different lengths
            if abs(dictWord.count - word.count) > maxDistance {
                continue
            }
            
            let dist = levenshtein(word, dictWord)
            if dist < minDistance {
                minDistance = dist
                bestMatch = dictWord
            }
        }
        
        if minDistance <= maxDistance {
            return bestMatch
        }
        
        return word
    }
    
    private static func levenshtein(_ aStr: String, _ bStr: String) -> Int {
        let a = Array(aStr)
        let b = Array(bStr)
        
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        
        var matrix = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        
        for i in 0...a.count { matrix[i][0] = i }
        for j in 0...b.count { matrix[0][j] = j }
        
        for i in 1...a.count {
            for j in 1...b.count {
                if a[i - 1] == b[j - 1] {
                    matrix[i][j] = matrix[i - 1][j - 1]
                } else {
                    matrix[i][j] = min(
                        matrix[i - 1][j] + 1,      // deletion
                        matrix[i][j - 1] + 1,      // insertion
                        matrix[i - 1][j - 1] + 1   // substitution
                    )
                }
            }
        }
        
        return matrix[a.count][b.count]
    }
}

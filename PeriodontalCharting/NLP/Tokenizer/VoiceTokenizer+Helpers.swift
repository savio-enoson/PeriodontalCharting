import Foundation

extension VoiceTokenizer {
    static func isToothPrefix(_ word: String) -> Bool {
        let w = word.lowercased()
        let prefixes = [
            "sampai", "hingga", "ke", "dan", "maupun", "gigi"
        ]
        return prefixes.contains(w)
    }

    static func parseIntOrWord(_ w: String) -> Int? {
        if let num = Int(w) { return num }
        if let num = VoiceTokenizer.numberWords[w] { return num }
        return nil
    }
    
    static func isAspectOrAction(_ word: String) -> Bool {
        let w = word.lowercased()
        let actions = [
            "missing", "gak", "tidak", "resesi", "poket", "pocket", "bop", "bleeding", "plak", "flek", "mobiliti", "furkasi", "impaksi", "sisa", "akar", "lanjut", "selesai",
            "semua", "semuanya", "seluruh", "seluruhnya", "kemudian", "selanjutnya", "berikutnya", "ada",
            "sampai", "hingga", "ke", "dan"
        ]
        let aspects = [
            "bukal", "lingual", "palatal", "labial", "mesial", "distal",
            "mesio", "disto", "mid", "tengah", "rahang", "atas", "bawah"
        ]
        return actions.contains(w) || aspects.contains(w)
    }
    
    static func hasExactlyNValues(words: [String], from index: Int, expected: Int) -> Bool {
        var valuesFound = 0
        print("DEBUG hasExactlyNValues: expected=\(expected), words=\(Array(words.suffix(from: index).prefix(5)))")
        for i in index..<words.count {
            let word = words[i].lowercased()
            if word == "_sep_" || word == "." {
                print("DEBUG hasExactlyNValues: break on \(word)")
                break
            }
            if word == "," || word == "dan" || word == "maupun" {
                continue
            }
            if let num = parseIntOrWord(word), num >= 0 && num <= 9 {
                valuesFound += 1
                print("DEBUG hasExactlyNValues: found value \(num)")
            } else {
                print("DEBUG hasExactlyNValues: break on non-value \(word)")
                break
            }
        }
        print("DEBUG hasExactlyNValues: returning \(valuesFound == expected) (found \(valuesFound))")
        return valuesFound == expected
    }
    
    static func isSequenceOfTeethEndingInAction(words: [String], from index: Int) -> Bool {
        var i = index
        var foundTeeth = 0
        var sawComma = false
        
        while i < words.count {
            let word = words[i]
            if isAspectOrAction(word) {
                return foundTeeth > 0
            }
            
            if word == "," || word == "dan" || word == "maupun" {
                sawComma = true
                i += 1
                continue
            }
            
            if word == "_sep_" || word == "." {
                return foundTeeth > 1 || (foundTeeth == 1 && sawComma)
            }
            
            if let d1 = parseIntOrWord(word), d1 >= 1 && d1 <= 8 {
                var j = i + 1
                while j < words.count && (words[j] == "," || words[j] == "dan" || words[j] == "maupun") {
                    j += 1
                }
                
                if j < words.count, let d2 = parseIntOrWord(words[j]), d2 >= 1 && d2 <= 8 {
                    foundTeeth += 1
                    i = j + 1
                    continue
                }
            }
            
            break
        }
        
        return foundTeeth > 1 || (foundTeeth == 1 && sawComma)
    }
}

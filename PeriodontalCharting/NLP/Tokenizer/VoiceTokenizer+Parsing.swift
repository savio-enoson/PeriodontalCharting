import Foundation

extension VoiceTokenizer {
    static func tokenize(text: String, isFinal: Bool = false) -> [VoiceToken] {
        var tokens: [VoiceToken] = []
        let cleaned = text.lowercased()
            .replacingOccurrences(of: ".", with: " _sep_ ")
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "\n", with: " _sep_ ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "{", with: " ")
            .replacingOccurrences(of: "}", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "mesiolingual", with: "mesio lingual")
            .replacingOccurrences(of: "distolingual", with: "disto lingual")
            .replacingOccurrences(of: "mesiobukal", with: "mesio bukal")
            .replacingOccurrences(of: "distobukal", with: "disto bukal")
            .replacingOccurrences(of: "mesiopalatal", with: "mesio palatal")
            .replacingOccurrences(of: "distopalatal", with: "disto palatal")
            .replacingOccurrences(of: "mesiolabial", with: "mesio labial")
            .replacingOccurrences(of: "distolabial", with: "disto labial")
            .replacingOccurrences(of: "mid-", with: "mid ")
            .replacingOccurrences(of: "mid ", with: "mid")
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
        
        var i = 0
        var expectedValues = 3
        var currentValues = 0
        
        func updateExpectedValues(for anatomy: AnatomyType) {
            switch anatomy {
            case .mesioBuccal, .distoBuccal, .mesioLingual, .distoLingual, .mesioPalatal, .distoPalatal, .mesial, .distal, .midBuccal, .midLingual, .midPalatal, .midLabial:
                expectedValues = 1
            case .buccal, .lingual, .palatal, .labial, .upperJaw, .lowerJaw:
                expectedValues = 3
            }
            currentValues = 0
        }
        
        func updateExpectedValues(for metric: AnnotationOperation) {
            switch metric {
            case .bleeding, .plaque, .implant, .missing:
                expectedValues = 0
            case .mobility, .furcation:
                expectedValues = 1
            case .probingDepth, .gingivalMargin:
                expectedValues = 3
            }
            currentValues = 0
        }
        
        while i < words.count {
            let w = words[i]
            let nextW = (i + 1 < words.count) ? words[i+1] : ""
            
            if w == "_sep_" {
                tokens.append(.word(w))
                currentValues = 0
                i += 1
                continue
            }
            
            if (w == "gak" || w == "tidak") && nextW == "ada" {
                tokens.append(.action(.missing))
                expectedValues = 3; currentValues = 0
                i += 2; continue
            }
            if w == "missing" {
                tokens.append(.action(.missing))
                expectedValues = 3; currentValues = 0
                i += 1; continue
            }
            if w == "semua" || w == "semuanya" || w == "seluruh" || w == "seluruhnya" { tokens.append(.action(.all)); i += 1; continue }
            if w == "lanjut" || w == "selesai" || w == "kemudian" || w == "selanjutnya" || w == "berikutnya" { tokens.append(.action(.commit)); i += 1; continue }
            
            if w == "midlingual" || w == "tengahlingual" { tokens.append(.anatomy(.midLingual)); updateExpectedValues(for: .midLingual); i += 1; continue }
            if w == "midbukal" || w == "tengahbukal" { tokens.append(.anatomy(.midBuccal)); updateExpectedValues(for: .midBuccal); i += 1; continue }
            if w == "midpalatal" || w == "tengahpalatal" { tokens.append(.anatomy(.midPalatal)); updateExpectedValues(for: .midPalatal); i += 1; continue }
            if w == "midlabial" || w == "tengahlabial" { tokens.append(.anatomy(.midLabial)); updateExpectedValues(for: .midLabial); i += 1; continue }

            if w == "mid" || w == "tengah" {
                if nextW == "lingual" { tokens.append(.anatomy(.midLingual)); updateExpectedValues(for: .midLingual); i += 2; continue }
                if nextW == "bukal" { tokens.append(.anatomy(.midBuccal)); updateExpectedValues(for: .midBuccal); i += 2; continue }
                if nextW == "palatal" { tokens.append(.anatomy(.midPalatal)); updateExpectedValues(for: .midPalatal); i += 2; continue }
                if nextW == "labial" { tokens.append(.anatomy(.midLabial)); updateExpectedValues(for: .midLabial); i += 2; continue }
            }
            
            if w == "mesio" || w == "mesial" {
                if nextW == "bukal" { tokens.append(.anatomy(.mesioBuccal)); updateExpectedValues(for: .mesioBuccal); i += 2; continue }
                if nextW == "lingual" { tokens.append(.anatomy(.mesioLingual)); updateExpectedValues(for: .mesioLingual); i += 2; continue }
                if nextW == "palatal" { tokens.append(.anatomy(.mesioPalatal)); updateExpectedValues(for: .mesioPalatal); i += 2; continue }
                tokens.append(.anatomy(.mesial)); updateExpectedValues(for: .mesial); i += 1; continue
            }
            if w == "disto" || w == "distal" {
                if nextW == "bukal" { tokens.append(.anatomy(.distoBuccal)); updateExpectedValues(for: .distoBuccal); i += 2; continue }
                if nextW == "lingual" { tokens.append(.anatomy(.distoLingual)); updateExpectedValues(for: .distoLingual); i += 2; continue }
                if nextW == "palatal" { tokens.append(.anatomy(.distoPalatal)); updateExpectedValues(for: .distoPalatal); i += 2; continue }
                tokens.append(.anatomy(.distal)); updateExpectedValues(for: .distal); i += 1; continue
            }
            
            if w == "rahang" && nextW == "atas" { tokens.append(.anatomy(.upperJaw)); updateExpectedValues(for: .upperJaw); i += 2; continue }
            if w == "rahang" && nextW == "bawah" { tokens.append(.anatomy(.lowerJaw)); updateExpectedValues(for: .lowerJaw); i += 2; continue }
            
            if w == "gigi" {
                if i + 1 < words.count {
                    if let num = parseIntOrWord(words[i+1]), num > 10 && num < 99 {
                        tokens.append(.toothIdentifier(num))
                        expectedValues = 3; currentValues = 0
                        i += 2
                        while i < words.count, let extra = parseIntOrWord(words[i]), extra > 10 && extra < 99 {
                            tokens.append(.toothIdentifier(extra))
                            expectedValues = 3; currentValues = 0
                            i += 1
                        }
                        continue
                    }
                    if i + 2 < words.count, let d1 = parseIntOrWord(words[i+1]), let d2 = parseIntOrWord(words[i+2]), d1 > 0 && d1 <= 8 && d2 > 0 && d2 <= 8 {
                        tokens.append(.toothIdentifier(d1 * 10 + d2))
                        expectedValues = 3; currentValues = 0
                        i += 3; continue
                    }
                }
                i += 1; continue
            }
            
            if let num = parseIntOrWord(w) {
                if num > 10 && num < 99 {
                    tokens.append(.toothIdentifier(num))
                    expectedValues = 3; currentValues = 0
                    i += 1; continue
                }
                
                if num >= 1 && num <= 8 {
                    if i + 1 < words.count, let nextNum = parseIntOrWord(words[i+1]), nextNum >= 1 && nextNum <= 8 {
                        let combined = num * 10 + nextNum
                        var thirdIsSingleDigit = false
                        var isStreamEnd = false
                        if i + 2 < words.count {
                            if let thirdNum = parseIntOrWord(words[i+2]), thirdNum >= 0 && thirdNum <= 9 {
                                thirdIsSingleDigit = true
                            }
                        } else {
                            isStreamEnd = true
                        }
                        
                        let isStartOfBlock = currentValues == 0 || (currentValues % expectedValues == 0 && expectedValues >= 3)
                        
                        if !thirdIsSingleDigit && isStartOfBlock {
                            if isStreamEnd && !isFinal {
                                // Defer merging: we might just be waiting for the user to dictate the 3rd value.
                            } else {
                                tokens.append(.toothIdentifier(combined))
                                expectedValues = 3; currentValues = 0
                                i += 2; continue
                            }
                        }
                    }
                }
                tokens.append(.number(num))
                currentValues += 1
                i += 1; continue
            }
            
            if let anatomy = AnatomyType(rawValue: w) { tokens.append(.anatomy(anatomy)); updateExpectedValues(for: anatomy); i += 1; continue }
            if w == "lanjut" {
                tokens.append(.action(.next))
                expectedValues = 3; currentValues = 0
                let aspectWords = ["palatal", "lingual", "bukal", "labial"]
                if aspectWords.contains(nextW) {
                    let thirdW = (i + 2 < words.count) ? words[i+2] : ""
                    var skipNext = true
                    if let tNum = Int(thirdW), tNum > 10 && tNum < 99 {
                        skipNext = false
                    }
                    if skipNext {
                        i += 2
                        continue
                    }
                }
                i += 1
                continue
            }
            if let action = ActionType(rawValue: w) { tokens.append(.action(action)); expectedValues = 3; currentValues = 0; i += 1; continue }
            
            if w == "resesi" || w == "kemunduran" { tokens.append(.metric(.gingivalMargin, multiplier: -1)); updateExpectedValues(for: AnnotationOperation.gingivalMargin); i += 1; continue }
            if w == "margin" || w == "gingival" { tokens.append(.metric(.gingivalMargin, multiplier: 1)); updateExpectedValues(for: AnnotationOperation.gingivalMargin); i += 1; continue }
            if w == "enlargement" || w == "pembengkakan" || w == "pembesaran" { tokens.append(.metric(.gingivalMargin, multiplier: 1)); updateExpectedValues(for: AnnotationOperation.gingivalMargin); i += 1; continue }
            
            if w == "poket" || w == "probing" || w == "kedalaman" { tokens.append(.metric(.probingDepth, multiplier: 1)); updateExpectedValues(for: AnnotationOperation.probingDepth); i += 1; continue }
            if w == "bop" || w == "berdarah" { tokens.append(.metric(.bleeding, multiplier: 1)); updateExpectedValues(for: AnnotationOperation.bleeding); i += 1; continue }
            if w == "plaque" || w == "plak" { tokens.append(.metric(.plaque, multiplier: 1)); updateExpectedValues(for: AnnotationOperation.plaque); i += 1; continue }
            if w == "kegoyangan" || w == "mobilitas" || w == "mobility" { tokens.append(.metric(.mobility, multiplier: 1)); updateExpectedValues(for: AnnotationOperation.mobility); i += 1; continue }
            if w == "furkasi" || w == "furcation" { tokens.append(.metric(.furcation, multiplier: 1)); updateExpectedValues(for: AnnotationOperation.furcation); i += 1; continue }
            if w == "implan" || w == "implant" { tokens.append(.metric(.implant, multiplier: 1)); updateExpectedValues(for: AnnotationOperation.implant); i += 1; continue }
            
            tokens.append(.word(w))
            i += 1
        }
        return tokens
    }
}

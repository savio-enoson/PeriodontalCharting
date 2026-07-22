import Foundation

// MARK: - Voice Parsing

enum ActionType: String, Equatable {
    case next = "lanjut"
    case missing = "gak"
    case missing2 = "tidak"
    case from = "dari"
    case until = "sampai"
    case until2 = "hingga"
    case until3 = "dan"
    case at = "pada"
    case at2 = "di"
    case all = "semua"
}

enum AnatomyType: String, Equatable {
    case palatal = "palatal"
    case buccal = "bukal"
    case lingual = "lingual"
    case labial = "labial"
    case mesial = "mesial"
    case distal = "distal"
    case mesioBuccal = "mesio bukal"
    case distoBuccal = "disto bukal"
    case mesioLingual = "mesio lingual"
    case distoLingual = "disto lingual"
    case mesioPalatal = "mesio palatal"
    case distoPalatal = "disto palatal"
    case upperJaw = "rahang atas"
    case lowerJaw = "rahang bawah"
}

enum VoiceToken: Equatable {
    case number(Int)
    case anatomy(AnatomyType)
    case metric(AnnotationOperation, multiplier: Int)
    case action(ActionType)
    case toothIdentifier(Int)
    case word(String)
}

class VoiceTokenizer {
    static let numberWords: [String: Int] = [
        "nol": 0, "satu": 1, "dua": 2, "tiga": 3, "empat": 4, 
        "lima": 5, "enam": 6, "tujuh": 7, "delapan": 8, "sembilan": 9,
        "sepuluh": 10
    ]
    
    static func tokenize(text: String) -> [VoiceToken] {
        let cleaned = text.lowercased()
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "mid-", with: "mid ")
            
        let words = cleaned.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        var tokens: [VoiceToken] = []
        
        var i = 0
        while i < words.count {
            let w = words[i]
            let nextW = (i + 1 < words.count) ? words[i+1] : ""
            
            if (w == "gak" || w == "tidak") && nextW == "ada" {
                tokens.append(.action(.missing))
                i += 2; continue
            }
            if w == "mid" {
                if let anatomy = AnatomyType(rawValue: nextW) {
                    tokens.append(.anatomy(anatomy))
                    i += 2; continue
                }
            }
            if w == "mesio" && nextW == "bukal" { tokens.append(.anatomy(.mesioBuccal)); i += 2; continue }
            if w == "disto" && nextW == "bukal" { tokens.append(.anatomy(.distoBuccal)); i += 2; continue }
            if w == "mesio" && (nextW == "lingual" || nextW == "palatal") {
                tokens.append(.anatomy(nextW == "lingual" ? .mesioLingual : .mesioPalatal)); i += 2; continue
            }
            if w == "disto" && (nextW == "lingual" || nextW == "palatal") {
                tokens.append(.anatomy(nextW == "lingual" ? .distoLingual : .distoPalatal)); i += 2; continue
            }
            if w == "rahang" && nextW == "atas" { tokens.append(.anatomy(.upperJaw)); i += 2; continue }
            if w == "rahang" && nextW == "bawah" { tokens.append(.anatomy(.lowerJaw)); i += 2; continue }
            
            if w == "gigi" {
                if let num = Int(nextW) {
                    tokens.append(.toothIdentifier(num))
                    i += 2; continue
                }
            }
            
            if let num = Int(w) {
                if num > 10 && num < 99 {
                    tokens.append(.toothIdentifier(num))
                } else {
                    tokens.append(.number(num))
                }
                i += 1; continue
            }
            if let num = VoiceTokenizer.numberWords[w] {
                tokens.append(.number(num))
                i += 1; continue
            }
            
            if let anatomy = AnatomyType(rawValue: w) { tokens.append(.anatomy(anatomy)); i += 1; continue }
            if w == "lanjut" {
                tokens.append(.action(.next))
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
            if let action = ActionType(rawValue: w) { tokens.append(.action(action)); i += 1; continue }
            
            if w == "resesi" || w == "kemunduran" { tokens.append(.metric(.gingivalMargin, multiplier: -1)); i += 1; continue }
            if w == "margin" || w == "gingival" { tokens.append(.metric(.gingivalMargin, multiplier: 1)); i += 1; continue }
            if w == "enlargement" || w == "pembengkakan" || w == "pembesaran" { tokens.append(.metric(.gingivalMargin, multiplier: 1)); i += 1; continue }
            
            if w == "poket" || w == "probing" || w == "kedalaman" { tokens.append(.metric(.probingDepth, multiplier: 1)); i += 1; continue }
            if w == "bop" || w == "berdarah" { tokens.append(.metric(.bleeding, multiplier: 1)); i += 1; continue }
            if w == "plaque" || w == "plak" { tokens.append(.metric(.plaque, multiplier: 1)); i += 1; continue }
            if w == "kegoyangan" || w == "mobilitas" || w == "mobility" { tokens.append(.metric(.mobility, multiplier: 1)); i += 1; continue }
            if w == "furkasi" || w == "furcation" { tokens.append(.metric(.furcation, multiplier: 1)); i += 1; continue }
            if w == "implan" || w == "implant" { tokens.append(.metric(.implant, multiplier: 1)); i += 1; continue }
            
            tokens.append(.word(w))
            i += 1
        }
        return tokens
    }
}


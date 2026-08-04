import Foundation

extension VoiceTokenizer {
    static func tokenize(text: String, isFinal: Bool = false) -> [VoiceToken] {
        var tokens: [VoiceToken] = []
        // Normalization is now handled centrally by TokenizerManager.normalizeSTT
        let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        
        var i = 0
        var expectedValues = 3
        var currentValues = 0
        
        func updateExpectedValues(for anatomy: AnatomyType) {
            switch anatomy {
            case .mesioBuccal, .distoBuccal, .mesioLingual, .distoLingual, .mesioPalatal, .distoPalatal, .mesial, .distal, .midBuccal, .midLingual, .midPalatal, .midLabial, .mesioLabial, .distoLabial:
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
                // Whisper often concatenates a spoken run of single-digit values
                // ("3 3 3") into one number ("333"). No valid tooth id (11–48) or
                // per-site metric value is ≥ 100, so a 3+ digit number here is
                // unambiguously a run of individual values — split it back into
                // single-digit `.number` tokens so it charts exactly as "3 3 3" would.
                if num >= 100 {
                    for ch in String(num) {
                        guard let d = ch.wholeNumberValue else { continue }
                        tokens.append(.number(d))
                        currentValues += 1
                    }
                    i += 1; continue
                }

                // Repetition-artifact guard: a "doubled digit" (11, 22, … 88, 99)
                // arriving immediately after a value number is almost always the STT
                // repeating the value stream ("2 2 2" → "222 22"), NOT a real tooth
                // jump. Treat it as two repeated values instead of jumping the cursor
                // to tooth 22. Explicit teeth are unaffected: "gigi 22" is handled by
                // the gigi branch above, and "22 …"/"lanjut 22" aren't preceded by a
                // bare value number, so `tokens.last` isn't a `.number` there.
                if num >= 11, num % 11 == 0, case .number = tokens.last {
                    let d = num / 11
                    tokens.append(.number(d)); tokens.append(.number(d))
                    currentValues += 2
                    i += 1; continue
                }

                if num > 10 && num < 99 {
                    tokens.append(.toothIdentifier(num))
                    expectedValues = 3; currentValues = 0
                    i += 1; continue
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
        _ = expectedValues
        return tokens
    }
}

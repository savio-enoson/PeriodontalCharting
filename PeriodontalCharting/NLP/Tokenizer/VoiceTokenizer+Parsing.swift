import Foundation

extension VoiceTokenizer {
    static func tokenize(text: String, isFinal: Bool = false) -> [VoiceToken] {
        var tokens: [VoiceToken] = []
        let cleaned = text.lowercased()
            // A decimal point BETWEEN digits ("1.5", "2.5", chained "1.5.3") is never
            // one charting value — depths/recession are whole mm dictated one digit
            // per site, so "1.5" is the two values 1 and 5. Split it to a space FIRST,
            // before the "." -> _sep_ rule below: left intact, that rule turns the dot
            // into a command boundary and scatters "1" and "5" onto different sites
            // (parser treats _sep_ like "dan"). Zero-width lookaround so it only fires
            // on a dot flanked by digits — real sentence periods and "b.o.p" are left
            // for the rules below.
            .replacingOccurrences(of: #"(?<=\d)\.(?=\d)"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: ".", with: " _sep_ ")
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "\n", with: " _sep_ ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "{", with: " ")
            .replacingOccurrences(of: "}", with: " ")
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
            .replacingOccurrences(of: " -", with: " minus ")
            .replacingOccurrences(of: "-", with: " ")
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
        
        // ---- Fused directional-compound splitter ------------------------------------
        // Whisper sometimes GLUES the stem and site into a single token, with the site
        // half itself fuzzed ("mesiyobukal", "distobuqal"). The positional recovery
        // below only fires when the site is a SEPARATE token, so peel a (fuzzy) trailing
        // site suffix off any m/d-initial token first — restoring the canonical site and
        // leaving the stem prefix ("mesiyo"/"disto"/…) for the positional pass to resolve
        // (mesio/disto by leading sound). Guarded to m/d/s-initial tokens with a ≥2-char
        // prefix so bare sites ("bukal") and "distal"/"mesial" are never split. 's' is
        // allowed because STT frequently drops the leading 'd' of "disto" ("setobukal",
        // "situbukal", "stobukal" → stem "seto"/"situ"/"sto"); the full site suffix is
        // still required, so real s-words ("selesai", "semua", "membuka") never split.
        let compoundSites: [(suffixes: [String], site: String)] = [
            (["bukal", "buccal", "bucal", "buqal", "bukkal", "bukhal"], "bukal"),
            (["lingual", "lingval", "linggual", "lingal", "linguol"], "lingual"),
            (["palatal", "palatial", "palatel", "palatual"], "palatal"),
        ]
        words = words.flatMap { word -> [String] in
            guard let first = word.first, first == "m" || first == "d" || first == "s" else { return [word] }
            for (suffixes, site) in compoundSites {
                for suf in suffixes where word.count > suf.count && word.hasSuffix(suf) {
                    let prefix = String(word.dropLast(suf.count))
                    if prefix.count >= 2 { return [prefix, site] }
                }
            }
            return [word]
        }

        // ---- Directional-stem recovery (generalized, position-based) ----------------
        // Whisper mangles the directional STEM ("disto"/"mesio") into an open-ended,
        // un-enumerable set of junk ("di situ"/"justru"/"stok"/"di slow"/"misi"/"mili"/…)
        // while the SITE word after it ("bukal"/"lingual"/"palatal") stays reliable.
        // Rather than chase every variant with a ClinicalConfig regex, use POSITION: a
        // word sitting immediately before a site word that the tokenizer does NOT
        // otherwise recognize is almost always a mis-heard stem. Resolve direction by
        // leading sound — 'm' → mesio, otherwise disto (covers di*/s*/j* → disto,
        // misi/mili → mesio) — and swallow a leading "di"/"the" fragment so
        // "di situ bukal" doesn't leave a stray "di" (which would tokenize as the "at"
        // action and spuriously start post-targeting). Bare "di bukal" (= "at buccal")
        // is left untouched because "di" IS recognized, so it never triggers. This
        // must run BEFORE the main loop tokenizes "di" into an action. See STT_ISSUES #5.
        let stemSites: Set<String> = ["bukal", "lingual", "palatal"]
        // Words that may legitimately precede a site — real directionals/positions,
        // at-actions, structural words, and the clinical vocabulary we must never
        // clobber. Anything NOT here (and not a number) before a site is a mis-hear.
        let recognizedBeforeSite: Set<String> = [
            "mesio", "mesial", "disto", "distal", "mid", "tengah",
            "di", "pada", "semua", "seluruh", "dan", "sampai", "hingga", "dari",
            "lanjut", "selesai", "kemudian", "gigi", "rahang", "atas", "bawah",
            "bukal", "lingual", "palatal", "labial", "_sep_",
            "bop", "berdarah", "poket", "probing", "kedalaman", "resesi", "kemunduran",
            "margin", "gingival", "enlargement", "pembengkakan", "pembesaran",
            "plak", "plaque", "furkasi", "furcation", "kegoyangan", "mobilitas",
            "mobility", "implan", "implant", "gak", "tidak", "ada", "minus", "mm",
            // region/surface words that legitimately precede a site aspect
            "bagian", "permukaan", "sekitar", "maupun", "sisi", "setelah", "disini",
        ]
        let stemLeadFragments: Set<String> = ["di", "the", "de", "dee", "dih", "dis"]
        if words.count >= 2 {
            var recovered: [String] = []
            for word in words {
                if stemSites.contains(word), let prev = recovered.last,
                   prev.count >= 2, prev.allSatisfy({ $0.isLetter }),
                   !recognizedBeforeSite.contains(prev), parseIntOrWord(prev) == nil {
                    let stem = prev.hasPrefix("m") ? "mesio" : "disto"
                    recovered.removeLast()                                   // drop the junk stem
                    if let lead = recovered.last, stemLeadFragments.contains(lead) {
                        recovered.removeLast()                               // drop a leading "di"/"the"/…
                    }
                    recovered.append(stem)
                    recovered.append(word)
                } else {
                    recovered.append(word)
                }
            }
            words = recovered
        }

        var i = 0
        var expectedValues = 3
        var currentValues = 0

        // "disto bukal" acoustically compressed by STT into a "<di-fragment>
        // <bop-fragment>" pair ("di bop"/"di bob"/"the bop"/…). Dangerous because a
        // bare "bop" is the BLEEDING metric, so the site would silently mark bleeding
        // instead of disto-buccal. Collapsed here on ADJACENCY, not spelling: a legit
        // "di" (the "at" action) is ALWAYS followed by a site word, never "bop", and a
        // real BOP command has the other word order ("bop di bukal") — so the pair only
        // ever occurs as this mishear. This lives in the parser (not a ClinicalConfig
        // regex) because only here is the site-vs-metric grammar visible; both halves
        // are fuzzy sets so acoustic variants collapse in one rule. See STT_ISSUES #5.
        let distoFragments: Set<String> = ["di", "the", "de", "dee", "dih"]
        let bukalBopFragments: Set<String> = ["bop", "bob", "pop", "bup"]
        
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

            // "disto bukal" mis-heard as a "<di> <bop>" pair — collapse before the
            // generic `di`→at-action / `bop`→bleeding rules below can split it.
            if distoFragments.contains(w) && bukalBopFragments.contains(nextW) {
                tokens.append(.anatomy(.distoBuccal))
                updateExpectedValues(for: .distoBuccal)
                i += 2
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
                        
                        let isStartOfBlock = currentValues == 0 || (expectedValues >= 3 && currentValues % expectedValues == 0)
                        
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

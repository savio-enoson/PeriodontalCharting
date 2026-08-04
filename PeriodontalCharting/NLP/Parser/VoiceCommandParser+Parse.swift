import Foundation

extension VoiceCommandParser {
    func parse(text: String, isFinal: Bool = false) -> [AnnotationCommand] {
        self.tokens = TokenizerManager.shared.tokenize(text: text, isFinal: isFinal)
        self.commands = []
        self.tokenIndex = 0
        
        self.currentNumbers = []
        self.currentMetricMultiplier = 1
        self.lastAutoAdvancedFromTooth = nil
        return parseTokens(isFinal: isFinal)
    }
    
    func parseTokens(isFinal: Bool = false) -> [AnnotationCommand] {
        var consumedIndices = Set<Int>()
        
        while tokenIndex < tokens.count {
            if self.tokens.isEmpty { break }
            
            // Apply heuristic to transform e.g. "3" "1" into "31" if 'Gigi' was omitted
            if case .number(let n) = tokens[tokenIndex], n >= 1 && n <= 8 {
                let lookaheadIdx = tokenIndex + 1
                var nextNum: Int? = nil
                while lookaheadIdx < tokens.count {
                    if case .word(let w) = tokens[lookaheadIdx], w == "_sep_" {
                        break
                    }
                    if case .number(let nn) = tokens[lookaheadIdx] {
                        nextNum = nn
                    }
                    break
                }
                
                if let nn = nextNum, nn >= 1 && nn <= 8 {
                    var thirdIsNum = false
                    var followedByAnatomy = false
                    var lookahead3Idx = lookaheadIdx + 1
                    while lookahead3Idx < tokens.count {
                        if case .word(let w) = tokens[lookahead3Idx], w == "_sep_" {
                            lookahead3Idx += 1; continue
                        }
                        if case .number(_) = tokens[lookahead3Idx] {
                            thirdIsNum = true
                        } else if case .anatomy(_) = tokens[lookahead3Idx] {
                            followedByAnatomy = true
                        }
                        break
                    }
                    
                    let canMerge = currentNumbers.isEmpty ? !thirdIsNum : (!thirdIsNum && followedByAnatomy)
                    
                    if canMerge {
                        if !currentNumbers.isEmpty {
                            flushNumbers(force: true)
                        }
                        let toothId = n * 10 + nn
                        self.tokens[tokenIndex] = .toothIdentifier(toothId)
                        self.tokens.remove(at: lookaheadIdx)
                    }
                }
            }
            
            // print("PROCESSING INDEX", tokenIndex, tokens[tokenIndex])
            let token = tokens[tokenIndex]
            
            switch token {
            case .number(let n):
                flushPostTargetIfPending()
                isPostTargeting = false
                

                if let sel = activeSelection, sel.expectedSlots == 1, self.cursor.currentMetric == .probingDepth {
                    var numCount = 0
                    var j = tokenIndex
                    while j < tokens.count && numCount < 3 {
                        var shouldBreak = false
                        switch tokens[j] {
                        case .number(_):
                            numCount += 1
                            j += 1
                        case .word(_):
                            j += 1
                        default:
                            shouldBreak = true
                        }
                        if shouldBreak { break }
                    }
                    if numCount >= 3 {
                        activeSelection = nil
                    }
                }
                
                if self.cursor.currentMetric == .bleeding || self.cursor.currentMetric == .plaque || self.cursor.currentMetric == .implant {
                    /* print("BEFORE EMIT METRIC..."); */ emitBoolIfPending()
                    restoreToMainSequence()
                }
                lastAutoAdvancedFromTooth = nil
                currentNumbers.append(n)
                flushNumbers(force: false)
                tokenIndex += 1
                
            case .toothIdentifier(let tooth):
                let originalToothIndex = tokenIndex
                lastAutoAdvancedFromTooth = nil
                metricHadSpecificTargets = true
                if isPostTargeting, let template = postTargetTemplate {
                    var isRange = false
                    var peek = tokenIndex + 1
                    var endAnatomy: AnatomyType? = nil
                    var endTooth: Int? = nil
                    
                    if peek < tokens.count, case .action(let act) = tokens[peek], (act == .until || act == .until2) {
                        isRange = true
                        peek += 1
                    }
                    
                    if isRange {
                        var endAnatomies: [AnatomyType] = []
                        while peek < tokens.count {
                            if case .word(let w) = tokens[peek], w != "_sep_" { peek += 1; continue }
                            if case .anatomy(let anat) = tokens[peek] {
                                endAnatomies.append(anat)
                                peek += 1
                                continue
                            }
                            break
                        }
                        if let ea = endAnatomies.last { endAnatomy = ea }
                        
                        while peek < tokens.count {
                            if case .word(let w) = tokens[peek], w != "_sep_" { peek += 1; continue }
                            break
                        }
                        if peek < tokens.count, case .toothIdentifier(let et) = tokens[peek] {
                            endTooth = et
                            peek += 1
                        }
                    }
                    
                    var finalSel: TeethSelection
                    
                    if let et = endTooth {
                        var sAspect = template.teethSelection.startAspect
                        var sSite = template.teethSelection.startSite
                        if let pa = postTargetAnatomy, var resolved = ChartAnatomyResolver.resolve(anatomy: pa, for: tooth, currentAspect: self.cursor.currentAspect) {
                            let isFull = (pa == .buccal || pa == .labial || pa == .lingual || pa == .palatal)
                            if isFull && template.values.count < 3 { resolved.site = 1 }
                            sAspect = resolved.aspect; sSite = resolved.site
                        }
                        
                        var eAspect = template.teethSelection.endAspect
                        var eSite = template.teethSelection.endSite
                        if let ea = endAnatomy, var resolved = ChartAnatomyResolver.resolve(anatomy: ea, for: et, currentAspect: self.cursor.currentAspect) {
                            let isFull = (ea == .buccal || ea == .labial || ea == .lingual || ea == .palatal)
                            if isFull && template.values.count < 3 { resolved.site = 1 }
                            eAspect = resolved.aspect; eSite = resolved.site
                        } else if endAnatomy == nil {
                            eAspect = sAspect; eSite = sSite
                        }
                        
                        finalSel = TeethSelection(startTooth: ToothObject.create(number: tooth), startAspect: sAspect, startSite: sSite, endTooth: ToothObject.create(number: et), endAspect: eAspect, endSite: eSite)
                        for i in tokenIndex..<peek { consumedIndices.insert(i) }
                        tokenIndex = peek
                    } else {
                        var sAspect = template.teethSelection.startAspect
                        var sSite = template.teethSelection.startSite
                        var eAspect = template.teethSelection.endAspect
                        var eSite = template.teethSelection.endSite
                        
                        if let pa = postTargetAnatomy, var resolved = ChartAnatomyResolver.resolve(anatomy: pa, for: tooth, currentAspect: self.cursor.currentAspect) {
                            let isFull = (pa == .buccal || pa == .labial || pa == .lingual || pa == .palatal)
                            if isFull && template.values.count < 3 { resolved.site = 1 }
                            sAspect = resolved.aspect
                            eAspect = resolved.aspect
                            sSite = resolved.site
                            eSite = resolved.site
                        }
                        
                        finalSel = TeethSelection(startTooth: ToothObject.create(number: tooth), startAspect: sAspect, startSite: sSite, endTooth: ToothObject.create(number: tooth), endAspect: eAspect, endSite: eSite)
                        
                        if isRange && endTooth == nil && endAnatomy != nil {
                            if let resolved = ChartAnatomyResolver.resolve(anatomy: endAnatomy!, for: tooth, currentAspect: self.cursor.currentAspect) {
                                finalSel.endAspect = resolved.aspect
                                finalSel.endSite = resolved.site
                            }
                            for i in tokenIndex..<peek { consumedIndices.insert(i) }
                            tokenIndex = peek
                        } else {
                            tokenIndex += 1
                        }
                    }
                    
                    let isBool = template.operation == .bleeding || template.operation == .plaque || template.operation == .implant
                    let finalVals = finalizeValues(for: finalSel, baseValues: template.values, isBoolMetric: isBool)
                    
                    let cmd = AnnotationCommand(operation: template.operation, teethSelection: finalSel, aspect: finalSel.startAspect ?? template.aspect, values: finalVals)
                    commands.append(cmd)
                    
                    if let targetTooth = endTooth ?? Optional(tooth) {
                        _ = self.cursor.jumpTo(tooth: targetTooth, aspect: finalSel.startAspect ?? self.cursor.currentAspect, updateSequenceIndex: true)
                    }
                    
                    consumedIndices.insert(originalToothIndex)
                    
                    if !isContinuingList(after: tokenIndex - 1, in: tokens) {
                        isPostTargeting = false
                        postTargetTemplate = nil
                        postTargetAnatomy = nil
                        restoreToMainSequence()
                    }
                    
                    continue
                }
                
                /* print("BEFORE EMIT METRIC..."); */ emitBoolIfPending()
                flushNumbers(force: true)
                
                _ = self.cursor.jumpTo(tooth: tooth, aspect: self.cursor.currentAspect, updateSequenceIndex: true)
                
                var isRange = false
                var peek = tokenIndex + 1
                
                while peek < tokens.count {
                    if case .word(let w) = tokens[peek], w != "_sep_" { peek += 1; continue }
                    break
                }
                
                if peek < tokens.count, case .action(let act) = tokens[peek], (act == .until || act == .until2) {
                    isRange = true
                    peek += 1
                }
                
                var endAnatomy: AnatomyType? = nil
                var endTooth: Int? = nil
                
                if isRange {
                    var endAnatomies: [AnatomyType] = []
                    while peek < tokens.count {
                        if case .word(let w) = tokens[peek], w != "_sep_" { peek += 1; continue }
                        if case .anatomy(let anat) = tokens[peek] {
                            endAnatomies.append(anat)
                            peek += 1
                            continue
                        }
                        break
                    }
                    if let ea = endAnatomies.last { endAnatomy = ea }
                    
                    while peek < tokens.count {
                        if case .word(let w) = tokens[peek], w != "_sep_" { peek += 1; continue }
                        break
                    }
                    if peek < tokens.count, case .toothIdentifier(let et) = tokens[peek] {
                        endTooth = et
                        peek += 1
                    }
                }
                
                var startAnatomies: [AnatomyType] = []
                var searchIdx = tokenIndex - 1
                while searchIdx >= 0 {
                    if case .anatomy(let anat) = tokens[searchIdx] {
                        startAnatomies.insert(anat, at: 0)
                        searchIdx -= 1
                    } else if case .word(let w) = tokens[searchIdx], w != "_sep_" {
                        searchIdx -= 1
                    } else {
                        break
                    }
                }
                
                if let et = endTooth {
                    var sAspect: ChartAspect?
                    var sSite: Int?
                    if let sa = startAnatomies.first, let resolved = resolveAnatomyWithLookahead(anatomy: sa, for: tooth, toothIndex: tokenIndex, tokens: tokens) {
                        sAspect = resolved.aspect; sSite = resolved.site
                    }
                    var eAspect: ChartAspect?
                    var eSite: Int?
                    if let ea = endAnatomy, let resolved = resolveAnatomyWithLookahead(anatomy: ea, for: et, toothIndex: peek - 1, tokens: tokens) {
                        eAspect = resolved.aspect; eSite = resolved.site
                    } else if endAnatomy == nil {
                        eAspect = sAspect; eSite = sSite
                    }
                    self.activeSelection = TeethSelection(startTooth: ToothObject.create(number: tooth), startAspect: sAspect, startSite: sSite, endTooth: ToothObject.create(number: et), endAspect: eAspect, endSite: eSite)
                    _ = self.cursor.jumpTo(tooth: et, aspect: eAspect ?? self.cursor.currentAspect, updateSequenceIndex: true)
                    for i in tokenIndex..<peek { consumedIndices.insert(i) }
                    tokenIndex = peek
                } else if isRange {
                    if let sa = startAnatomies.first, let resolved = resolveAnatomyWithLookahead(anatomy: sa, for: tooth, toothIndex: tokenIndex, tokens: tokens) {
                        self.activeSelection = TeethSelection(startTooth: ToothObject.create(number: tooth), startAspect: resolved.aspect, startSite: resolved.site, endTooth: ToothObject.create(number: tooth), endAspect: resolved.aspect, endSite: resolved.site)
                    } else {
                        self.activeSelection = TeethSelection(startTooth: ToothObject.create(number: tooth), startAspect: nil, startSite: nil, endTooth: ToothObject.create(number: tooth), endAspect: nil, endSite: nil)
                    }
                    for i in tokenIndex..<peek { consumedIndices.insert(i) }
                    tokenIndex = peek
                } else {
                    if let sa = startAnatomies.first, let resolved = resolveAnatomyWithLookahead(anatomy: sa, for: tooth, toothIndex: tokenIndex, tokens: tokens) {
                        self.activeSelection = TeethSelection(startTooth: ToothObject.create(number: tooth), startAspect: resolved.aspect, startSite: resolved.site, endTooth: ToothObject.create(number: tooth), endAspect: resolved.aspect, endSite: resolved.site)
                        
                        // Aggregate multiple anatomies
                        if startAnatomies.count > 1 {
                            for anat in startAnatomies.dropFirst() {
                                if let resolvedNext = resolveAnatomyWithLookahead(anatomy: anat, for: tooth, toothIndex: tokenIndex, tokens: tokens) {
                                    if self.activeSelection?.startAspect == resolvedNext.aspect {
                                        let currentStart = self.activeSelection?.startSite
                                        let currentEnd = self.activeSelection?.endSite
                                        if let s = currentStart, let e = currentEnd, let es = resolvedNext.site {
                                            self.activeSelection?.startSite = min(s, min(e, es))
                                            self.activeSelection?.endSite = max(s, max(e, es))
                                        } else {
                                            self.activeSelection?.startSite = nil
                                            self.activeSelection?.endSite = nil
                                        }
                                    } else {
                                        self.activeSelection?.startAspect = resolvedNext.aspect
                                        self.activeSelection?.endAspect = resolvedNext.aspect
                                        self.activeSelection?.startSite = resolvedNext.site
                                        self.activeSelection?.endSite = resolvedNext.site
                                    }
                                }
                            }
                        }
                    } else {
                        var isList = false
                        if self.activeSelection != nil && self.currentNumbers.isEmpty {
                            var j = tokenIndex - 1
                            while j >= 0 {
                                if case .toothIdentifier(_) = tokens[j] {
                                    isList = true
                                    break
                                } else if case .word(let w) = tokens[j], w != "_sep_" {
                                    j -= 1
                                } else if case .anatomy(_) = tokens[j] {
                                    j -= 1
                                } else {
                                    break
                                }
                            }
                        }
                        
                        if isList {
                            if var currentSelection = self.activeSelection {
                                currentSelection.endTooth = ToothObject.create(number: tooth)
                                currentSelection.endAspect = currentSelection.startAspect
                                currentSelection.endSite = currentSelection.startSite
                                self.activeSelection = currentSelection
                            }
                        } else {
                            self.activeSelection = TeethSelection(startTooth: ToothObject.create(number: tooth), startAspect: nil, startSite: nil, endTooth: ToothObject.create(number: tooth), endAspect: nil, endSite: nil)
                        }
                    }
                    tokenIndex += 1
                }
                
            case .metric(let m, let mult):
                if let last = lastAutoAdvancedFromTooth, !hasUpcomingToothIdentifier(from: tokenIndex, in: tokens) {
                    _ = self.cursor.jumpTo(tooth: last, aspect: self.cursor.currentAspect, updateSequenceIndex: false)
                    lastAutoAdvancedFromTooth = nil
                }
                isPostTargeting = false
                postTargetTemplate = nil
                postTargetAnatomy = nil
                /* print("BEFORE EMIT METRIC..."); */ emitBoolIfPending()
                flushNumbers(force: true)
                
                if self.cursor.currentMetric == .plaque && !metricHadSpecificTargets {
                    if let first = self.cursor.currentSequence.first, let last = self.cursor.currentSequence.last {
                        let sel = TeethSelection(startTooth: ToothObject.create(number: first), startAspect: nil, startSite: nil, endTooth: ToothObject.create(number: last), endAspect: nil, endSite: nil)
                        let cmd = AnnotationCommand(operation: .plaque, teethSelection: sel, aspect: nil, values: Array(repeating: "True", count: sel.expectedSlots))
                        commands.append(cmd)
                    }
                }
                
                if currentNumbers.isEmpty, let sel = activeSelection {
                    _ = self.cursor.jumpTo(tooth: sel.startTooth.toothNumber, aspect: sel.startAspect ?? self.cursor.currentAspect, updateSequenceIndex: false)
                }
                
                // print("SETTING METRIC TO", m)
                self.cursor.setMetric(m)
                currentMetricMultiplier = mult
                metricHadSpecificTargets = false
                
                if m == .bleeding || m == .plaque || m == .implant {
                    if self.activeSelection != nil {
                        emitBoolIfPending()
                        restoreToMainSequence()
                    }
                }
                
                tokenIndex += 1
                
            case .action(let a):
                lastAutoAdvancedFromTooth = nil
                if a == .at || a == .at2 {
                    let isBoolMetric = cursor.currentMetric == .bleeding || cursor.currentMetric == .plaque || cursor.currentMetric == .implant
                    if !isBoolMetric {
                        startPostTargeting()
                    }
                } else if a == .all {
                    metricHadSpecificTargets = true
                    
                    let upperSeq = cursor.configuration.getSequence(for: .upper, aspect: .buccal)
                    let lowerSeq = cursor.configuration.getSequence(for: .lower, aspect: .buccal)
                    let selUpper = TeethSelection(startTooth: ToothObject.create(number: upperSeq.first ?? 18), startAspect: nil, startSite: nil, endTooth: ToothObject.create(number: upperSeq.last ?? 28), endAspect: nil, endSite: nil)
                    let selLower = TeethSelection(startTooth: ToothObject.create(number: lowerSeq.first ?? 48), startAspect: nil, startSite: nil, endTooth: ToothObject.create(number: lowerSeq.last ?? 38), endAspect: nil, endSite: nil)
                    
                    if isPostTargeting, let template = postTargetTemplate {
                        let cmdUpper = AnnotationCommand(operation: template.operation, teethSelection: selUpper, aspect: nil, values: Array(repeating: template.values.first ?? "True", count: selUpper.expectedSlots))
                        let cmdLower = AnnotationCommand(operation: template.operation, teethSelection: selLower, aspect: nil, values: Array(repeating: template.values.first ?? "True", count: selLower.expectedSlots))
                        commands.append(cmdUpper)
                        commands.append(cmdLower)
                    } else {
                        if cursor.currentMetric == .bleeding || cursor.currentMetric == .plaque || cursor.currentMetric == .implant {
                            let cmdUpper = AnnotationCommand(operation: cursor.currentMetric, teethSelection: selUpper, aspect: nil, values: Array(repeating: "True", count: selUpper.expectedSlots))
                            let cmdLower = AnnotationCommand(operation: cursor.currentMetric, teethSelection: selLower, aspect: nil, values: Array(repeating: "True", count: selLower.expectedSlots))
                            commands.append(cmdUpper)
                            commands.append(cmdLower)
                        }
                    }
                    isPostTargeting = false
                    postTargetTemplate = nil
                    postTargetAnatomy = nil
                } else if a == .next || a == .commit {
                    flushPostTargetIfPending()
                    isPostTargeting = false
                    postTargetTemplate = nil
                    postTargetAnatomy = nil
                    emitBoolIfPending()
                    flushNumbers(force: true)
                    
                    if self.cursor.currentMetric == .plaque && !metricHadSpecificTargets {
                        if let first = self.cursor.currentSequence.first, let last = self.cursor.currentSequence.last {
                            let sel = TeethSelection(startTooth: ToothObject.create(number: first), startAspect: nil, startSite: nil, endTooth: ToothObject.create(number: last), endAspect: nil, endSite: nil)
                            let cmd = AnnotationCommand(operation: .plaque, teethSelection: sel, aspect: nil, values: Array(repeating: "True", count: sel.expectedSlots))
                            commands.append(cmd)
                        }
                    }
                    
                    restoreToMainSequence()
                } else if a == .missing || a == .missing2 {
                    if tokenIndex > 0, case .action(let prevA) = tokens[tokenIndex - 1], (prevA == .missing || prevA == .missing2) {
                        tokenIndex += 1
                        continue
                    }
                    flushPostTargetIfPending()
                    /* print("BEFORE EMIT METRIC..."); */ emitBoolIfPending()
                    flushNumbers(force: true)
                    
                    var targets: [Int] = []
                    var j = tokenIndex - 1
                    while j >= 0 {
                        if consumedIndices.contains(j) { break }
                        switch tokens[j] {
                        case .toothIdentifier(let t):
                            targets.insert(t, at: 0)
                            j -= 1
                        case .word(let w):
                            if w == "_sep_" { j = -1 } else { j -= 1 }
                        default:
                            j = -1 // break
                        }
                    }
                    
                    if targets.isEmpty {
                        targets = [activeSelection?.startTooth.toothNumber ?? self.cursor.currentTooth]
                    }
                    
                    for targetTooth in targets {
                        self.missingTeeth.insert(targetTooth)
                        
                        let cmd = AnnotationCommand(
                            operation: .missing,
                            teethSelection: TeethSelection(startTooth: ToothObject.create(number: targetTooth), startAspect: nil, startSite: nil, endTooth: ToothObject.create(number: targetTooth), endAspect: nil, endSite: nil),
                            aspect: self.cursor.currentAspect,
                            values: ["True"]
                        )
                        commands.append(cmd)
                    }
                    
                    self.activeSelection = nil
                    
                    if let lastTarget = targets.last, lastTarget == self.cursor.currentTooth {
                        _ = self.cursor.advanceToNextTooth()
                        while missingTeeth.contains(self.cursor.currentTooth) {
                            if !self.cursor.advanceToNextTooth() { break }
                        }
                    }
                    
                    restoreToMainSequence()
                } else if a == .until || a == .until2 {
                    /* print("BEFORE EMIT METRIC..."); */ emitBoolIfPending()
                    flushNumbers(force: true)
                    var peek = tokenIndex + 1
                    var endAnatomy: AnatomyType? = nil
                    var endTooth: Int? = nil
                    
                    var endAnatomies: [AnatomyType] = []
                    while peek < tokens.count {
                        if case .word(let w) = tokens[peek], w != "_sep_" { peek += 1; continue }
                        if case .anatomy(let anat) = tokens[peek] {
                            endAnatomies.append(anat)
                            peek += 1
                            continue
                        }
                        break
                    }
                    if let ea = endAnatomies.last { endAnatomy = ea }
                    
                    while peek < tokens.count {
                        if case .word(let w) = tokens[peek], w != "_sep_" { peek += 1; continue }
                        break
                    }
                    if peek < tokens.count, case .toothIdentifier(let et) = tokens[peek] {
                        endTooth = et
                        peek += 1
                    }
                    
                    if let et = endTooth {
                        var eAspect: ChartAspect? = self.cursor.currentAspect
                        var eSite: Int? = nil
                        if let ea = endAnatomy, let resolved = ChartAnatomyResolver.resolve(anatomy: ea, for: et, currentAspect: self.cursor.currentAspect) {
                            eAspect = resolved.aspect; eSite = resolved.site
                        }
                        
                        self.activeSelection = TeethSelection(
                            startTooth: ToothObject.create(number: self.cursor.currentTooth), 
                            startAspect: self.cursor.currentAspect, 
                            startSite: nil, 
                            endTooth: ToothObject.create(number: et), 
                            endAspect: eAspect, 
                            endSite: eSite
                        )
                        for i in tokenIndex..<peek { consumedIndices.insert(i) }
                        tokenIndex = peek
                        continue
                    } else if let ea = endAnatomy {
                        let refTooth = self.activeSelection?.startTooth.toothNumber ?? self.cursor.currentTooth
                        var sAspect: ChartAspect? = self.cursor.currentAspect
                        
                        var eAspect: ChartAspect? = self.cursor.currentAspect
                        var eSite: Int? = nil
                        if let resolved = ChartAnatomyResolver.resolve(anatomy: ea, for: refTooth, currentAspect: self.cursor.currentAspect) {
                            eAspect = resolved.aspect; eSite = resolved.site
                        }
                        
                        var sSite: Int? = nil
                        if let active = self.activeSelection, let sa = active.startAspect {
                            sAspect = sa
                            if let s = active.startSite, let e = active.endSite, let es = eSite {
                                sSite = min(s, min(e, es))
                                eSite = max(s, max(e, es))
                            } else {
                                sSite = active.startSite
                            }
                        }
                        
                        self.activeSelection = TeethSelection(
                            startTooth: ToothObject.create(number: refTooth), 
                            startAspect: sAspect, 
                            startSite: sSite, 
                            endTooth: ToothObject.create(number: refTooth), 
                            endAspect: eAspect, 
                            endSite: eSite
                        )
                        for i in tokenIndex..<peek { consumedIndices.insert(i) }
                        tokenIndex = peek
                        continue
                    } else {
                        self.activeSelection = nil
                        for i in tokenIndex..<peek { consumedIndices.insert(i) }
                        tokenIndex = peek
                        continue
                    }
                } else if a == .from {
                    // Intentional no-op. "dari" (from) anchors the start of a range but
                    // the actual start tooth is set by the following .toothIdentifier token.
                    // The .until / .until2 handler then closes the range from cursor.currentTooth.
                }
                tokenIndex += 1
                
            case .anatomy(let a):
                if let last = lastAutoAdvancedFromTooth, !hasUpcomingToothIdentifier(from: tokenIndex, in: tokens) {
                    _ = self.cursor.jumpTo(tooth: last, aspect: self.cursor.currentAspect, updateSequenceIndex: false)
                    lastAutoAdvancedFromTooth = nil
                }
                metricHadSpecificTargets = true
                
                if a == .lowerJaw || a == .upperJaw {
                    flushPostTargetIfPending()
                    isPostTargeting = false
                    postTargetTemplate = nil
                    postTargetAnatomy = nil
                } else {
                    if !currentNumbers.isEmpty && !isPostTargeting {
                        if self.activeSelection?.startAspect == nil && self.activeSelection?.startSite == nil {
                            startPostTargeting()
                        } else {
                            /* print("BEFORE EMIT METRIC..."); */ emitBoolIfPending()
                            flushNumbers(force: true)
                        }
                    }
                }
                
                if isPostTargeting {
                    postTargetAnatomy = a
                    tokenIndex += 1
                    continue
                }
                
                if a == .lowerJaw {
                    /* print("BEFORE EMIT METRIC..."); */ emitBoolIfPending()
                    flushNumbers(force: true)
                    self.activeSelection = nil
                    _ = self.cursor.jumpTo(jaw: .lower)
                } else if a == .upperJaw {
                    /* print("BEFORE EMIT METRIC..."); */ emitBoolIfPending()
                    flushNumbers(force: true)
                    self.activeSelection = nil
                    _ = self.cursor.jumpTo(jaw: .upper)
                } else {
                    if hasUpcomingToothIdentifier(from: tokenIndex, in: tokens) {
                        // Defer selection until the following tooth identifier is processed
                    } else {
                        var refTooth = self.cursor.currentTooth
                        
                        if let sel = activeSelection, tokenIndex > 0, case .toothIdentifier(_) = tokens[tokenIndex-1] {
                            refTooth = sel.startTooth.toothNumber
                        }
                        
                        if let resolved = resolveAnatomyWithLookahead(anatomy: a, for: refTooth, toothIndex: tokenIndex, tokens: tokens) {
                            if resolved.aspect != self.cursor.currentAspect {
                                if let active = self.activeSelection, active.startSite == nil && active.endSite == nil {
                                    // Do not emit full face for a newly targeted tooth just because the aspect changed
                                } else {
                                    emitBoolIfPending()
                                    flushNumbers(force: true)
                                }
                                let aspectType: AspectType = (resolved.aspect == .outer) ? .buccal : .palatal
                                _ = self.cursor.jumpTo(aspect: aspectType)
                            }
                            
                            if resolved.site == nil {
                                self.activeSelection = nil
                            } else {
                                if let existingSel = self.activeSelection,
                                   existingSel.startTooth.toothNumber == refTooth,
                                   existingSel.startAspect == resolved.aspect,
                                   existingSel.endTooth.toothNumber == refTooth,
                                   existingSel.endAspect == resolved.aspect,
                                   self.currentNumbers.isEmpty {
                                    let sSite = min(existingSel.startSite ?? resolved.site!, resolved.site!)
                                    let eSite = max(existingSel.endSite ?? resolved.site!, resolved.site!)
                                    self.activeSelection = TeethSelection(startTooth: existingSel.startTooth, startAspect: existingSel.startAspect, startSite: sSite, endTooth: existingSel.endTooth, endAspect: existingSel.endAspect, endSite: eSite)
                                } else {
                                    self.activeSelection = TeethSelection(startTooth: ToothObject.create(number: refTooth), startAspect: resolved.aspect, startSite: resolved.site, endTooth: ToothObject.create(number: refTooth), endAspect: resolved.aspect, endSite: resolved.site)
                                }
                            }
                        }
                    }
                }
                tokenIndex += 1
                
            case .word(let w):
                if w == "minus" && tokenIndex+1 < tokens.count, case .number(let n) = tokens[tokenIndex+1] {
                    currentNumbers.append(-n)
                    consumedIndices.insert(tokenIndex)
                    consumedIndices.insert(tokenIndex + 1)
                    tokenIndex += 2
                } else {
                    tokenIndex += 1
                }
            }
        }
        
        if isFinal {
            flushPostTargetIfPending()
            /* print("BEFORE EMIT METRIC..."); */ emitBoolIfPending()
            flushNumbers(force: true)
            
            if self.cursor.currentMetric == .plaque && !metricHadSpecificTargets {
                if let first = self.cursor.currentSequence.first, let last = self.cursor.currentSequence.last {
                    let sel = TeethSelection(startTooth: ToothObject.create(number: first), startAspect: nil, startSite: nil, endTooth: ToothObject.create(number: last), endAspect: nil, endSite: nil)
                    let cmd = AnnotationCommand(operation: .plaque, teethSelection: sel, aspect: nil, values: Array(repeating: "True", count: sel.expectedSlots))
                    commands.append(cmd)
                }
            }
        }
        
        self.pendingValues = currentNumbers.map { String($0) }
        return commands
    }
}

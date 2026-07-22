import Foundation

class VoiceCommandParser {
    var cursor: ChartingCursor
    var activeSelection: TeethSelection?
    var pendingValues: [String] = []
    var missingTeeth: Set<Int> = []
    
    var isPostTargeting: Bool = false
    var postTargetTemplate: AnnotationCommand? = nil
    var postTargetAnatomy: AnatomyType? = nil
    
    var metricHadSpecificTargets: Bool = false
    
    init(configuration: ChartingConfiguration) {
        self.cursor = ChartingCursor(configuration: configuration)
    }
    
    func parse(text: String, isFinal: Bool = false) -> [AnnotationCommand] {
        let tokens = VoiceTokenizer.tokenize(text: text)
        var commands: [AnnotationCommand] = []
        var i = 0
        
        var currentNumbers: [Int] = []
        var currentMetricMultiplier: Int = 1
        var lastAutoAdvancedFromTooth: Int? = nil
        
        func restoreToMainSequence() {
            cursor.setMetric(.probingDepth)
            currentMetricMultiplier = 1
            activeSelection = nil
            cursor.syncWithSequence()
            while missingTeeth.contains(cursor.currentTooth) {
                if !cursor.advanceToNextTooth() { break }
            }
        }
        
        func emitBoolIfPending() {
            let m = cursor.currentMetric
            if m == .bleeding || m == .plaque || m == .implant {
                if let sel = activeSelection {
                    let targetSlots = sel.expectedSlots
                    let values = Array(repeating: "True", count: targetSlots)
                    let cmd = AnnotationCommand(operation: m, teethSelection: sel, aspect: cursor.currentAspect, values: values)
                    commands.append(cmd)
                    activeSelection = nil
                }
            }
        }
        
        func flushNumbers(force: Bool = false) {
            if currentNumbers.isEmpty { return }
            
            let targetSlots = activeSelection?.expectedSlots ?? 3
            
            if currentNumbers.count >= targetSlots || force {
                var values = currentNumbers
                
                if values.count == 1 && targetSlots > 1 {
                    values = Array(repeating: values[0], count: targetSlots)
                } else if values.count < targetSlots {
                    let fill = values.last ?? 0
                    while values.count < targetSlots { values.append(fill) }
                }
                
                values = Array(values.prefix(targetSlots))
                
                let selectionToUse = activeSelection ?? TeethSelection(startTooth: ToothObject.create(number: cursor.currentTooth), startAspect: nil, startSite: nil, endTooth: ToothObject.create(number: cursor.currentTooth), endAspect: nil, endSite: nil)
                
                if self.activeSelection == nil || self.activeSelection?.expectedSlots == 3 {
                    let jaw: JawType = (11...28).contains(cursor.currentTooth) ? .upper : .lower
                    let aspectType: AspectType = cursor.currentAspect == .outer ? .buccal : .palatal
                    let dir = cursor.configuration.direction(for: jaw, aspect: aspectType)
                    
                    if dir == .rightToLeft {
                        values = values.reversed()
                    }
                }
                
                var valuesToEmit: [String] = []
                let m = cursor.currentMetric
                for n in values {
                    if m == .probingDepth {
                        valuesToEmit.append(String(abs(n)))
                    } else {
                        valuesToEmit.append(String(abs(n) * currentMetricMultiplier))
                    }
                }
                
                let cmd = AnnotationCommand(
                    operation: m,
                    teethSelection: selectionToUse,
                    aspect: cursor.currentAspect,
                    values: valuesToEmit
                )
                commands.append(cmd)
                let isPlainTooth = self.activeSelection != nil && self.activeSelection?.startAspect == nil && self.activeSelection?.endAspect == nil && self.activeSelection?.startTooth.toothNumber == self.activeSelection?.endTooth.toothNumber
                
                if (self.activeSelection == nil || isPlainTooth) && cursor.currentMetric == .probingDepth {
                    let oldTooth = cursor.currentTooth
                    _ = cursor.advanceToNextTooth()
                    lastAutoAdvancedFromTooth = oldTooth
                    while missingTeeth.contains(cursor.currentTooth) {
                        if !cursor.advanceToNextTooth() { break }
                    }
                }
                
                self.activeSelection = nil
                currentNumbers = []
            }
        }
        
        func finalizeValues(for sel: TeethSelection, baseValues: [String], isBoolMetric: Bool) -> [String] {
            var finalValues = baseValues
            let targetSlots = sel.expectedSlots
            
            if finalValues.count == 1 && targetSlots > 1 {
                finalValues = Array(repeating: finalValues[0], count: targetSlots)
            } else if finalValues.count < targetSlots {
                let fill = finalValues.last ?? (isBoolMetric ? "True" : "0")
                while finalValues.count < targetSlots { finalValues.append(fill) }
            }
            finalValues = Array(finalValues.prefix(targetSlots))
            
            if targetSlots == 3 {
                let jaw: JawType = (11...28).contains(sel.startTooth.toothNumber) ? .upper : .lower
                let cAspect = sel.startAspect ?? cursor.currentAspect
                let aspectType: AspectType = cAspect == .outer ? .buccal : .palatal
                if cursor.configuration.direction(for: jaw, aspect: aspectType) == .rightToLeft {
                    finalValues = finalValues.reversed()
                }
            }
            
            return finalValues
        }
        
        func flushPostTargetIfPending() {
            guard isPostTargeting, let template = postTargetTemplate else { return }
            
            var sAspect = template.teethSelection.startAspect
            var sSite = template.teethSelection.startSite
            
            if let pa = postTargetAnatomy, let resolved = ChartAnatomyResolver.resolve(anatomy: pa, for: cursor.currentTooth, currentAspect: cursor.currentAspect) {
                sAspect = resolved.aspect
                sSite = resolved.site
            }
            
            let finalSel = TeethSelection(startTooth: ToothObject.create(number: cursor.currentTooth), startAspect: sAspect, startSite: sSite, endTooth: ToothObject.create(number: cursor.currentTooth), endAspect: sAspect, endSite: sSite)
            
            let isBool = template.operation == .bleeding || template.operation == .plaque || template.operation == .implant
            let finalVals = finalizeValues(for: finalSel, baseValues: template.values, isBoolMetric: isBool)
            
            let cmd = AnnotationCommand(operation: template.operation, teethSelection: finalSel, aspect: finalSel.startAspect ?? template.aspect, values: finalVals)
            commands.append(cmd)
            
            isPostTargeting = false
            postTargetTemplate = nil
            postTargetAnatomy = nil
            
            restoreToMainSequence()
        }
        
        func startPostTargeting() {
            emitBoolIfPending()
            let isBoolMetric = cursor.currentMetric == .bleeding || cursor.currentMetric == .plaque || cursor.currentMetric == .implant
            
            if !currentNumbers.isEmpty || isBoolMetric {
                let sel = activeSelection ?? TeethSelection(startTooth: ToothObject.create(number: cursor.currentTooth), startAspect: nil, startSite: nil, endTooth: ToothObject.create(number: cursor.currentTooth), endAspect: nil, endSite: nil)
                
                var values: [String] = []
                let m = cursor.currentMetric
                for n in currentNumbers {
                    if m == .probingDepth {
                        values.append(String(abs(n)))
                    } else {
                        values.append(String(abs(n) * currentMetricMultiplier))
                    }
                }
                if isBoolMetric && values.isEmpty {
                    values = ["True"]
                }
                
                postTargetTemplate = AnnotationCommand(operation: cursor.currentMetric, teethSelection: sel, aspect: cursor.currentAspect, values: values)
                currentNumbers = []
            } else if let last = commands.last, last.operation == cursor.currentMetric {
                postTargetTemplate = commands.popLast()
            }
            isPostTargeting = true
            postTargetAnatomy = nil
            self.activeSelection = nil
        }
        
        func hasUpcomingToothIdentifier(from index: Int, in tokens: [VoiceToken]) -> Bool {
            var j = index + 1
            while j < tokens.count {
                switch tokens[j] {
                case .toothIdentifier(_):
                    return true
                case .metric(_, _), .action(_):
                    return false
                default:
                    j += 1
                }
            }
            return false
        }
        
        func resolveAnatomyWithLookahead(anatomy: AnatomyType, for tooth: Int, toothIndex: Int, tokens: [VoiceToken]) -> (aspect: ChartAspect, site: Int?)? {
            guard var resolved = ChartAnatomyResolver.resolve(anatomy: anatomy, for: tooth, currentAspect: cursor.currentAspect) else { return nil }
            let isFullAspectTarget = (anatomy == .buccal || anatomy == .labial || anatomy == .lingual || anatomy == .palatal)
            if isFullAspectTarget {
                var numCount = 0
                var j = toothIndex + 1
                lookaheadLoop: while j < tokens.count {
                    let t = tokens[j]
                    switch t {
                    case .number(_):
                        numCount += 1
                    case .anatomy(_), .metric(_), .toothIdentifier(_), .action(_):
                        break lookaheadLoop
                    case .word(_):
                        break
                    }
                    j += 1
                }
                if numCount < 3 {
                    resolved.site = 1
                }
            }
            return (resolved.aspect!, resolved.site)
        }
        
        func isContinuingList(from index: Int, in tokens: [VoiceToken]) -> Bool {
            var j = index
            while j < tokens.count {
                switch tokens[j] {
                case .toothIdentifier(_):
                    return true
                case .word(_):
                    j += 1
                default:
                    return false
                }
            }
            return false
        }
        
        while i < tokens.count {
            let token = tokens[i]
            
            switch token {
            case .number(let n):
                flushPostTargetIfPending()
                isPostTargeting = false
                if cursor.currentMetric == .bleeding || cursor.currentMetric == .plaque || cursor.currentMetric == .implant {
                    emitBoolIfPending()
                    restoreToMainSequence()
                }
                lastAutoAdvancedFromTooth = nil
                currentNumbers.append(n)
                flushNumbers(force: false)
                i += 1
                
            case .toothIdentifier(let tooth):
                lastAutoAdvancedFromTooth = nil
                metricHadSpecificTargets = true
                if isPostTargeting, let template = postTargetTemplate {
                    var isRange = false
                    var peek = i + 1
                    var endAnatomy: AnatomyType? = nil
                    var endTooth: Int? = nil
                    
                    if peek < tokens.count, case .action(let act) = tokens[peek], (act == .until || act == .until2 || act == .until3) {
                        isRange = true
                        peek += 1
                    }
                    
                    if isRange {
                        if peek < tokens.count, case .anatomy(let anat) = tokens[peek] {
                            endAnatomy = anat
                            peek += 1
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
                        if let pa = postTargetAnatomy, var resolved = ChartAnatomyResolver.resolve(anatomy: pa, for: tooth, currentAspect: cursor.currentAspect) {
                            let isFull = (pa == .buccal || pa == .labial || pa == .lingual || pa == .palatal)
                            if isFull && template.values.count < 3 { resolved.site = 1 }
                            sAspect = resolved.aspect; sSite = resolved.site
                        }
                        
                        var eAspect = template.teethSelection.endAspect
                        var eSite = template.teethSelection.endSite
                        if let ea = endAnatomy, var resolved = ChartAnatomyResolver.resolve(anatomy: ea, for: et, currentAspect: cursor.currentAspect) {
                            let isFull = (ea == .buccal || ea == .labial || ea == .lingual || ea == .palatal)
                            if isFull && template.values.count < 3 { resolved.site = 1 }
                            eAspect = resolved.aspect; eSite = resolved.site
                        } else if endAnatomy == nil {
                            eAspect = sAspect; eSite = sSite
                        }
                        
                        finalSel = TeethSelection(startTooth: ToothObject.create(number: tooth), startAspect: sAspect, startSite: sSite, endTooth: ToothObject.create(number: et), endAspect: eAspect, endSite: eSite)
                        i = peek
                    } else {
                        var sAspect = template.teethSelection.startAspect
                        var sSite = template.teethSelection.startSite
                        var eAspect = template.teethSelection.endAspect
                        var eSite = template.teethSelection.endSite
                        
                        if let pa = postTargetAnatomy, var resolved = ChartAnatomyResolver.resolve(anatomy: pa, for: tooth, currentAspect: cursor.currentAspect) {
                            let isFull = (pa == .buccal || pa == .labial || pa == .lingual || pa == .palatal)
                            if isFull && template.values.count < 3 { resolved.site = 1 }
                            sAspect = resolved.aspect
                            eAspect = resolved.aspect
                            sSite = resolved.site
                            eSite = resolved.site
                        }
                        
                        finalSel = TeethSelection(startTooth: ToothObject.create(number: tooth), startAspect: sAspect, startSite: sSite, endTooth: ToothObject.create(number: tooth), endAspect: eAspect, endSite: eSite)
                        
                        if isRange && endTooth == nil && endAnatomy != nil {
                            if let resolved = ChartAnatomyResolver.resolve(anatomy: endAnatomy!, for: tooth, currentAspect: cursor.currentAspect) {
                                finalSel.endAspect = resolved.aspect
                                finalSel.endSite = resolved.site
                            }
                            i = peek
                        } else {
                            i += 1
                        }
                    }
                    
                    let isBool = template.operation == .bleeding || template.operation == .plaque || template.operation == .implant
                    let finalVals = finalizeValues(for: finalSel, baseValues: template.values, isBoolMetric: isBool)
                    
                    let cmd = AnnotationCommand(operation: template.operation, teethSelection: finalSel, aspect: finalSel.startAspect ?? template.aspect, values: finalVals)
                    commands.append(cmd)
                    
                    if !isContinuingList(from: i, in: tokens) {
                        isPostTargeting = false
                        postTargetTemplate = nil
                        postTargetAnatomy = nil
                        restoreToMainSequence()
                    }
                    
                    continue
                }
                
                emitBoolIfPending()
                flushNumbers(force: true)
                
                _ = cursor.jumpTo(tooth: tooth, aspect: cursor.currentAspect, updateSequenceIndex: cursor.currentMetric == .probingDepth)
                
                var isRange = false
                var peek = i + 1
                var endAnatomy: AnatomyType? = nil
                var endTooth: Int? = nil
                
                if peek < tokens.count, case .action(let act) = tokens[peek], (act == .until || act == .until2) {
                    isRange = true
                    peek += 1
                }
                
                if isRange {
                    if peek < tokens.count, case .anatomy(let anat) = tokens[peek] {
                        endAnatomy = anat
                        peek += 1
                    }
                    if peek < tokens.count, case .toothIdentifier(let et) = tokens[peek] {
                        endTooth = et
                        peek += 1
                    }
                }
                
                var startAnatomy: AnatomyType? = nil
                if i > 0, case .anatomy(let anat) = tokens[i-1] {
                    startAnatomy = anat
                }
                
                if let et = endTooth {
                    var sAspect: ChartAspect?
                    var sSite: Int?
                    if let sa = startAnatomy, let resolved = resolveAnatomyWithLookahead(anatomy: sa, for: tooth, toothIndex: i, tokens: tokens) {
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
                    i = peek
                } else if isRange {
                    if let sa = startAnatomy, let resolved = resolveAnatomyWithLookahead(anatomy: sa, for: tooth, toothIndex: i, tokens: tokens) {
                        self.activeSelection = TeethSelection(startTooth: ToothObject.create(number: tooth), startAspect: resolved.aspect, startSite: resolved.site, endTooth: ToothObject.create(number: tooth), endAspect: resolved.aspect, endSite: resolved.site)
                    } else {
                        self.activeSelection = TeethSelection(startTooth: ToothObject.create(number: tooth), startAspect: nil, startSite: nil, endTooth: ToothObject.create(number: tooth), endAspect: nil, endSite: nil)
                    }
                    i = peek
                } else {
                    if let sa = startAnatomy, let resolved = resolveAnatomyWithLookahead(anatomy: sa, for: tooth, toothIndex: i, tokens: tokens) {
                        self.activeSelection = TeethSelection(startTooth: ToothObject.create(number: tooth), startAspect: resolved.aspect, startSite: resolved.site, endTooth: ToothObject.create(number: tooth), endAspect: resolved.aspect, endSite: resolved.site)
                    } else {
                        self.activeSelection = TeethSelection(startTooth: ToothObject.create(number: tooth), startAspect: nil, startSite: nil, endTooth: ToothObject.create(number: tooth), endAspect: nil, endSite: nil)
                    }
                    i += 1
                }
                
            case .metric(let m, let mult):
                if let last = lastAutoAdvancedFromTooth, !hasUpcomingToothIdentifier(from: i, in: tokens) {
                    _ = cursor.jumpTo(tooth: last, aspect: cursor.currentAspect, updateSequenceIndex: false)
                    lastAutoAdvancedFromTooth = nil
                }
                isPostTargeting = false
                postTargetTemplate = nil
                postTargetAnatomy = nil
                emitBoolIfPending()
                flushNumbers(force: true)
                
                if cursor.currentMetric == .plaque && !metricHadSpecificTargets {
                    if let first = cursor.currentSequence.first, let last = cursor.currentSequence.last {
                        let sel = TeethSelection(startTooth: ToothObject.create(number: first), startAspect: nil, startSite: nil, endTooth: ToothObject.create(number: last), endAspect: nil, endSite: nil)
                        let cmd = AnnotationCommand(operation: .plaque, teethSelection: sel, aspect: nil, values: Array(repeating: "True", count: sel.expectedSlots))
                        commands.append(cmd)
                    }
                }
                
                if currentNumbers.isEmpty, let sel = activeSelection {
                    _ = cursor.jumpTo(tooth: sel.startTooth.toothNumber, aspect: sel.startAspect ?? cursor.currentAspect, updateSequenceIndex: false)
                }
                
                self.activeSelection = nil
                cursor.setMetric(m)
                currentMetricMultiplier = mult ?? 1
                metricHadSpecificTargets = false
                i += 1
                
            case .action(let a):
                lastAutoAdvancedFromTooth = nil
                if a == .at || a == .at2 {
                    startPostTargeting()
                } else if a == .all {
                    metricHadSpecificTargets = true
                    if let first = cursor.currentSequence.first, let last = cursor.currentSequence.last {
                        let sel = TeethSelection(startTooth: ToothObject.create(number: first), startAspect: nil, startSite: nil, endTooth: ToothObject.create(number: last), endAspect: nil, endSite: nil)
                        if isPostTargeting, let template = postTargetTemplate {
                            let cmd = AnnotationCommand(operation: template.operation, teethSelection: sel, aspect: nil, values: Array(repeating: template.values.first ?? "True", count: sel.expectedSlots))
                            commands.append(cmd)
                        } else {
                            self.activeSelection = sel
                            emitBoolIfPending()
                            flushNumbers(force: true)
                        }
                    }
                    isPostTargeting = false
                    postTargetTemplate = nil
                    postTargetAnatomy = nil
                } else if a == .next {
                    flushPostTargetIfPending()
                    isPostTargeting = false
                    postTargetTemplate = nil
                    postTargetAnatomy = nil
                    emitBoolIfPending()
                    flushNumbers(force: true)
                    
                    if cursor.currentMetric == .plaque && !metricHadSpecificTargets {
                        if let first = cursor.currentSequence.first, let last = cursor.currentSequence.last {
                            let sel = TeethSelection(startTooth: ToothObject.create(number: first), startAspect: nil, startSite: nil, endTooth: ToothObject.create(number: last), endAspect: nil, endSite: nil)
                            let cmd = AnnotationCommand(operation: .plaque, teethSelection: sel, aspect: nil, values: Array(repeating: "True", count: sel.expectedSlots))
                            commands.append(cmd)
                        }
                    }
                    
                    restoreToMainSequence()
                } else if a == .missing || a == .missing2 {
                    flushPostTargetIfPending()
                    emitBoolIfPending()
                    flushNumbers(force: true)
                    
                    let targetTooth = activeSelection?.startTooth.toothNumber ?? cursor.currentTooth
                    self.missingTeeth.insert(targetTooth)
                    
                    let cmd = AnnotationCommand(
                        operation: .missing,
                        teethSelection: TeethSelection(startTooth: ToothObject.create(number: targetTooth), startAspect: nil, startSite: nil, endTooth: ToothObject.create(number: targetTooth), endAspect: nil, endSite: nil),
                        aspect: cursor.currentAspect,
                        values: ["True"]
                    )
                    commands.append(cmd)
                    self.activeSelection = nil
                    
                    if targetTooth == cursor.currentTooth {
                        _ = cursor.advanceToNextTooth()
                        while missingTeeth.contains(cursor.currentTooth) {
                            if !cursor.advanceToNextTooth() { break }
                        }
                    }
                    
                    restoreToMainSequence()
                } else if a == .until || a == .until2 || a == .until3 {
                    emitBoolIfPending()
                    flushNumbers(force: true)
                    var peek = i + 1
                    var endAnatomy: AnatomyType? = nil
                    var endTooth: Int? = nil
                    
                    if peek < tokens.count, case .anatomy(let anat) = tokens[peek] {
                        endAnatomy = anat
                        peek += 1
                    }
                    if peek < tokens.count, case .toothIdentifier(let et) = tokens[peek] {
                        endTooth = et
                        peek += 1
                    }
                    
                    if let et = endTooth {
                        var eAspect: ChartAspect? = cursor.currentAspect
                        var eSite: Int? = nil
                        if let ea = endAnatomy, let resolved = ChartAnatomyResolver.resolve(anatomy: ea, for: et, currentAspect: cursor.currentAspect) {
                            eAspect = resolved.aspect; eSite = resolved.site
                        }
                        
                        self.activeSelection = TeethSelection(
                            startTooth: ToothObject.create(number: cursor.currentTooth), 
                            startAspect: cursor.currentAspect, 
                            startSite: nil, 
                            endTooth: ToothObject.create(number: et), 
                            endAspect: eAspect, 
                            endSite: eSite
                        )
                        i = peek
                        continue
                    } else if let ea = endAnatomy {
                        let refTooth = self.activeSelection?.startTooth.toothNumber ?? cursor.currentTooth
                        var sAspect: ChartAspect? = cursor.currentAspect
                        var sSite: Int? = nil
                        if let active = self.activeSelection, let sa = active.startAspect {
                            sAspect = sa
                            sSite = active.startSite
                        }
                        
                        var eAspect: ChartAspect? = cursor.currentAspect
                        var eSite: Int? = nil
                        if let resolved = ChartAnatomyResolver.resolve(anatomy: ea, for: refTooth, currentAspect: cursor.currentAspect) {
                            eAspect = resolved.aspect; eSite = resolved.site
                        }
                        
                        self.activeSelection = TeethSelection(
                            startTooth: ToothObject.create(number: refTooth), 
                            startAspect: sAspect, 
                            startSite: sSite, 
                            endTooth: ToothObject.create(number: refTooth), 
                            endAspect: eAspect, 
                            endSite: eSite
                        )
                        i = peek
                        continue
                    } else {
                        self.activeSelection = nil
                        i = peek
                        continue
                    }
                }
                i += 1
                
            case .anatomy(let a):
                if let last = lastAutoAdvancedFromTooth, !hasUpcomingToothIdentifier(from: i, in: tokens) {
                    _ = cursor.jumpTo(tooth: last, aspect: cursor.currentAspect, updateSequenceIndex: false)
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
                        startPostTargeting()
                    }
                }
                
                if isPostTargeting {
                    postTargetAnatomy = a
                    i += 1
                    continue
                }
                
                if a == .lowerJaw {
                    emitBoolIfPending()
                    flushNumbers(force: true)
                    self.activeSelection = nil
                    _ = cursor.jumpTo(jaw: .lower)
                } else if a == .upperJaw {
                    emitBoolIfPending()
                    flushNumbers(force: true)
                    self.activeSelection = nil
                    _ = cursor.jumpTo(jaw: .upper)
                } else {
                    if i + 1 < tokens.count, case .toothIdentifier(_) = tokens[i+1] {
                        // Defer selection until the following tooth identifier is processed
                    } else {
                        var refTooth = cursor.currentTooth
                        var isModifyingExisting = false
                        
                        if let sel = activeSelection, i > 0, case .toothIdentifier(_) = tokens[i-1] {
                            refTooth = sel.startTooth.toothNumber
                            isModifyingExisting = true
                        }
                        
                        if let resolved = resolveAnatomyWithLookahead(anatomy: a, for: refTooth, toothIndex: i, tokens: tokens) {
                            
                            if resolved.aspect != cursor.currentAspect {
                                emitBoolIfPending()
                                flushNumbers(force: true)
                                let aspectType: AspectType = (resolved.aspect == .outer) ? .buccal : .palatal
                                _ = cursor.jumpTo(aspect: aspectType)
                            }
                            
                            if resolved.site == nil {
                                self.activeSelection = nil
                            } else {
                                if isModifyingExisting {
                                    self.activeSelection = TeethSelection(startTooth: ToothObject.create(number: refTooth), startAspect: resolved.aspect, startSite: resolved.site, endTooth: ToothObject.create(number: refTooth), endAspect: resolved.aspect, endSite: resolved.site)
                                } else {
                                    self.activeSelection = TeethSelection(startTooth: ToothObject.create(number: cursor.currentTooth), startAspect: resolved.aspect, startSite: resolved.site, endTooth: ToothObject.create(number: cursor.currentTooth), endAspect: resolved.aspect, endSite: resolved.site)
                                }
                            }
                        }
                    }
                }
                i += 1
                
            case .word(let w):
                if w == "minus" && i+1 < tokens.count, case .number(let n) = tokens[i+1] {
                    currentNumbers.append(-n)
                    i += 2
                } else {
                    i += 1
                }
            }
        }
        
        if isFinal {
            emitBoolIfPending()
            flushNumbers(force: true)
            
            if cursor.currentMetric == .plaque && !metricHadSpecificTargets {
                if let first = cursor.currentSequence.first, let last = cursor.currentSequence.last {
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

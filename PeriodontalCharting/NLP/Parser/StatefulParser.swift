import Foundation

struct StatefulParser: Equatable, Sendable {
    // --- Cursor & traversal ---
    var cursor: ChartingCursor
    var missingTeeth: Set<Int> = []
    var lastAutoAdvancedFromTooth: Int? = nil

    // --- Numeric buffer ---
    var pendingNumbers: [Int] = []
    var currentMetricMultiplier: Int = 1
    var isNextNumberNegative: Bool = false

    // --- Target selection ---
    var activeSelection: TeethSelection?
    var isSelectionUsed: Bool = false
    var pendingAnatomies: [AnatomyType] = []
    var pendingTeeth: [Int] = []

    // --- Range state ---
    var isWaitingForRangeEnd: Bool = false
    var pendingRangeDigits: [Int] = []

    // --- Post-targeting ---
    var isPostTargeting: Bool = false
    var postTargetTemplate: AnnotationCommand? = nil
    var postTargetAnatomy: AnatomyType? = nil
    
    var didSpecifyExplicitFullAspect: Bool = false

    // --- List aggregation ---
    var isListAggregationActive: Bool = false

    // --- Range start pending ---
    // Set by case .from (no pending numbers) so the immediately following
    // full-aspect anatomy (e.g. "bukal") is stored in pendingAnatomies instead
    // of consumed by a cursor-jump early-return.  Cleared on next toothIdentifier.
    var isRangeStartPending: Bool = false

    // --- Metric context ---
    var metricHadSpecificTargets: Bool = false
    var isFreshMetric: Bool = false

    // --- Output ---
    var commands: [AnnotationCommand] = []

    var pendingValues: [String] {
        return pendingNumbers.map { String($0) }
    }

    init(configuration: ChartingConfiguration) {
        self.cursor = ChartingCursor(configuration: configuration)
    }

    mutating func consume(tokens: [VoiceToken], isFinal: Bool = false) {
        for token in tokens {
            parserTrace("CONSUME TOKEN: \(token)")
            consume(token: token)
        }
        if isFinal {
            // Force-commit everything in the buffer
            if !pendingNumbers.isEmpty { parserTrace("CALLING flushNumbers(true) from line (#line)"); parserTrace("CALLING flushNumbers(true) from line \(#line)"); flushNumbers(force: true) }
            emitBoolIfPending()
            pendingRangeDigits = []
            isWaitingForRangeEnd = false
        }
    }

    mutating func consume(token: VoiceToken) {
        switch token {
        case .number(var n):
            if isNextNumberNegative {
                n = -n
                isNextNumberNegative = false
            }
            if cursor.currentMetric == .bleeding || cursor.currentMetric == .plaque || cursor.currentMetric == .implant {
                emitBoolIfPending()
                restoreToMainSequence()
            }
            lastAutoAdvancedFromTooth = nil
            isRangeStartPending = false
            
            if isWaitingForRangeEnd {
                // Fragmented digit accumulator
                pendingRangeDigits.append(n)
                tryResolveRangeDigits()
                return // skip appending to pendingNumbers
            }
            
            var didResolveAnatomy = false
            if activeSelection == nil && !pendingAnatomies.isEmpty {
                var newSel = TeethSelection(
                    startTooth: ToothObject.create(number: cursor.currentTooth),
                    startAspect: nil,
                    startSite: nil,
                    endTooth: ToothObject.create(number: cursor.currentTooth),
                    endAspect: nil,
                    endSite: nil
                )
                
                for pa in pendingAnatomies {
                    if let resolved = ChartAnatomyResolver.resolve(anatomy: pa, for: cursor.currentTooth, currentAspect: cursor.currentAspect) {
                        let aspectToSet = (pa == .mesial || pa == .distal) ? nil : resolved.aspect
                        if newSel.startSite == nil && newSel.endSite == nil {
                            newSel.startAspect = aspectToSet
                            newSel.endAspect = aspectToSet
                            newSel.startSite = resolved.site
                            newSel.endSite = resolved.site
                        } else {
                            let sSite = min(newSel.startSite ?? 1, resolved.site ?? 1)
                            let eSite = max(newSel.endSite ?? 1, resolved.site ?? 1)
                            newSel.startSite = sSite
                            newSel.endSite = eSite
                        }
                    }
                }
                activeSelection = newSel
                // Keep pendingAnatomies alive — if .at follows ("pada gigi 16,17…"),
                // the anatomy tokens must still be available to propagate to each
                // tooth in the list via flushNumbers.
                // pendingAnatomies is cleared only when the selection is flushed or
                // consumed in a non-list context.
                didResolveAnatomy = true
            }

            
            if didResolveAnatomy && !pendingNumbers.isEmpty {
                parserTrace("CALLING flushNumbers(true) from line \(#line)"); flushNumbers(force: true)
                emitBoolIfPending()
                activeSelection = nil
            }
            
            if pendingNumbers.isEmpty {
                if activeSelection == nil && cursor.currentMetric != .probingDepth {
                    let currentToothObj = ToothObject.create(number: cursor.currentTooth)
                    activeSelection = TeethSelection(startTooth: currentToothObj, startAspect: cursor.currentAspect, startSite: nil, endTooth: currentToothObj, endAspect: cursor.currentAspect, endSite: nil)
                    isFreshMetric = true
                } else if activeSelection != nil {
                    if isFreshMetric {
                        isFreshMetric = false
                    }
                }
            }
            
            pendingNumbers.append(n)
            
            // Auto-override metric if we get 3 numbers for a 1-slot metric
            if pendingNumbers.count >= 3 && cursor.currentMetric != .probingDepth {
                cursor.setMetric(.probingDepth)
                if !metricHadSpecificTargets {
                    restoreToMainSequence()
                } else {
                    _ = cursor.jumpTo(tooth: cursor.currentTooth, aspect: cursor.currentAspect, updateSequenceIndex: true)
                }
            }
            
            parserTrace("CALLING flushNumbers(false) from line \(#line)"); flushNumbers(force: false)
            isListAggregationActive = false
            
        case .toothIdentifier(let tooth):
            lastAutoAdvancedFromTooth = nil
            let hadTargets = metricHadSpecificTargets
            metricHadSpecificTargets = true
            isNextNumberNegative = false
            pendingRangeDigits = [] // Clear any accumulated range digits
            
            let newToothObj = ToothObject.create(number: tooth)
            
            if isWaitingForRangeEnd {
                var sel = activeSelection ?? TeethSelection(startTooth: ToothObject.create(number: cursor.currentTooth), startAspect: nil, startSite: nil, endTooth: ToothObject.create(number: cursor.currentTooth), endAspect: nil, endSite: nil)
                sel.endTooth = newToothObj
                if !pendingAnatomies.isEmpty {
                    for pa in pendingAnatomies {
                        if let resolved = ChartAnatomyResolver.resolve(anatomy: pa, for: tooth, currentAspect: cursor.currentAspect) {
                            let aspectToSet = (pa == .mesial || pa == .distal) ? nil : resolved.aspect
                            sel.endAspect = aspectToSet
                            sel.endSite = resolved.site
                        }
                    }
                }
                
                if pendingAnatomies.isEmpty {
                    if let _ = activeSelection, !isWaitingForRangeEnd {
                        let prevAspect = activeSelection?.startAspect ?? cursor.currentAspect
                        let prevStartSite = activeSelection?.startSite
                        let prevEndSite = activeSelection?.endSite
                        
                        sel.startAspect = prevAspect
                        sel.endAspect = prevAspect
                        sel.startSite = prevStartSite
                        sel.endSite = prevEndSite
                    }
                }
                pendingAnatomies = []
                activeSelection = sel
                isWaitingForRangeEnd = false
                
                if isPostTargeting {
                    isPostTargeting = false
                }
                
                _ = cursor.jumpTo(tooth: tooth, aspect: activeSelection?.endAspect ?? cursor.currentAspect, updateSequenceIndex: cursor.currentMetric == .probingDepth)
            } else {
                let isPlainTooth = activeSelection != nil && activeSelection!.startSite == nil && activeSelection!.startAspect == nil && activeSelection!.endSite == nil && activeSelection!.endAspect == nil && pendingAnatomies.isEmpty
                
                parserTrace("DEBUG toothIdentifier(\(tooth)): else block entered. activeSel=\(activeSelection != nil), pendingEmpty=\(pendingNumbers.isEmpty), listAgg=\(isListAggregationActive), isPlainTooth=\(isPlainTooth), rangeStart=\(isRangeStartPending), freshMetric=\(isFreshMetric)")
                if let _ = activeSelection, pendingNumbers.isEmpty {
                    if isRangeStartPending {
                        activeSelection?.endTooth = ToothObject.create(number: tooth)
                        isRangeStartPending = false
                    } else if isListAggregationActive || isPlainTooth {
                        if !pendingTeeth.contains(tooth) {
                            pendingTeeth.append(tooth)
                        }
                        isListAggregationActive = false
                    } else {
                        emitBoolIfPending()
                        
                        let prevAspect = activeSelection?.startAspect ?? cursor.currentAspect
                        let prevSite = activeSelection?.startSite
                        let prevEndAspect = activeSelection?.endAspect ?? cursor.currentAspect
                        let prevEndSite = activeSelection?.endSite
                        
                        activeSelection = nil
                        didSpecifyExplicitFullAspect = false
                        
                        let currentToothObj = ToothObject.create(number: tooth)
                        activeSelection = TeethSelection(
                            startTooth: currentToothObj,
                            startAspect: prevAspect,
                            startSite: prevSite,
                            endTooth: currentToothObj,
                            endAspect: prevEndAspect,
                            endSite: prevEndSite
                        )
                        isSelectionUsed = false
                        
                        let currentAspect = cursor.currentAspect
                        if !pendingAnatomies.isEmpty {
                            for a in pendingAnatomies {
                                if let resolved = ChartAnatomyResolver.resolve(anatomy: a, for: tooth, currentAspect: currentAspect) {
                                    activeSelection?.startAspect = resolved.aspect ?? currentAspect
                                    activeSelection?.endAspect = resolved.aspect ?? currentAspect
                                    if activeSelection?.startSite == nil && activeSelection?.endSite == nil {
                                        activeSelection?.startSite = resolved.site
                                        activeSelection?.endSite = resolved.site
                                    } else {
                                        let currStart = activeSelection?.startSite ?? 1
                                        let currEnd = activeSelection?.endSite ?? 1
                                        activeSelection?.startSite = min(currStart, resolved.site ?? 1)
                                        activeSelection?.endSite = max(currEnd, resolved.site ?? 1)
                                    }
                                }
                            }
                            pendingAnatomies.removeAll()
                        }
                    }
                    _ = cursor.jumpTo(tooth: tooth)
                    
                } else if !pendingNumbers.isEmpty {
                    if isListAggregationActive || isPostTargeting {
                        isListAggregationActive = true
                        pendingTeeth.append(newToothObj.toothNumber)
                        isPostTargeting = false
                    } else if !hadTargets {
                        parserTrace("DEBUG toothIdentifier(\(tooth)): implicitly post-targeting because no specific targets yet")
                        activeSelection?.startTooth = newToothObj
                        activeSelection?.endTooth = newToothObj
                        _ = cursor.jumpTo(tooth: tooth)
                        // Note: we do NOT flush here! The pending numbers remain,
                        // and will be flushed on the NEXT separator or command, 
                        // now correctly bound to this new tooth.
                    } else if !pendingAnatomies.isEmpty {
                        var sel = TeethSelection(startTooth: newToothObj, startAspect: nil, startSite: nil, endTooth: newToothObj, endAspect: nil, endSite: nil)
                        var didSpecifyExplicitFullAspect = false
                        for pa in pendingAnatomies {
                            if let resolved = ChartAnatomyResolver.resolve(anatomy: pa, for: newToothObj.toothNumber, currentAspect: cursor.currentAspect) {
                                if sel.startSite == nil && sel.endSite == nil {
                                    if resolved.site == nil {
                                        didSpecifyExplicitFullAspect = true
                                    }
                                    let aspectToSet = (pa == .mesial || pa == .distal) ? nil : resolved.aspect
                                    sel.startAspect = aspectToSet
                                    sel.endAspect = aspectToSet
                                    sel.startSite = resolved.site
                                    sel.endSite = resolved.site
                                } else {
                                    let sSite = min(sel.startSite ?? 1, resolved.site ?? 1)
                                    let eSite = max(sel.endSite ?? 1, resolved.site ?? 1)
                                    sel.startSite = sSite
                                    sel.endSite = eSite
                                }
                            }
                        }
                        if didSpecifyExplicitFullAspect && sel.startSite == nil && sel.endSite == nil {
                            sel.startSite = nil
                            sel.endSite = nil
                        }
                        activeSelection = sel
                        pendingAnatomies = []
                        parserTrace("CALLING flushNumbers(false) from line \(#line)"); flushNumbers(force: false)
                    } else {
                        parserTrace("CALLING flushNumbers(true) from line \(#line)"); flushNumbers(force: true)
                        emitBoolIfPending()
                        activeSelection = nil
                        let currentToothObj = ToothObject.create(number: tooth)
                        activeSelection = TeethSelection(
                            startTooth: currentToothObj,
                            startAspect: cursor.currentAspect,
                            startSite: nil,
                            endTooth: currentToothObj,
                            endAspect: cursor.currentAspect,
                            endSite: nil
                        )
                    }
                }
                
                if !isRangeStartPending && !isFreshMetric {
                    emitBoolIfPending()
                }
                
                if activeSelection == nil {
                    var sel = TeethSelection(startTooth: newToothObj, startAspect: nil, startSite: nil, endTooth: newToothObj, endAspect: nil, endSite: nil)
                    for pa in pendingAnatomies {
                        if let resolved = ChartAnatomyResolver.resolve(anatomy: pa, for: tooth, currentAspect: cursor.currentAspect) {
                            let aspectToSet = (pa == .mesial || pa == .distal) ? nil : resolved.aspect
                            if sel.startSite == nil && sel.endSite == nil {
                                sel.startAspect = aspectToSet
                                sel.endAspect = aspectToSet
                                sel.startSite = resolved.site
                                sel.endSite = resolved.site
                            } else {
                                let sSite = min(sel.startSite ?? 1, resolved.site ?? 1)
                                let eSite = max(sel.endSite ?? 1, resolved.site ?? 1)
                                sel.startSite = sSite
                                sel.endSite = eSite
                            }
                        }
                    }
                    activeSelection = sel
                    isSelectionUsed = false
                    didSpecifyExplicitFullAspect = false
                    isWaitingForRangeEnd = false
                    isRangeStartPending = false
                    
                    if isPostTargeting {
                        isPostTargeting = false
                    }
                }
                
                // Preserve pendingAnatomies in list-aggregation mode so flushNumbers
                // can apply the anatomy (e.g. "bukal") to every tooth in the list.
                if !isListAggregationActive {
                        pendingAnatomies = []
                    }
                    if pendingTeeth.isEmpty {
                        pendingTeeth = [newToothObj.toothNumber]
                    }

                
                let jumpSuccess = cursor.jumpTo(tooth: tooth, aspect: activeSelection?.startAspect ?? cursor.currentAspect, updateSequenceIndex: cursor.currentMetric == .probingDepth)
                parserTrace("DEBUG JUMP: jumping to \(tooth) aspect=\(activeSelection?.startAspect ?? cursor.currentAspect) updateSeq=\(cursor.currentMetric == .probingDepth) -> success=\(jumpSuccess). currentTooth is now \(cursor.currentTooth)")
            }
            
        case .metric(let m, let mult):
            if let last = lastAutoAdvancedFromTooth {
                _ = cursor.jumpTo(tooth: last, aspect: cursor.currentAspect, updateSequenceIndex: false)
                lastAutoAdvancedFromTooth = nil
            }
            isListAggregationActive = false
            isNextNumberNegative = false
            isRangeStartPending = false
            
            if !pendingNumbers.isEmpty {
                parserTrace("CALLING flushNumbers(true) from line (#line)"); parserTrace("CALLING flushNumbers(true) from line \(#line)"); flushNumbers(force: true)
            }
            
            let prevMetric = cursor.currentMetric
            if prevMetric == .bleeding || prevMetric == .plaque || prevMetric == .implant {
                if activeSelection != nil {
                    emitBoolIfPending()
                    restoreToMainSequence()
                }
            }
            
            cursor.setMetric(m)
            currentMetricMultiplier = mult
            metricHadSpecificTargets = false
            isPostTargeting = false
            isFreshMetric = true
            pendingRangeDigits = []
            
        case .anatomy(let a):
            if let last = lastAutoAdvancedFromTooth {
                _ = cursor.jumpTo(tooth: last, aspect: cursor.currentAspect, updateSequenceIndex: false)
                lastAutoAdvancedFromTooth = nil
            }
            isListAggregationActive = false
            isNextNumberNegative = false
            pendingRangeDigits = []
            
            if a == .upperJaw || a == .lowerJaw {
                discardOrFlush()
                activeSelection = nil
                didSpecifyExplicitFullAspect = false
                _ = cursor.jumpTo(jaw: a == .upperJaw ? .upper : .lower)
                cursor.setMetric(.probingDepth)
                currentMetricMultiplier = 1
                return
            }
            
            if isWaitingForRangeEnd {
                pendingAnatomies.append(a)
                return
            }

            
            if activeSelection == nil {
                if let resolved = ChartAnatomyResolver.resolve(anatomy: a, for: cursor.currentTooth, currentAspect: cursor.currentAspect) {
                    if resolved.aspect != cursor.currentAspect {
                        let aspectType: AspectType = (resolved.aspect == .outer) ? .buccal : .palatal
                        _ = cursor.jumpTo(aspect: aspectType)
                    }
                    
                    if resolved.site == nil {
                        if !isRangeStartPending {
                            // Normal pass-switch (even if redundant): consume via cursor jump, and allow it to be stored.
                            isRangeStartPending = false
                        }
                        // isRangeStartPending: this anatomy anchors the range start —
                        // fall through to store it in pendingAnatomies.
                        isRangeStartPending = false
                    }
                }
                pendingAnatomies.append(a)
            } else {
                // activeSelection != nil — clear any pending range-start flag
                isRangeStartPending = false
                let refTooth = activeSelection?.startTooth.toothNumber ?? cursor.currentTooth
                if let resolved = ChartAnatomyResolver.resolve(anatomy: a, for: refTooth, currentAspect: cursor.currentAspect) {
                    
                    if resolved.aspect != cursor.currentAspect {
                        if activeSelection?.startSite != nil || activeSelection?.endSite != nil {
                            emitBoolIfPending()
                            if !pendingNumbers.isEmpty { parserTrace("CALLING flushNumbers(true) from line (#line)"); parserTrace("CALLING flushNumbers(true) from line \(#line)"); flushNumbers(force: true) }
                        }
                        let aspectType: AspectType = (resolved.aspect == .outer) ? .buccal : .palatal
                        _ = cursor.jumpTo(aspect: aspectType)
                    }
                    
                    if resolved.site == nil {
                        if !pendingNumbers.isEmpty {
                            if activeSelection?.startSite == nil && activeSelection?.endSite == nil && !(didSpecifyExplicitFullAspect) {
                                activeSelection?.startAspect = resolved.aspect
                                activeSelection?.endAspect = resolved.aspect
                                didSpecifyExplicitFullAspect = true
                            } else {
                                discardOrFlush()
                                pendingAnatomies.append(a)
                            }
                        } else {
                            if let sel = activeSelection, (sel.startSite != nil || sel.endSite != nil), sel.startAspect == resolved.aspect {
                                let sSite = min(sel.startSite ?? 1, 1)
                                let eSite = max(sel.endSite ?? 1, 1)
                                activeSelection?.startSite = sSite
                                activeSelection?.endSite = eSite
                            } else {
                                activeSelection?.startAspect = resolved.aspect
                                activeSelection?.endAspect = resolved.aspect
                                activeSelection?.startSite = nil
                                activeSelection?.endSite = nil
                                didSpecifyExplicitFullAspect = true
                            }
                        }
                    } else {
                        if let sel = activeSelection, sel.startAspect == resolved.aspect, sel.endAspect == resolved.aspect, pendingNumbers.isEmpty {
                            if sel.startSite == nil && sel.endSite == nil {
                                if didSpecifyExplicitFullAspect {
                                    activeSelection?.startSite = min(1, resolved.site!)
                                    activeSelection?.endSite = max(1, resolved.site!)
                                } else {
                                    activeSelection?.startSite = resolved.site
                                    activeSelection?.endSite = resolved.site
                                }
                            } else {
                                if isSelectionUsed {
                                    activeSelection?.startSite = resolved.site
                                    activeSelection?.endSite = resolved.site
                                    isSelectionUsed = false
                                } else {
                                    let sSite = min(sel.startSite!, resolved.site!)
                                    let eSite = max(sel.endSite!, resolved.site!)
                                    activeSelection?.startSite = sSite
                                    activeSelection?.endSite = eSite
                                }
                            }
                        } else {
                            if !pendingNumbers.isEmpty {
                                if activeSelection?.startSite == nil && activeSelection?.endSite == nil {
                                    parserTrace("DEBUG ANATOMY: applying anatomy \(a) to existing activeSelection because startSite was nil")
                                    let aspectToSet = (a == .mesial || a == .distal) ? nil : resolved.aspect
                                    activeSelection?.startAspect = aspectToSet
                                    activeSelection?.endAspect = aspectToSet
                                    activeSelection?.startSite = resolved.site
                                    activeSelection?.endSite = resolved.site
                                } else {
                                    discardOrFlush()
                                    pendingAnatomies.append(a)
                                }
                            } else {
                                let aspectToSet = (a == .mesial || a == .distal) ? nil : resolved.aspect
                                activeSelection?.startAspect = aspectToSet
                                activeSelection?.endAspect = aspectToSet
                                activeSelection?.startSite = resolved.site
                                activeSelection?.endSite = resolved.site
                            }
                        }
                    }
                }
            }
            
        case .action(let a):
            lastAutoAdvancedFromTooth = nil
            isListAggregationActive = false
            pendingRangeDigits = []
            
            switch a {
            case .next, .commit:
                discardOrFlush()
                restoreToMainSequence()
                
            case .missing:
                var targets = pendingTeeth
                
                if let explicitSel = activeSelection?.startTooth.toothNumber {
                    if !targets.contains(explicitSel) {
                        if !isSelectionUsed {
                            targets.append(explicitSel)
                        } else if !pendingNumbers.isEmpty {
                            targets.append(explicitSel)
                        }
                    }
                }
                
                discardOrFlush()
                
                if targets.isEmpty {
                    parserTrace("DEBUG Parser: Ignoring .missing because no explicit tooth was targeted")
                } else {
                    for targetTooth in targets {
                        missingTeeth.insert(targetTooth)
                        let cmd = AnnotationCommand(
                            operation: .missing,
                            teethSelection: TeethSelection(startTooth: ToothObject.create(number: targetTooth), startAspect: nil, startSite: nil, endTooth: ToothObject.create(number: targetTooth), endAspect: nil, endSite: nil),
                            aspect: cursor.currentAspect,
                            values: ["True"]
                        )
                        commands.append(cmd)
                    }
                    
                    pendingTeeth = []
                    activeSelection = nil
                    didSpecifyExplicitFullAspect = false
                    cursor.resyncToothToSequence()
                    cursor.syncWithSequence()
                    
                    while missingTeeth.contains(cursor.currentTooth) {
                        if !cursor.advanceToNextTooth() { break }
                    }
                    restoreToMainSequence()
                }
                
            case .until, .until2:
                isWaitingForRangeEnd = true
                
            case .from:
                lastAutoAdvancedFromTooth = nil
                isListAggregationActive = false
                
                if !pendingNumbers.isEmpty {
                    isPostTargeting = true
                } else {
                    if !isFreshMetric {
                        emitBoolIfPending()
                    }
                    activeSelection = nil
                    isRangeStartPending = true
                }
                
            case .at, .at2:
                if !pendingNumbers.isEmpty {
                    // Always defer to isPostTargeting so that a subsequent tooth-list
                    // (e.g. "pada gigi 16, 17, 26, 27") receives the command instead
                    // of immediately flushing to the current cursor tooth.
                    // pendingAnatomies is intentionally NOT cleared here — flushNumbers
                    // will use them to apply the anatomy to each tooth in the list.
                    isPostTargeting = true
                    activeSelection = nil   // discard any eagerly-built cursor-tooth selection
                }
                
            case .all:
                metricHadSpecificTargets = true
                let selUpper = TeethSelection(startTooth: ToothObject.create(number: 18), startAspect: nil, startSite: nil, endTooth: ToothObject.create(number: 28), endAspect: nil, endSite: nil)
                let selLower = TeethSelection(startTooth: ToothObject.create(number: 48), startAspect: nil, startSite: nil, endTooth: ToothObject.create(number: 38), endAspect: nil, endSite: nil)
                let m = cursor.currentMetric
                
                if m == .bleeding || m == .plaque || m == .implant {
                    commands.append(AnnotationCommand(operation: m, teethSelection: selUpper, aspect: nil, values: ["True"]))
                    commands.append(AnnotationCommand(operation: m, teethSelection: selLower, aspect: nil, values: ["True"]))
                } else if !pendingNumbers.isEmpty {
                    let vals = pendingNumbers.map { String(m == .probingDepth ? max(1, abs($0)) : abs($0) * currentMetricMultiplier) }
                    commands.append(AnnotationCommand(operation: m, teethSelection: selUpper, aspect: nil, values: vals))
                    commands.append(AnnotationCommand(operation: m, teethSelection: selLower, aspect: nil, values: vals))
                }
                
                pendingNumbers = []
                activeSelection = nil
                isPostTargeting = false
            }
            
        case .word(let w):
            if w == "minus" {
                isNextNumberNegative = true
            } else if w == "dan" || w == "serta" || w == "," {
                if !pendingTeeth.isEmpty || (activeSelection != nil && pendingNumbers.isEmpty) {
                    isListAggregationActive = true
                } else {
                    isListAggregationActive = false
                }
            } else if w == "_sep_" {
                discardOrFlush(clearSelection: false)
                isListAggregationActive = false
                pendingTeeth.removeAll()
                if activeSelection == nil && pendingNumbers.isEmpty {
                    pendingAnatomies.removeAll()
                }
            } else {
                isListAggregationActive = false
            }
        }
    }
}

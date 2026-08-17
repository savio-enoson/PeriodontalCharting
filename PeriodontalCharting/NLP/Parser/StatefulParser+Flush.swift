import Foundation

extension StatefulParser {
    
    mutating func discardOrFlush(clearSelection: Bool = true) {
        parserTrace("DEBUG discardOrFlush: clearSelection=\(clearSelection)")
        if !pendingNumbers.isEmpty {
            flushNumbers(force: true)
        } else {
            parserTrace("DEBUG discardOrFlush: before if clearSelection=\(clearSelection)")
            if clearSelection {
                parserTrace("DEBUG discardOrFlush: EXECUTING activeSelection = nil")
                emitBoolIfPending()
                activeSelection = nil
                didSpecifyExplicitFullAspect = false
            }
        }
        isPostTargeting = false
    }
    
    mutating func emitBoolIfPending() {
        let m = cursor.currentMetric
        parserTrace("DEBUG emitBoolIfPending: metric=\(m), activeSelection=\(activeSelection != nil), isSelectionUsed=\(isSelectionUsed)")
        if m == .bleeding || m == .plaque || m == .implant || m == .missing {
            if let sel = activeSelection, !isSelectionUsed {
                let targetSlots = sel.expectedSlots
                let values = Array(repeating: "True", count: targetSlots)
                let cmd = AnnotationCommand(operation: m, teethSelection: sel, aspect: cursor.currentAspect, values: values)
                parserTrace("DEBUG FLUSH: EMITTING BOOL \(m) for \(sel.startTooth.toothNumber) to \(sel.endTooth.toothNumber)")
                commands.append(cmd)
                activeSelection = nil
                isSelectionUsed = true
                pendingTeeth = []
                pendingAnatomies = []
            } else {
                parserTrace("DEBUG emitBoolIfPending: failed because sel=\(activeSelection != nil) isSelectionUsed=\(isSelectionUsed)")
            }
        } else {
            parserTrace("DEBUG emitBoolIfPending: failed because metric is \(m)")
        }
        
        if m == .bleeding || m == .plaque || m == .implant || m == .missing {
            if activeSelection == nil && (!pendingAnatomies.isEmpty || !pendingTeeth.isEmpty) {
                let targets = pendingTeeth.isEmpty ? [cursor.currentTooth] : pendingTeeth
                for t in targets {
                    var sel = TeethSelection(startTooth: ToothObject.create(number: t), startAspect: nil, startSite: nil, endTooth: ToothObject.create(number: t), endAspect: nil, endSite: nil)
                    for a in pendingAnatomies {
                        if let resolved = ChartAnatomyResolver.resolve(anatomy: a, for: t, currentAspect: cursor.currentAspect) {
                            let aspectToSet = (a == .mesial || a == .distal) ? nil : resolved.aspect
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
                    
                    let targetSlots = sel.expectedSlots
                    let values = Array(repeating: "True", count: targetSlots)
                    let cmd = AnnotationCommand(operation: m, teethSelection: sel, aspect: sel.startAspect, values: values)
                    commands.append(cmd)
                }
                pendingTeeth = []
            }
        }
    }
    
    
    mutating func restoreToMainSequence() {
        cursor.setMetric(.probingDepth)
        currentMetricMultiplier = 1
        activeSelection = nil
        isPostTargeting = false
        isWaitingForRangeEnd = false
        pendingAnatomies = []
        isListAggregationActive = false
        pendingTeeth = []
        isRangeStartPending = false
        
        cursor.resyncToothToSequence()
        cursor.syncWithSequence()
        
        while missingTeeth.contains(cursor.currentTooth) {
            parserTrace("DEBUG ADVANCE: restoreToMainSequence missing")
            if !cursor.advanceToNextTooth() { break }
        }
    }
    

    mutating func flushNumbers(force: Bool) {
        parserTrace("flushNumbers: force=\(force), pendingNumbers = \(pendingNumbers), metric = \(cursor.currentMetric), activeSelStartSite=\(String(describing: activeSelection?.startSite)), pendingTeeth=\(pendingTeeth)")
        
        var targetSlots = activeSelection?.expectedSlots ?? 3
        
        // For furcation and mobility 1-slot commands, never auto-flush eagerly.
        // For PD/GM 1-slot commands (e.g. "Lingual"), we defer flushing until we see if
        // the user provides 3 numbers ("Lingual 2 2 3") or just 1 ("Lingual 2").
        let isDeferred1SlotMetric = (cursor.currentMetric == .furcation || cursor.currentMetric == .mobility)
        if targetSlots == 1 && !force {
            if isDeferred1SlotMetric { return }
            if (cursor.currentMetric == .probingDepth || cursor.currentMetric == .gingivalMargin) && pendingNumbers.count < 3 { return }
        }
        
        if pendingNumbers.count >= 3 && activeSelection != nil && activeSelection!.startSite != nil && activeSelection!.startTooth.toothNumber == activeSelection!.endTooth.toothNumber {
            parserTrace("DEBUG FLUSH: expanding activeSelection to full tooth because we received \(pendingNumbers.count) numbers")
            activeSelection?.startSite = nil
            activeSelection?.endSite = nil
            targetSlots = 3
        }
        
        let wasFull = pendingNumbers.count >= targetSlots
        
        if pendingNumbers.count >= targetSlots || force {
            var values = pendingNumbers
            
            if values.count == 1 && targetSlots > 1 {
                if cursor.currentMetric != .probingDepth && cursor.currentMetric != .gingivalMargin {
                    values = Array(repeating: values[0], count: targetSlots)
                }
            } else if values.count > 1 && values.count < targetSlots && targetSlots % values.count == 0 {
                let repeatCount = targetSlots / values.count
                var repeatedValues: [Int] = []
                for _ in 0..<repeatCount {
                    repeatedValues.append(contentsOf: values)
                }
                values = repeatedValues
            } else if values.count < targetSlots {
                let fill = values.last ?? 0
                while values.count < targetSlots { values.append(fill) }
            }
            
            values = Array(values.prefix(targetSlots))
            
            let isRange = activeSelection != nil && activeSelection!.startTooth.toothNumber != activeSelection!.endTooth.toothNumber
            
            var selectionsToUse: [TeethSelection] = []
            if isRange {
                let sel = activeSelection!
                let startT = sel.startTooth.toothNumber
                let endT = sel.endTooth.toothNumber
                let sa = sel.startAspect ?? .outer
                let ea = sel.endAspect ?? .outer
                
                var orderedSequence = ChartAnatomyResolver.sequence(from: (startT, sa, sel.startSite), to: (endT, ea, sel.endSite))
                if orderedSequence.isEmpty {
                    orderedSequence = ChartAnatomyResolver.sequence(from: (endT, ea, sel.endSite), to: (startT, sa, sel.startSite))
                }
                
                if orderedSequence.isEmpty {
                    var fallbackSel = sel
                    fallbackSel.endTooth = fallbackSel.startTooth
                    selectionsToUse = [fallbackSel]
                } else {
                    selectionsToUse = [sel]
                }
            } else if !pendingTeeth.isEmpty {
                selectionsToUse = pendingTeeth.map { num in
                    // Start with the aspect/site from activeSelection (if any),
                    // then overlay any pending anatomy tokens (e.g. "bukal", "mesial").
                    var sel = TeethSelection(
                        startTooth: ToothObject.create(number: num),
                        startAspect: activeSelection?.startAspect,
                        startSite: activeSelection?.startSite,
                        endTooth: ToothObject.create(number: num),
                        endAspect: activeSelection?.endAspect,
                        endSite: activeSelection?.endSite
                    )
                    for a in pendingAnatomies {
                        if let resolved = ChartAnatomyResolver.resolve(anatomy: a, for: num, currentAspect: cursor.currentAspect) {
                            let aspectToSet: ChartAspect? = (a == .mesial || a == .distal) ? nil : resolved.aspect
                            if sel.startSite == nil && sel.endSite == nil {
                                sel.startAspect = aspectToSet
                                sel.endAspect = aspectToSet
                                sel.startSite = resolved.site
                                sel.endSite = resolved.site
                            } else {
                                sel.startSite = min(sel.startSite ?? 1, resolved.site ?? 1)
                                sel.endSite = max(sel.endSite ?? 1, resolved.site ?? 1)
                            }
                        }
                    }
                    return sel
                }
            } else {
                selectionsToUse = [activeSelection ?? TeethSelection(startTooth: ToothObject.create(number: cursor.currentTooth), startAspect: nil, startSite: nil, endTooth: ToothObject.create(number: cursor.currentTooth), endAspect: nil, endSite: nil)]
            }
            
            var valuesToEmit: [String] = []
            let m = cursor.currentMetric
            for n in values {
                if m == .probingDepth {
                    valuesToEmit.append(String(max(1, abs(n))))
                } else {
                    valuesToEmit.append(String(abs(n) * currentMetricMultiplier))
                }
            }

            if valuesToEmit.count == 1 && targetSlots > 1 {
                if cursor.currentMetric == .probingDepth || cursor.currentMetric == .gingivalMargin {
                    var allNil = true
                    for i in 0..<selectionsToUse.count {
                        if selectionsToUse[i].startSite != nil {
                            allNil = false
                            break
                        }
                    }
                    if allNil {
                        for i in 0..<selectionsToUse.count {
                            if selectionsToUse[i].startTooth.toothNumber == selectionsToUse[i].endTooth.toothNumber {
                                selectionsToUse[i].startSite = 1
                                selectionsToUse[i].endSite = 1
                            }
                        }
                    } else {
                        valuesToEmit = Array(repeating: valuesToEmit[0], count: targetSlots)
                    }
                }
            }
            
            for selectionToUse in selectionsToUse {
                var reversedValues = valuesToEmit
                if selectionToUse.expectedSlots == 3 {
                    let jaw: JawType = (11...28).contains(selectionToUse.startTooth.toothNumber) ? .upper : .lower
                    let aspectType: AspectType = cursor.currentAspect == .outer ? .buccal : .palatal
                    let dir = cursor.configuration.direction(for: jaw, aspect: aspectType)
                    
                    if dir == .rightToLeft {
                        reversedValues = Array(valuesToEmit.reversed())
                    }
                }
                
                let cmd = AnnotationCommand(
                    operation: m,
                    teethSelection: selectionToUse,
                    aspect: selectionToUse.startAspect ?? cursor.currentAspect,
                    values: reversedValues
                )
                parserTrace("DEBUG FLUSH: active=\(selectionToUse.startTooth.toothNumber) to \(selectionToUse.endTooth.toothNumber), startSite=\(String(describing: selectionToUse.startSite)), endSite=\(String(describing: selectionToUse.endSite)), operation=\(m), values=\(valuesToEmit)")
                commands.append(cmd)
            }
            
            let isPlainTooth = activeSelection != nil && 
                               (activeSelection?.startAspect == nil || activeSelection?.startAspect == cursor.currentAspect) && 
                               (activeSelection?.endAspect == nil || activeSelection?.endAspect == cursor.currentAspect) && 
                               activeSelection?.startSite == nil && activeSelection?.endSite == nil && 
                               activeSelection?.startTooth.toothNumber == activeSelection?.endTooth.toothNumber
            
            if (activeSelection == nil || isPlainTooth) && cursor.currentMetric == .probingDepth && wasFull {
                let oldTooth = cursor.currentTooth
                parserTrace("DEBUG ADVANCE: flushNumbers normal. isPlain=\(isPlainTooth) activeSel=\(activeSelection == nil)")
                _ = cursor.advanceToNextTooth()
                lastAutoAdvancedFromTooth = oldTooth
                while missingTeeth.contains(cursor.currentTooth) {
                    parserTrace("DEBUG ADVANCE: flushNumbers missing")
                    if !cursor.advanceToNextTooth() { break }
                }
            }
            
            activeSelection = nil
            didSpecifyExplicitFullAspect = false
            isSelectionUsed = true
            pendingNumbers = []
            pendingTeeth = []
            pendingAnatomies = []
            isListAggregationActive = false

        }
    }
}

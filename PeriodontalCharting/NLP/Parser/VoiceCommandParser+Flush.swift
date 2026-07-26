import Foundation

extension VoiceCommandParser {
    func restoreToMainSequence() {
        cursor.setMetric(.probingDepth)
        currentMetricMultiplier = 1
        activeSelection = nil
        cursor.resyncToothToSequence()
        cursor.syncWithSequence()
        while missingTeeth.contains(cursor.currentTooth) {
            if !cursor.advanceToNextTooth() { break }
        }
    }
    
    func emitBoolIfPending() {
        let m = cursor.currentMetric
        if m == .bleeding || m == .plaque || m == .implant {
            if let sel = activeSelection {
                print("EMITTING SELECTION:", sel.startTooth.toothNumber, sel.startSite ?? -1, "TO", sel.endTooth.toothNumber, sel.endSite ?? -1); let targetSlots = sel.expectedSlots
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
                    valuesToEmit.append(String(max(1, abs(n))))
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
        print("EMITTING SELECTION:", sel.startTooth.toothNumber, sel.startSite ?? -1, "TO", sel.endTooth.toothNumber, sel.endSite ?? -1); let targetSlots = sel.expectedSlots
        
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
        
        if isBoolMetric {
            return
        }
        
        var didCreateTemplate = false
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
            didCreateTemplate = true
        } else if let last = commands.last, last.operation == cursor.currentMetric {
            postTargetTemplate = commands.popLast()
            didCreateTemplate = true
        }
        
        if didCreateTemplate {
            isPostTargeting = true
            postTargetAnatomy = nil
            self.activeSelection = nil
        }
    }
}

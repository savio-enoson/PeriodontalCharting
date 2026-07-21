import Foundation

class VoiceCommandParser {
    var cursor: ChartingCursor
    var activeSelection: TeethSelection?
    var pendingValues: [String] = []
    var missingTeeth: Set<Int> = []
    
    init(configuration: ChartingConfiguration) {
        self.cursor = ChartingCursor(configuration: configuration)
    }
    
    func parse(text: String, isFinal: Bool = false) -> [AnnotationCommand] {
        let tokens = VoiceTokenizer.tokenize(text: text)
        var commands: [AnnotationCommand] = []
        var i = 0
        
        var currentNumbers: [Int] = []
        
        func restoreToMainSequence() {
            cursor.setMetric(.probingDepth)
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
                
                let cmd = AnnotationCommand(
                    operation: cursor.currentMetric,
                    teethSelection: selectionToUse,
                    aspect: cursor.currentAspect,
                    values: values.map { String($0) }
                )
                commands.append(cmd)
                
                currentNumbers = []
                if self.activeSelection == nil {
                    _ = cursor.advanceToNextTooth()
                    while missingTeeth.contains(cursor.currentTooth) {
                        if !cursor.advanceToNextTooth() { break }
                    }
                }
                self.activeSelection = nil
            }
        }
        
        while i < tokens.count {
            let token = tokens[i]
            
            switch token {
            case .number(let n):
                if cursor.currentMetric == .bleeding || cursor.currentMetric == .plaque || cursor.currentMetric == .implant {
                    emitBoolIfPending()
                    restoreToMainSequence()
                }
                currentNumbers.append(n)
                flushNumbers(force: false)
                i += 1
                
            case .toothIdentifier(let tooth):
                emitBoolIfPending()
                flushNumbers(force: true)
                
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
                    if let sa = startAnatomy, let resolved = ChartAnatomyResolver.resolve(anatomy: sa, for: tooth, currentAspect: cursor.currentAspect) {
                        sAspect = resolved.aspect; sSite = resolved.site
                    }
                    var eAspect: ChartAspect?
                    var eSite: Int?
                    if let ea = endAnatomy, let resolved = ChartAnatomyResolver.resolve(anatomy: ea, for: et, currentAspect: cursor.currentAspect) {
                        eAspect = resolved.aspect; eSite = resolved.site
                    } else if endAnatomy == nil {
                        eAspect = sAspect; eSite = sSite
                    }
                    self.activeSelection = TeethSelection(startTooth: ToothObject.create(number: tooth), startAspect: sAspect, startSite: sSite, endTooth: ToothObject.create(number: et), endAspect: eAspect, endSite: eSite)
                    i = peek
                } else if isRange {
                    if let sa = startAnatomy, let resolved = ChartAnatomyResolver.resolve(anatomy: sa, for: tooth, currentAspect: cursor.currentAspect) {
                        self.activeSelection = TeethSelection(startTooth: ToothObject.create(number: tooth), startAspect: resolved.aspect, startSite: resolved.site, endTooth: ToothObject.create(number: tooth), endAspect: resolved.aspect, endSite: resolved.site)
                    } else {
                        self.activeSelection = TeethSelection(startTooth: ToothObject.create(number: tooth), startAspect: nil, startSite: nil, endTooth: ToothObject.create(number: tooth), endAspect: nil, endSite: nil)
                    }
                    i = peek
                } else {
                    if let sa = startAnatomy, let resolved = ChartAnatomyResolver.resolve(anatomy: sa, for: tooth, currentAspect: cursor.currentAspect) {
                        self.activeSelection = TeethSelection(startTooth: ToothObject.create(number: tooth), startAspect: resolved.aspect, startSite: resolved.site, endTooth: ToothObject.create(number: tooth), endAspect: resolved.aspect, endSite: resolved.site)
                    } else {
                        self.activeSelection = TeethSelection(startTooth: ToothObject.create(number: tooth), startAspect: nil, startSite: nil, endTooth: ToothObject.create(number: tooth), endAspect: nil, endSite: nil)
                    }
                    i += 1
                }
                
            case .metric(let m):
                emitBoolIfPending()
                flushNumbers(force: true)
                self.activeSelection = nil
                cursor.setMetric(m)
                i += 1
                
            case .action(let a):
                if a == .next {
                    if cursor.currentMetric == .bleeding || cursor.currentMetric == .plaque || cursor.currentMetric == .implant {
                        let sel = activeSelection ?? TeethSelection(startTooth: ToothObject.create(number: cursor.currentTooth), startAspect: nil, startSite: nil, endTooth: ToothObject.create(number: cursor.currentTooth), endAspect: nil, endSite: nil)
                        let targetSlots = sel.expectedSlots
                        commands.append(AnnotationCommand(operation: cursor.currentMetric, teethSelection: sel, aspect: cursor.currentAspect, values: Array(repeating: "True", count: targetSlots)))
                    }
                    flushNumbers(force: true)
                    restoreToMainSequence()
                } else if a == .missing || a == .missing2 {
                    emitBoolIfPending()
                    flushNumbers(force: true)
                    self.activeSelection = nil
                    
                    self.missingTeeth.insert(cursor.currentTooth)
                    
                    let cmd = AnnotationCommand(
                        operation: .missing,
                        teethSelection: TeethSelection(startTooth: ToothObject.create(number: cursor.currentTooth), startAspect: nil, startSite: nil, endTooth: ToothObject.create(number: cursor.currentTooth), endAspect: nil, endSite: nil),
                        aspect: cursor.currentAspect,
                        values: ["True"]
                    )
                    commands.append(cmd)
                    _ = cursor.advanceToNextTooth()
                    while missingTeeth.contains(cursor.currentTooth) {
                        if !cursor.advanceToNextTooth() { break }
                    }
                } else if a == .until || a == .until2 {
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
                        var eAspect = cursor.currentAspect
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
                    } else {
                        self.activeSelection = nil
                        i = peek
                        continue
                    }
                }
                i += 1
                
            case .anatomy(let a):
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
                    } else if let resolved = ChartAnatomyResolver.resolve(anatomy: a, for: cursor.currentTooth, currentAspect: cursor.currentAspect) {
                        emitBoolIfPending()
                        flushNumbers(force: true)
                        self.activeSelection = TeethSelection(startTooth: ToothObject.create(number: cursor.currentTooth), startAspect: resolved.aspect, startSite: resolved.site, endTooth: ToothObject.create(number: cursor.currentTooth), endAspect: resolved.aspect, endSite: resolved.site)
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
        }
        
        self.pendingValues = currentNumbers.map { String($0) }
        return commands
    }
}

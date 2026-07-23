import Foundation

struct ChartingCursor: Equatable {
    var currentTooth: Int
    var currentAspect: ChartAspect
    var currentMetric: AnnotationOperation = .probingDepth
    
    var configuration: ChartingConfiguration
    
    // Iteration State
    private(set) var primaryIndex: Int = 0
    private(set) var secondaryIndex: Int = 0
    private(set) var sequenceIndex: Int = 0
    private(set) var currentSequence: [Int] = []
    
    var currentJaw: JawType {
        if configuration.primaryOrder == .jawFirst {
            return configuration.jawOrder[primaryIndex]
        } else {
            let aspectEnum = configuration.aspectOrder[primaryIndex]
            let jawOrder = aspectEnum == .buccal ? configuration.buccalJawOrder : configuration.palatalJawOrder
            return jawOrder[secondaryIndex]
        }
    }
    
    init(configuration: ChartingConfiguration) {
        self.configuration = configuration
        self.currentTooth = 18
        self.currentAspect = .outer
        setupSequence()
    }
    
    private mutating func setupSequence() {
        if configuration.primaryOrder == .jawFirst {
            guard primaryIndex < configuration.jawOrder.count else { return }
            let jaw = configuration.jawOrder[primaryIndex]
            let aspectOrder = jaw == .upper ? configuration.upperAspectOrder : configuration.lowerAspectOrder
            guard secondaryIndex < aspectOrder.count else { return }
            let aspect = aspectOrder[secondaryIndex]
            
            self.currentSequence = configuration.getSequence(for: jaw, aspect: aspect)
            self.currentAspect = (aspect == .buccal) ? .outer : .inner
            self.sequenceIndex = 0
            if !currentSequence.isEmpty {
                self.currentTooth = currentSequence[0]
            }
        } else {
            guard primaryIndex < configuration.aspectOrder.count else { return }
            let aspect = configuration.aspectOrder[primaryIndex]
            let jawOrder = aspect == .buccal ? configuration.buccalJawOrder : configuration.palatalJawOrder
            guard secondaryIndex < jawOrder.count else { return }
            let jaw = jawOrder[secondaryIndex]
            
            self.currentSequence = configuration.getSequence(for: jaw, aspect: aspect)
            self.currentAspect = (aspect == .buccal) ? .outer : .inner
            self.sequenceIndex = 0
            if !currentSequence.isEmpty {
                self.currentTooth = currentSequence[0]
            }
        }
    }
    
    mutating func advanceToNextTooth() -> Bool {
        sequenceIndex += 1
        if sequenceIndex < currentSequence.count {
            self.currentTooth = currentSequence[sequenceIndex]
            return true
        } else {
            // Reached end of row, advance to next row
            return advanceToNextRow()
        }
    }
    
    mutating func advanceToNextRow() -> Bool {
        secondaryIndex += 1
        var secondaryLimit = 2
        if configuration.primaryOrder == .jawFirst {
            let jaw = configuration.jawOrder[primaryIndex]
            secondaryLimit = (jaw == .upper ? configuration.upperAspectOrder : configuration.lowerAspectOrder).count
        } else {
            let aspect = configuration.aspectOrder[primaryIndex]
            secondaryLimit = (aspect == .buccal ? configuration.buccalJawOrder : configuration.palatalJawOrder).count
        }
        
        if secondaryIndex >= secondaryLimit {
            primaryIndex += 1
            secondaryIndex = 0
            
            let primaryLimit = configuration.primaryOrder == .jawFirst ? configuration.jawOrder.count : configuration.aspectOrder.count
            if primaryIndex >= primaryLimit {
                return false
            }
        }
        
        setupSequence()
        return true
    }
    
    mutating func jumpTo(tooth: Int) {
        self.currentTooth = tooth
    }
    
    mutating func syncWithSequence() {
        if sequenceIndex < currentSequence.count {
            self.currentTooth = currentSequence[sequenceIndex]
        }
        
        if configuration.primaryOrder == .jawFirst {
            let jaw = configuration.jawOrder[primaryIndex]
            let aspectOrder = jaw == .upper ? configuration.upperAspectOrder : configuration.lowerAspectOrder
            guard secondaryIndex < aspectOrder.count else { return }
            let aspect = aspectOrder[secondaryIndex]
            self.currentAspect = (aspect == .buccal) ? .outer : .inner
        } else {
            guard primaryIndex < configuration.aspectOrder.count else { return }
            let aspect = configuration.aspectOrder[primaryIndex]
            self.currentAspect = (aspect == .buccal) ? .outer : .inner
        }
    }
    
    mutating func setMetric(_ metric: AnnotationOperation) {
        self.currentMetric = metric
    }
    
    mutating func jumpTo(jaw: JawType) -> Bool {
        if configuration.primaryOrder == .jawFirst {
            if let idx = configuration.jawOrder.firstIndex(of: jaw) {
                primaryIndex = idx
                secondaryIndex = 0
                setupSequence()
                return true
            }
        }
        return false
    }
    
    mutating func jumpTo(aspect: AspectType) -> Bool {
        let prevTooth = currentTooth
        if configuration.primaryOrder == .jawFirst {
            let jaw = configuration.jawOrder[primaryIndex]
            let order = jaw == .upper ? configuration.upperAspectOrder : configuration.lowerAspectOrder
            if let idx = order.firstIndex(of: aspect) {
                secondaryIndex = idx
                setupSequence()
                if let newIdx = currentSequence.firstIndex(of: prevTooth) {
                    sequenceIndex = newIdx
                    currentTooth = prevTooth
                }
                return true
            }
        } else {
            if let idx = configuration.aspectOrder.firstIndex(of: aspect) {
                primaryIndex = idx
                setupSequence()
                if let newIdx = currentSequence.firstIndex(of: prevTooth) {
                    sequenceIndex = newIdx
                    currentTooth = prevTooth
                }
                return true
            }
        }
        return false
    }
    
    mutating func jumpTo(tooth: Int, aspect: ChartAspect, updateSequenceIndex: Bool = true) -> Bool {
        let originalPrimary = primaryIndex
        let originalSecondary = secondaryIndex
        let originalSequenceIndex = sequenceIndex
        let originalSequence = currentSequence
        let originalAspect = currentAspect
        let originalTooth = currentTooth
        
        let primaryLimit = configuration.primaryOrder == .jawFirst ? configuration.jawOrder.count : configuration.aspectOrder.count
        for p in 0..<primaryLimit {
            let secondaryLimit: Int
            if configuration.primaryOrder == .jawFirst {
                let jaw = configuration.jawOrder[p]
                secondaryLimit = (jaw == .upper ? configuration.upperAspectOrder : configuration.lowerAspectOrder).count
            } else {
                let a = configuration.aspectOrder[p]
                secondaryLimit = (a == .buccal ? configuration.buccalJawOrder : configuration.palatalJawOrder).count
            }
            
            for s in 0..<secondaryLimit {
                let testAspect: ChartAspect
                let testSequence: [Int]
                
                if configuration.primaryOrder == .jawFirst {
                    let jaw = configuration.jawOrder[p]
                    let aspectOrder = jaw == .upper ? configuration.upperAspectOrder : configuration.lowerAspectOrder
                    let aspectEnum = aspectOrder[s]
                    testAspect = (aspectEnum == .buccal) ? .outer : .inner
                    testSequence = configuration.getSequence(for: jaw, aspect: aspectEnum)
                } else {
                    let aspectEnum = configuration.aspectOrder[p]
                    let jawOrder = aspectEnum == .buccal ? configuration.buccalJawOrder : configuration.palatalJawOrder
                    let jaw = jawOrder[s]
                    testAspect = (aspectEnum == .buccal) ? .outer : .inner
                    testSequence = configuration.getSequence(for: jaw, aspect: aspectEnum)
                }
                
                if testAspect == aspect, let idx = testSequence.firstIndex(of: tooth) {
                    if updateSequenceIndex {
                        primaryIndex = p
                        secondaryIndex = s
                        currentSequence = testSequence
                        currentAspect = testAspect
                        sequenceIndex = idx
                        currentTooth = tooth
                    } else {
                        primaryIndex = originalPrimary
                        secondaryIndex = originalSecondary
                        sequenceIndex = originalSequenceIndex
                        currentSequence = originalSequence
                        currentAspect = originalAspect
                        currentTooth = tooth
                    }
                    return true
                }
            }
        }
        
        primaryIndex = originalPrimary
        secondaryIndex = originalSecondary
        sequenceIndex = originalSequenceIndex
        currentSequence = originalSequence
        currentAspect = originalAspect
        currentTooth = originalTooth
        return false
    }
    
    mutating func resyncToothToSequence() {
        if sequenceIndex >= 0 && sequenceIndex < currentSequence.count {
            currentTooth = currentSequence[sequenceIndex]
        }
    }
}
